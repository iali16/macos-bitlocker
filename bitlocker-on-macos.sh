#!/usr/bin/env bash
#
# Mount a BitLocker-encrypted device on macOS.
# Requires macFUSE, dislocker, and ntfs-3g.
#
# usage: bitlocker-on-macos.sh /dev/diskXsY [--force] [--eject]

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
