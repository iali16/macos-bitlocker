# Mounting a BitLocker drive on macOS (Apple Silicon) — and fixing Finder so it shows files, not just folders

> Tried: macOS 26.x, Apple Silicon, macFUSE 5.4.0, dislocker (built from source), ntfs-3g-mac.

Windows BitLocker-encrypted drives can't be read by macOS out of the box. The standard workaround is
**dislocker** (decrypt in userspace) + **ntfs-3g** (read/write NTFS) on top of **macFUSE**.

This works fine in the Terminal, but **Finder only shows folders — no files**. This guide explains why and
the fix (two mount options), and provides a ready-to-use script.

---

## 1. Why Finder shows only folders

When you mount NTFS with a bare

```sh
ntfs-3g /dev/disk3s1 /Volumes/BitLocker
```

macOS registers the volume as a **non-local (network-style)** filesystem and Finder then refuses to display
regular files — directories show, files don't. The same files are perfectly visible and readable from the
Terminal (`ls`, `cp`, etc.).

Finder needs the volume to be reported as a **local** volume that supports **extended attributes**. Both are
FUSE mount options:

```sh
-o local          # report MNT_LOCAL so macOS treats the volume as a local disk
-o auto_xattr     # let Finder read/write macOS-style extended attributes (._ files) on NTFS
```

This is the documented fix in the macFUSE wiki (NTFS-3G page) and the NTFS-3G FAQ
("How to make ntfs-3g drive visible in Finder": *"you have to use `-o local,auto_xattr` … to show the volume in Finder"*).

The full recommended option set:

```sh
ntfs-3g -o local -o allow_other -o auto_xattr -o auto_cache DEVICE MOUNTPOINT
```

---

## 2. Prerequisites

Install Homebrew if you don't have it: <https://brew.sh>

```sh
# 1. macFUSE (system extension; needs a restart and approval on Apple Silicon)
brew install --cask macfuse

# On Apple Silicon you must allow the macFUSE system extension:
#   System Settings > Privacy & Security > scroll to "Allow Benjamin Fleischer" > Allow > Restart

# 2. dislocker (unlocks BitLocker). Homebrew build can be flaky; build from source if needed.
brew install --build-from-source dislocker
# If that still fails, build it manually:
mkdir -p ~/dislocker && cd ~/dislocker
curl -L https://github.com/Aorimn/dislocker/tarball/master | tar -xz --strip 1
mkdir build && cd build
cmake .. && make dislocker
sudo cp dislocker /usr/local/bin/

# 3. ntfs-3g for macOS (gromgit's fork, the one that works with macFUSE on modern macOS)
brew tap gromgit/fuse
brew install gromgit/fuse/ntfs-3g-mac
```

Verify:

```sh
ntfs-3g --version        # e.g. ntfs-3g 2026.7.7 external FUSE 29
dislocker -h
```

---

## 3. The mount script

Save this as `bitlocker-on-macos.sh`. The critical part for Finder is the
`-o local -o allow_other -o auto_xattr -o auto_cache` line.

