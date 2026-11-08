#!/usr/bin/env luajit

-- ============================================================
-- rhe - tiny DNF5 wrapper for Fedora 45 (Btrfs)
--
--   rhe u         ONE snapshot of "/" right before the upgrade, then dnf upgrade
--   rhe ls        list the pre-update snapshots
--   rhe rb [name] roll back (newest snapshot by default), then reboot
--
-- Assumes the default Fedora Btrfs layout: "/" lives in the
-- subvolume named "root" (kernel arg: rootflags=subvol=root).
-- ============================================================

-- ============================================================
-- Config
-- ============================================================
local MAX_SNAPSHOTS = 25               -- keep the newest N, 0 = never delete any
local SNAP_PREFIX   = "rhe_pre_"       -- snapshots are rhe_pre_YYYYMMDD_HHMMSS
local ROLLED_NAME   = "rhe_rolled_back"-- old root kept after a rollback
local TOP_MNT       = "/mnt/rhe_top"   -- temp mount of the Btrfs top level
local LOCK_DIR      = "/run/rhe.lock"  -- mkdir is atomic, so no race

local USAGE = [[
Usage: rhe <action> [packages...]

  i   install        r   remove        re  reinstall
  s   search         c   check-update  aw  autoremove
  u   upgrade (takes ONE pre-update snapshot first)
  ls  list pre-update snapshots
  rb  roll back to the newest snapshot (or: rhe rb <name>)

Anything else is passed straight to dnf (e.g. "rhe repoquery foo").]]

-- Plain actions: all of these just run live through dnf (DNF5)
local cmd_map = {
    i  = "dnf install",
    r  = "dnf remove",
    re = "dnf reinstall",
    c  = "dnf check-update",
    aw = "dnf autoremove",
    s  = "dnf search",
    u  = "dnf upgrade",
}

-- ============================================================
-- Helpers
-- ============================================================

