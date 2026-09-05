#!/usr/bin/env lua

-- ============================================================
-- Config
-- ============================================================
local MAX_SNAPSHOTS = 25        -- keep between 20-30, adjust as you like
local SNAP_ROOT      = "/.snapshots"
local ROOT_DEV       = "/dev/nvme0n1p2"
local MOUNT_TARGET   = "/mnt/atomic_build"
local LOCK_FILE      = "/run/rhe.lock"

local args = {...}
if #args == 0 then
    print("Usage: rhe [u|i|s|r|un|c|aw] <package>")
    os.exit(1)
end

-- Map of commands for Fedora / DNF
local cmd_map = {
    i  = { cmd = "dnf install",      atomic = false }, -- Live install
    r  = { cmd = "dnf remove",       atomic = false }, -- Live removal
    u  = { cmd = "dnf upgrade",      atomic = true  }, -- Upgrades system in a snapshot
    re = { cmd = "dnf reinstall",    atomic = false }, -- Live reinstall
    c  = { cmd = "dnf check-update", atomic = false }, -- Read-only check
    aw = { cmd = "dnf autoremove",   atomic = false }  -- Cleanup orphans
}

local flag = args[1]
table.remove(args, 1)	

-- Safely quote arguments to prevent shell errors
for i, v in ipairs(args) do
    args[i] = "'" .. v:gsub("'", "'\\''") .. "'"
end

-- Resolve the command action (Fallback to DNF)
local action = cmd_map[flag]
local target_cmd = action and action.cmd or ("dnf " .. flag)
local is_atomic = action and action.atomic or false

local full_command = target_cmd
if #args > 0 then
    full_command = full_command .. " " .. table.concat(args, " ")
end

-- ============================================================
-- Helpers
-- ============================================================

local function run(c)
    local status = os.execute(c)
    if type(status) == "number" then return status == 0 end
    return status == true or status == 0
end

local function log(color, tag, msg)
    print("\27[" .. color .. "m[" .. tag .. "]\27[0m " .. msg)
end

-- Ask btrfs directly for the subvolume's path relative to the top-level
-- of the filesystem, instead of guessing a "@snapshots/..." layout.
-- `btrfs subvolume show <path>` prints that relative path as its first line.
local function get_subvol_path(path)
    local handle = io.popen("btrfs subvolume show " .. path .. " 2>/dev/null")
    if not handle then return nil end
    local line = handle:read("*l")
    handle:close()
    if not line then return nil end
    return line:match("^%s*(.-)%s*$") -- trim whitespace
end

-- Simple lockfile to stop two rhe runs from racing on the same mountpoint
local function acquire_lock()
    local f = io.open(LOCK_FILE, "r")
    if f then
        f:close()
        return false
    end
    f = io.open(LOCK_FILE, "w")
    if f then
        f:write(tostring(os.time()))
        f:close()
    end
    return true
end

local function release_lock()
    os.remove(LOCK_FILE)
end

-- List existing snapshot dirs under SNAP_ROOT, oldest first
-- (relies on the "@snap_YYYYMMDD_HHMMSS" naming sorting lexically = chronologically)
local function list_snapshots()
    local snaps = {}
    local handle = io.popen("ls -1 " .. SNAP_ROOT .. " 2>/dev/null | grep '^@snap_' | sort")
    if handle then
        for line in handle:lines() do
            table.insert(snaps, line)
        end
        handle:close()
    end
    return snaps
end