```sh
#!/usr/bin/env bash
#
# Mount a BitLocker-encrypted device on macOS.
# Requires macFUSE, dislocker, and ntfs-3g.
#
# usage: bitlocker-on-macos.sh /dev/diskXsY [--password|--recovery|--bek FILE] [--force] [--eject]

USAGE="usage: $(basename "$0") /dev/diskXsY [--password|--recovery|--bek FILE] [--force] [--eject]

Mounts a BitLocker-encrypted partition.

Unlock method (default: --password):
  --password          BitLocker user password (-u)
  --recovery          48-digit recovery key, dashes included (-p)
  --bek FILE          .BEK key file (-f)

Other options:
  --force             force the unmount when unmounting
  --eject             eject the underlying disk after unmounting
  -h, --help          display this help and exit

List your available devices with: diskutil list"

DEVICE="$1"
DEVICE_ID="$(echo "$1" | sed 's:/dev/::')"
DEVICE_NUMBER="$(echo "$DEVICE_ID" | rev | cut -f2- -d's' | rev)"
DEVICE_NAME="BitLocker"
DISLOCKER_ARGS=(-u)

# Parse command line arguments.
ARGS=()
EJECT_DISK=""
FORCE_UMOUNT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --eject)
            EJECT_DISK=1
            shift
            ;;
        --force)
            FORCE_UMOUNT=force
            shift
            ;;
        --password)
            DISLOCKER_ARGS=(-u)
            shift
            ;;
        --recovery)
            DISLOCKER_ARGS=(-p)
            shift
            ;;
        --bek)
            DISLOCKER_ARGS=(-f "$2")
            shift 2
            ;;
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        *)
            ARGS+=("$1") # save positional arg
            shift # past argument
            ;;
    esac
done

set -- "${ARGS[@]}"

# Display usage.
[ "$1" = -h ] || [ "$1" = --help ] && echo "$USAGE" && exit 0

# Verify if input argument has been passed.
[ -z "$1" ] && {
    echo "$USAGE"
    echo "[ERROR] Missing device identifier, e.g., '/dev/diskXsY'."
    echo "Tip: List your currently available devices with 'diskutil list'."
    exit 1
}

# Verify if running as superuser.
[ $EUID -ne 0 ] && {
    echo "[ERROR] This script must be run as root (with sudo)."
    exit 1
}

# Work in the invoking user's home, not root's.
if [ -n "$SUDO_USER" ]; then
    USER_HOME="$(eval echo "~$SUDO_USER")"
else
    USER_HOME="$HOME"
fi
DISLOCKER_DIR="$USER_HOME/.dislocker/$DEVICE_ID"
BLOCK_FILE="$USER_HOME/.dislocker/$DEVICE_ID.tmp"

# Unmount if already mounted.
if [ -f "$DISLOCKER_DIR/dislocker-file" ] && [ -f "$BLOCK_FILE" ]; then
    DEVICE_BLOCK="$(cat "$BLOCK_FILE")"

    [ -d "/Volumes/$DEVICE_NAME" ] && diskutil umount "/Volumes/$DEVICE_NAME"
    diskutil umountdisk "$DEVICE_BLOCK" &&
    diskutil umount $FORCE_UMOUNT "$USER_HOME/.dislocker/$DEVICE_ID" &&
    echo "[OK] Successfully unmounted $DEVICE_NAME ($DEVICE_ID => $DEVICE_BLOCK)." &&
    rm -f "$BLOCK_FILE" ||
    {
        echo "[ERROR] Failed to unmount $DEVICE_NAME ($DEVICE_ID => $DEVICE_BLOCK)."
        echo "Tip: Retry the command with '--force'."
        exit 1
    }

    [ -n "$EJECT_DISK" ] && diskutil eject "/dev/$DEVICE_NUMBER"
    exit 0
fi

# Unlock the device with dislocker (prompts for the selected key material).
mkdir -p "$DISLOCKER_DIR" &&
dislocker -V "/dev/$DEVICE_ID" "${DISLOCKER_ARGS[@]}" -- "$DISLOCKER_DIR" || exit 1

# Create a raw block device out of the decrypted (virtual) NTFS file.
ATTACH_OUT="$(hdiutil attach \
    -imagekey diskimage-class=CRawDiskImage -nomount \
    "$DISLOCKER_DIR/dislocker-file")" || exit 1

# Prefer the NTFS partition itself, fall back to the last listed device.
DEVICE_BLOCK="$(echo "$ATTACH_OUT" | awk '/Windows_NTFS|Microsoft Basic Data/ {print $1; exit}')"
[ -z "$DEVICE_BLOCK" ] && DEVICE_BLOCK="$(echo "$ATTACH_OUT" | tail -1 | awk '{print $1}')"
[ -z "$DEVICE_BLOCK" ] && {
    echo "[ERROR] Could not determine the block device created by hdiutil."
    echo "$ATTACH_OUT"
    exit 1
}

# Create the mount point.
mkdir -p "/Volumes/$DEVICE_NAME"

# Mount it read-write with ntfs-3g (falls back to mount_ntfs, read-only).
if command -v ntfs-3g >/dev/null 2>&1; then
    ntfs-3g -o local -o allow_other -o auto_xattr -o auto_cache \
        "$DEVICE_BLOCK" "/Volumes/$DEVICE_NAME" || exit 1
elif [ -x /sbin/mount_ntfs ]; then
    /sbin/mount_ntfs "$DEVICE_BLOCK" "/Volumes/$DEVICE_NAME" || exit 1
else
    echo "[ERROR] No NTFS driver found (install ntfs-3g, e.g. 'brew install ntfs-3g')."
    exit 1
fi

# Store block device identifier for the unmount run.
echo "$DEVICE_BLOCK" > "$BLOCK_FILE"

echo "[OK] Successfully mounted $DEVICE_NAME ($DEVICE_ID => $DEVICE_BLOCK)."
echo "Tip: Run the same command again to unmount the device."
```