local function shq(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Returns ok (bool), exit code (number). Works on Lua 5.1 - 5.4.
local function run(cmd)
    local a, _, code = os.execute(cmd)
    if type(a) == "number" then           -- Lua 5.1 style
        return a == 0, math.floor(a / 256)
    end
    return a == true, code or (a and 0 or 1)
end

local function capture(cmd)
    local h = io.popen(cmd .. " 2>/dev/null")
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function exists(path)
    return run("test -e " .. shq(path))
end

local function log(color, tag, msg)
    print("\27[" .. color .. "m[" .. tag .. "]\27[0m " .. msg)
end

local function is_root()
    return capture("id -u") == "0"
end

-- Lock: mkdir fails if the dir already exists. /run is a tmpfs,
-- so a stale lock disappears on reboot.
local function acquire_lock()
    return run("mkdir " .. LOCK_DIR .. " 2>/dev/null")
end

local function release_lock()
    run("rmdir " .. LOCK_DIR .. " 2>/dev/null")
end

-- Mount the top level of the Btrfs filesystem (subvolid=5) so we can
-- see "root" and the snapshots side by side.
local function mount_top()
    if capture("findmnt -no FSTYPE /") ~= "btrfs" then
        log("31", "Error", "/ is not Btrfs, so rhe can't snapshot it.")
        return false
    end
    local uuid = capture("findmnt -no UUID /")
    if uuid == "" then
        log("31", "Error", "Could not find the UUID of the root filesystem.")
        return false
    end
    run("mkdir -p " .. TOP_MNT)
    if not run("mount -o subvolid=5 -U " .. shq(uuid) .. " " .. TOP_MNT) then
        log("31", "Error", "Failed to mount the Btrfs top level.")
        return false
    end
    return true
end

local function umount_top()
    if not run("umount " .. TOP_MNT) then
        run("umount -l " .. TOP_MNT)
    end
end

-- Snapshot names, oldest first (the timestamp sorts chronologically).
-- Only call this while the top level is mounted.
local function list_snapshots()
    local snaps = {}
    local out = capture("ls -1 " .. TOP_MNT .. " | grep '^" .. SNAP_PREFIX .. "'")
    for line in out:gmatch("[^\n]+") do
        snaps[#snaps + 1] = line
    end
    table.sort(snaps)
    return snaps
end

-- Delete the oldest snapshots beyond MAX_SNAPSHOTS
local function prune_snapshots()
    if MAX_SNAPSHOTS <= 0 then return end
    local snaps = list_snapshots()
    local excess = #snaps - MAX_SNAPSHOTS
    for i = 1, excess do
        local victim = TOP_MNT .. "/" .. snaps[i]
        log("33", "Prune", "Deleting old snapshot " .. snaps[i])
        if not run("btrfs subvolume delete " .. victim .. " >/dev/null") then
            log("31", "Warning", "Could not delete " .. snaps[i] .. ", skipping.")
        end
    end
end

-- ============================================================
-- Snapshot: exactly ONE new read-only snapshot per update
-- ============================================================

local function take_snapshot()
    if not mount_top() then return false end

    local name = SNAP_PREFIX .. os.date("%Y%m%d_%H%M%S")
    local snap = TOP_MNT .. "/" .. name
    local old_root = TOP_MNT .. "/" .. ROLLED_NAME
    local ok = false

    -- Leftover broken root from an earlier rollback. If it's still
    -- the running system, the delete just fails, which is fine.
    if exists(old_root) and run("btrfs subvolume delete " .. old_root .. " >/dev/null 2>&1") then
        log("33", "Clean", "Removed leftover rolled-back root.")
    end

    log("34", "1/2", "Taking pre-update snapshot " .. name .. " (read-only)...")
    if run("btrfs subvolume snapshot -r / " .. snap) then
        ok = true
        prune_snapshots()
    else
        log("31", "Error", "Failed to create the Btrfs snapshot!")
    end

    umount_top()
    return ok, name
end

-- ============================================================
-- List
-- ============================================================

local function show_snapshots()
    if not mount_top() then return false end
    local snaps = list_snapshots()
    umount_top()

    if #snaps == 0 then
        print("No pre-update snapshots yet.")
        return true
    end
    for i, s in ipairs(snaps) do
        print(s .. (i == #snaps and "   (newest)" or ""))
    end
    return true
end

-- ============================================================
-- Rollback
--
-- Fedora boots with rootflags=subvol=root, so `btrfs subvolume
-- set-default` would do nothing. Instead we swap the subvolume
-- NAMES: current root -> rhe_rolled_back, snapshot copy -> root.
-- The snapshot itself stays untouched (you can roll back again).
-- ============================================================

local function rollback(target)
    -- "/root" -> "root"
    local root_name = capture("findmnt -no FSROOT /"):gsub("^/", "")
    if root_name == "" then
        log("31", "Error", "Could not work out the name of the root subvolume.")
        return false
    end

    if target then
        if not target:match("^[%w_]+$") then
            log("31", "Error", "Bad snapshot name.")
            return false
        end
        if target:sub(1, #SNAP_PREFIX) ~= SNAP_PREFIX then
            target = SNAP_PREFIX .. target   -- allow just the timestamp
        end
    end

    if not mount_top() then return false end

    local name = target
    if not name then
        local snaps = list_snapshots()
        name = snaps[#snaps]
    end

    local root     = TOP_MNT .. "/" .. root_name
    local old_root = TOP_MNT .. "/" .. ROLLED_NAME
    local ok = false

    if not name or not exists(TOP_MNT .. "/" .. name) then
        log("31", "Error", "Snapshot not found. See `rhe ls`.")
    elseif exists(old_root) and not run("btrfs subvolume delete " .. old_root) then
        log("31", "Error", "A previous rollback is still pending. Reboot first.")
    elseif not run("mv " .. root .. " " .. old_root) then
        log("31", "Error", "Could not move the current root out of the way.")
    elseif not run("btrfs subvolume snapshot " .. TOP_MNT .. "/" .. name .. " " .. root) then
        log("31", "Error", "Could not restore the snapshot, putting the old root back...")
        run("mv " .. old_root .. " " .. root)
    else
        ok = true
        log("34", "Rollback", "Restored " .. name)
    end

    umount_top()
    return ok
end

-- ============================================================
-- Main
-- ============================================================

local args = {...}
if #args == 0 then
    print(USAGE)
    os.exit(1)
end

local flag = table.remove(args, 1)

local quoted = {}
for _, v in ipairs(args) do quoted[#quoted + 1] = shq(v) end
local arg_str = (#quoted > 0) and (" " .. table.concat(quoted, " ")) or ""

-- Actions that touch Btrfs need root and the lock
if flag == "rb" or flag == "ls" or flag == "u" then
    if not is_root() then
        log("31", "Error", "Run as root: sudo rhe " .. flag)
        os.exit(1)
    end
    if not acquire_lock() then
        log("31", "Error", "Another rhe is already running (" .. LOCK_DIR .. ")")
        os.exit(1)
    end
end

-- ---------- rhe ls ----------
if flag == "ls" then
    local ok = show_snapshots()
    release_lock()
    os.exit(ok and 0 or 1)
end

-- ---------- rhe rb [name] ----------
if flag == "rb" then
    local ok = rollback(args[1])
    release_lock()
    if ok then
        log("32", "Success", "Rolled back. Reboot to boot the pre-update system.")
        os.exit(0)
    end
    os.exit(1)
end

-- ---------- rhe u ----------
if flag == "u" then
    local ok, name = take_snapshot()
    if not ok then
        release_lock()
        log("31", "Aborted", "No snapshot, so no upgrade. Nothing was changed.")
        os.exit(1)
    end

    log("34", "2/2", "Running: " .. cmd_map.u .. arg_str)
    local up_ok, code = run(cmd_map.u .. arg_str)
    release_lock()

    if up_ok then
        log("32", "Success", "Upgrade done. Your way back is `" .. name .. "` (sudo rhe rb).")
    else
        log("31", "Failed", "Upgrade failed. Undo it with: sudo rhe rb")
    end
    os.exit(code)
end

-- ---------- everything else: live dnf ----------
local base = cmd_map[flag] or ("dnf " .. shq(flag))
log("32", "Raid OS", "Running: " .. base .. arg_str)
local _, code = run(base .. arg_str)

-- dnf5 check-update exits 100 when updates exist. That's not an error.
if flag == "c" and code == 100 then code = 0 end

os.exit(code)