-- Delete oldest snapshots beyond MAX_SNAPSHOTS
local function prune_snapshots()
    local snaps = list_snapshots()
    local excess = #snaps - MAX_SNAPSHOTS
    if excess <= 0 then return end

    log("33", "Prune", "Snapshot count (" .. #snaps .. ") exceeds limit (" .. MAX_SNAPSHOTS .. "), removing " .. excess .. " oldest...")
    for i = 1, excess do
        local victim = SNAP_ROOT .. "/" .. snaps[i]
        log("33", "Prune", "Deleting " .. victim)
        if not run("btrfs subvolume delete " .. victim) then
            log("31", "Warning", "Could not delete " .. victim .. " (may be default/mounted, skipping)")
        end
    end
end

-- ============================================================
-- Execution Handlers
-- ============================================================

local function execute_live(cmd)
    log("32", "Raid OS", "Running live: " .. cmd)
    return os.execute(cmd)
end

local function execute_atomic(cmd)
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local snap_dir  = SNAP_ROOT .. "/@snap_" .. timestamp

    if not acquire_lock() then
        log("31", "Error", "Another rhe transaction is already running (lock: " .. LOCK_FILE .. ")")
        return false, "locked", 1
    end

    -- Ensures we always release the lock, even on early return
    local function fail(reason)
        release_lock()
        return false, reason, 1
    end

    log("32", “Fedora", "Initiating Atomic Build Environment...")
    run("mkdir -p " .. SNAP_ROOT)

    log("34", "1/7", "Creating read-write Btrfs snapshot at " .. snap_dir)
    if not run("btrfs subvolume snapshot / " .. snap_dir) then
        log("31", "Error", "Failed to create Btrfs snapshot!")
        return fail("snapshot_failed")
    end

    -- Dynamically resolve the real subvol path instead of assuming "@snapshots/..."
    local btrfs_subvol = get_subvol_path(snap_dir)
    if not btrfs_subvol then
        log("31", "Error", "Could not resolve btrfs subvolume path for " .. snap_dir)
        run("btrfs subvolume delete " .. snap_dir)
        return fail("subvol_resolve_failed")
    end
    log("34", "2/7", "Resolved subvolume path: " .. btrfs_subvol)

    log("34", "3/7", "Mounting snapshot and API filesystems...")
    run("mkdir -p " .. MOUNT_TARGET)

    if not run("mount -o subvol=" .. btrfs_subvol .. " " .. ROOT_DEV .. " " .. MOUNT_TARGET) then
        log("31", "Error", "Failed to mount snapshot subvolume!")
        run("btrfs subvolume delete " .. snap_dir)
        return fail("mount_failed")
    end

    -- Ensure Fedora mount targets exist inside the mounted snapshot
    run("mkdir -p " .. MOUNT_TARGET .. "/var/cache/dnf")
    run("mkdir -p " .. MOUNT_TARGET .. "/efi")
    run("mkdir -p " .. MOUNT_TARGET .. "/dev")
    run("mkdir -p " .. MOUNT_TARGET .. "/proc")
    run("mkdir -p " .. MOUNT_TARGET .. "/sys")
    run("mkdir -p " .. MOUNT_TARGET .. "/run")

    -- Track what we've successfully mounted so cleanup only unwinds real mounts
    local mounted = {}

    local function bind_or_fail(src, dst)
        if not run("mount -B " .. src .. " " .. dst) then
            log("31", "Error", "Failed to bind mount " .. src .. " -> " .. dst)
            return false
        end
        table.insert(mounted, dst)
        return true
    end

    local function rbind_or_fail(src, dst)
        if not run("mount -R " .. src .. " " .. dst .. " && mount --make-rslave " .. dst) then
            log("31", "Error", "Failed to rbind mount " .. src .. " -> " .. dst)
            return false
        end
        table.insert(mounted, dst)
        return true
    end

    local function unwind_and_fail(reason)
        log("31", "Error", "Rolling back partial mounts...")
        for i = #mounted, 1, -1 do
            run("umount -l " .. mounted[i])
        end
        run("umount " .. MOUNT_TARGET)
        run("btrfs subvolume delete " .. snap_dir)
        return fail(reason)
    end

    if not bind_or_fail("/var/cache/dnf", MOUNT_TARGET .. "/var/cache/dnf") then return unwind_and_fail("bind_failed") end
    if not bind_or_fail("/efi", MOUNT_TARGET .. "/efi") then return unwind_and_fail("bind_failed") end
    if not bind_or_fail("/run", MOUNT_TARGET .. "/run") then return unwind_and_fail("bind_failed") end
    if not rbind_or_fail("/dev", MOUNT_TARGET .. "/dev") then return unwind_and_fail("rbind_failed") end
    if not rbind_or_fail("/proc", MOUNT_TARGET .. "/proc") then return unwind_and_fail("rbind_failed") end
    if not rbind_or_fail("/sys", MOUNT_TARGET .. "/sys") then return unwind_and_fail("rbind_failed") end

    log("34", "4/7", "Executing DNF inside isolated snapshot chroot...")
    local chroot_cmd = "chroot " .. MOUNT_TARGET .. " /bin/bash -c " .. "'" .. cmd:gsub("'", "'\\''") .. "'"
    local build_ok = run(chroot_cmd)

    log("34", "5/7", "Cleaning up bind mounts...")
    for i = #mounted, 1, -1 do
        if not run("umount -l " .. mounted[i]) then
            log("31", "Warning", "Failed to unmount " .. mounted[i] .. " (left as lazy unmount request)")
        end
    end
    if not run("umount " .. MOUNT_TARGET) then
        log("31", "Warning", "Failed to unmount " .. MOUNT_TARGET .. ", retrying lazily...")
        run("umount -l " .. MOUNT_TARGET)
    end

    if not build_ok then
        log("31", "Build Failed", "Cleaning up target snapshot " .. snap_dir)
        run("btrfs subvolume delete " .. snap_dir)
        return fail("build_failed")
    end

    log("34", "6/7", "Promoting snapshot `@snap_" .. timestamp .. "` to default boot subvolume...")
    run("btrfs subvolume set-default " .. snap_dir)

    -- Fedora uses grub2-mkconfig instead of grub-mkconfig
    run("grub2-mkconfig -o /boot/grub2/grub.cfg > /dev/null 2>&1")

    -- IF YOU WANT TRUE IMMUTABILITY, UNCOMMENT THIS LINE:
    -- run("btrfs property set " .. snap_dir .. " ro true")

    log("34", "7/7", "Pruning old snapshots...")
    prune_snapshots()

    log("32", "Success", "Atomic transaction complete! Reboot to load `@snap_" .. timestamp .. "`.")
    release_lock()
    return true, "success", 0
end
local success, reason, status
if is_atomic then
    success, reason, status = execute_atomic(full_command)
else
    success, reason, status = execute_live(full_command)
end

if type(success) == "number" then
    os.exit(success / 256)
else
    os.exit(status or (success and 0 or 1))
end