Make it executable:

```sh
chmod +x bitlocker-on-macos.sh
```

---

## 4. Usage

### Step 0 — Connect and find your drive

Plug in the BitLocker drive. An encrypted partition has no readable filesystem, so macOS won't mount it —
that's expected, don't panic about the "unrecognized" disk.

List your devices to find the encrypted partition:

```sh
diskutil list
```

Note the identifier, e.g. `/dev/disk2s3`. Its filesystem type will show as something like
`Microsoft Basic Data` or nothing at all — that's normal for BitLocker.

### Mount (prompts for the 48-digit recovery key)

```sh
sudo ./bitlocker-on-macos.sh /dev/disk2s3 --recovery
```

(or `--password` for the BitLocker user password, or `--bek /path/key.bek` for a key file.)

The volume appears at `/Volumes/BitLocker`, and Finder now lists all files inside.

### Unmount

The **same command** detects that it's already mounted and unmounts instead:

```sh
sudo ./bitlocker-on-macos.sh /dev/disk2s3 --recovery
# add --force if the dislocker mount is busy, --eject to also eject the disk
```

---

## 5. Troubleshooting

| Symptom | Fix |
| --- | --- |
| Finder shows folders only, no files | Remount with `-o local -o auto_xattr` (already in the script). If Finder cached the old view: `killall Finder`. |
| Files visible in Terminal but apps can't open them | Same root cause as above — the volume wasn't local/`auto_xattr`. |
| `Unmount failed for ~/.dislocker/...` | Something (Finder/Spotlight) still holds the FUSE mount → rerun with `--force`, or `sudo umount -f ~/.dislocker/diskXsY` first. |
| Volume mounts read-only | NTFS is dirty (Windows didn't shut down cleanly) or hibernated. Boot Windows and run `chkdsk /f`, or `sudo ntfsfix /dev/...`. |
| `mount: cannot locate OSXFUSE` / system extension blocked | macFUSE not loaded/approved. Allow "Benjamin Fleischer" in Privacy & Security and restart, then `sudo /usr/local/bin/load_macfuse` if needed. |
| Recovering your key | macOS does not know the BitLocker key; use the 48-digit recovery key (`--recovery`) or a `.BEK` file (`--bek`). |

---

## 6. References

- macFUSE: <https://macfuse.github.io>
- macFUSE Wiki – NTFS-3G (recommends `-o local -o allow_other -o auto_xattr -o auto_cache`): <https://github.com/macfuse/macfuse/wiki/NTFS-3G>
- macFUSE issue #925 "not able to view files in finder but visible in terminal": <https://github.com/macfuse/macfuse/issues/925>
- dislocker (BitLocker decryption): <https://github.com/Aorimn/dislocker>
- ntfs-3g: <https://github.com/tuxera/ntfs-3g>