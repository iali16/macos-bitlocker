# macos-bitlocker-mount-

Mount BitLocker-encrypted Windows drives on macOS (Apple Silicon) with **dislocker** + **ntfs-3g** on macFUSE — including the fix so **Finder shows files, not just folders**.

The same files are visible and readable from the Terminal, but Finder lists only folders — a known macFUSE/ntfs-3g issue caused by mounting without `-o local` + `-o auto_xattr`. This repo contains a ready-to-use script that mounts correctly on the first try.

## Features

- Unlock BitLocker with a **recovery key**, **password**, or **.BEK** key file
- Read/write NTFS via ntfs-3g
- **Finder-compatible mount** (`-o local -o auto_xattr -o auto_cache -o allow_other`) — files show up in Finder
- Same command toggles **mount / unmount**
- `--force` to unmount a busy dislocker mount, `--eject` to eject the disk afterward

## Requirements

- macOS 26.x (tested on Apple Silicon)
- [Homebrew](https://brew.sh)
- [macFUSE](https://macfuse.github.io)
- [dislocker](https://github.com/Aorimn/dislocker)
- [ntfs-3g-mac](https://github.com/gromgit/homebrew-fuse)

## Installation

```sh
# 1. macFUSE (approve the system extension in Privacy & Security, then restart)
brew install --cask macfuse

# 2. dislocker
brew install --build-from-source dislocker
# if that fails, build it manually:
mkdir -p ~/dislocker && cd ~/dislocker
curl -L https://github.com/Aorimn/dislocker/tarball/master | tar -xz --strip 1
mkdir build && cd build
cmake .. && make dislocker
sudo cp dislocker /usr/local/bin/

# 3. ntfs-3g for macOS
brew tap gromgit/fuse
brew install gromgit/fuse/ntfs-3g-mac

# 4. get the script (or just clone this repo)
chmod +x bitlocker-on-macos.sh
```

Verify the tools are installed:

```sh
ntfs-3g --version   # e.g. ntfs-3g 2026.7.7 external FUSE 29
dislocker -h
```

## Usage

### Find your BitLocker partition

```sh
diskutil list
```

An encrypted partition has no readable filesystem, so macOS won't mount it — that's expected. Note the identifier, e.g. `/dev/disk2s3`.

### Mount

```sh
sudo ./bitlocker-on-macos.sh /dev/disk2s3 --recovery
```

Or with a password / key file:

```sh
sudo ./bitlocker-on-macos.sh /dev/disk2s3 --password
sudo ./bitlocker-on-macos.sh /dev/disk2s3 --bek /path/key.bek
```

The volume mounts at `/Volumes/BitLocker` and Finder lists all files inside.

### Unmount

The **same command** detects the volume is mounted and unmounts instead:

```sh
sudo ./bitlocker-on-macos.sh /dev/disk2s3 --recovery
# --force if the dislocker mount is busy
# --eject to also eject the underlying disk
```

## Why Finder showed only folders

```
ntfs-3g /dev/disk3s1 /Volumes/BitLocker        # ❌ folders only in Finder
```

macOS registers that mount as a **non-local (network-style)** filesystem, and Finder refuses to list regular files.

The fix is two FUSE mount options:

```sh
-o local          # report MNT_LOCAL so macOS treats the volume as a local disk
-o auto_xattr     # let Finder read/write macOS-style extended attributes on NTFS
```

Used in full, the script mounts with:

```sh
ntfs-3g -o local -o allow_other -o auto_xattr -o auto_cache \
    "$DEVICE_BLOCK" "/Volumes/$DEVICE_NAME"
```

This is the documented fix from the [macFUSE wiki — NTFS-3G](https://github.com/macfuse/macfuse/wiki/NTFS-3G).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Finder shows folders only, no files | Remount with `-o local -o auto_xattr` (already in the script). If Finder cached the old view: `killall Finder`. |
| Files visible in Terminal but apps can't open them | Same root cause — the volume wasn't mounted as local/`auto_xattr`. |
| `Unmount failed for ~/.dislocker/...` | Something (Finder/Spotlight) holds the FUSE mount → rerun with `--force`, or `sudo umount -f ~/.dislocker/diskXsY`. |
| Volume mounts read-only | NTFS is dirty (Windows didn't shut down cleanly) or hibernated. Boot Windows and run `chkdsk /f`, or `sudo ntfsfix /dev/...`. |
| `mount: cannot locate OSXFUSE` / system extension blocked | macFUSE not loaded/approved. Allow "Benjamin Fleischer" in Privacy & Security, restart, then `sudo /usr/local/bin/load_macfuse` if needed. |

## How it works

1. **dislocker** unlocks the BitLocker volume in userspace and exposes the decrypted NTFS as `~/.dislocker/<device>/dislocker-file`.
2. **hdiutil** attaches that file as a raw block device.
3. **ntfs-3g** (on macFUSE) mounts the decrypted NTFS at `/Volumes/BitLocker` with the Finder-compatible options.

## References

- [macFUSE](https://macfuse.github.io)
- [macFUSE Wiki — NTFS-3G](https://github.com/macfuse/macfuse/wiki/NTFS-3G)
- [macFUSE issue #925 — not able to view files in Finder but visible in terminal](https://github.com/macfuse/macfuse/issues/925)
- [dislocker](https://github.com/Aorimn/dislocker)
- [ntfs-3g](https://github.com/tuxera/ntfs-3g)

## Disclaimer

- Store your password / recovery key **.BEK** file securely — macOS cannot recover it for you.
- Mount encrypted volumes read-only if you don't trust that Windows shut down cleanly.
- This project is provided as-is, without warranty. A bad NTFS state is best fixed in Windows (`chkdsk`).