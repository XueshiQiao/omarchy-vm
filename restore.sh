#!/bin/bash
# restore.sh — save and roll back the guest's whole machine state.
#
# A restore point is the disk *and* the EFI variable store together. The disk
# alone is not enough: the boot entry the installer wrote lives in the variable
# store, so restoring one without the other can leave a machine that has an OS
# on it and no way to reach it.
#
# On APFS both files are cloned, so a restore point is instant and costs nothing
# until the copies diverge. Keep as many as you like.
set -euo pipefail
cd "$(dirname "$0")"

VM=vm
SNAPS=$VM/snapshots
DISK=$VM/disk.img
NVRAM=$VM/efistore.nvram

vm_running() { pgrep -f "omarchy-vm --" >/dev/null; }

list() {
  [ -d "$SNAPS" ] || { echo "  (none yet)"; return; }
  local found=0
  for d in "$SNAPS"/*/; do
    [ -d "$d" ] || continue
    found=1
    printf "  %-34s %s\n" "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  done
  [ $found -eq 1 ] || echo "  (none yet)"
}

usage() {
  cat >&2 <<USAGE
usage:
  restore.sh save <name>     save the current disk + EFI variables
  restore.sh <name>          roll back to a saved point
  restore.sh list            show what is saved

saved points:
USAGE
  list >&2
  exit 2
}

[ $# -ge 1 ] || usage

case "$1" in
  list) echo "saved points:"; list; exit 0 ;;
  save)
    [ $# -eq 2 ] || usage
    dest=$SNAPS/$2
    [ -e "$dest" ] && { echo "restore.sh: '$2' already exists" >&2; exit 1; }
    [ -f "$DISK" ] || { echo "restore.sh: no $DISK to save" >&2; exit 1; }
    # A live disk would be captured mid-write, which is a crash, not a snapshot.
    vm_running && { echo "restore.sh: shut the VM down first" >&2; exit 1; }
    mkdir -p "$dest"
    cp -c "$DISK" "$dest/disk.img"
    [ -f "$NVRAM" ] && cp -c "$NVRAM" "$dest/efistore.nvram"
    echo "saved $2"
    du -sh "$dest" | cut -f1
    ;;
  *)
    src=$SNAPS/$1
    [ -d "$src" ] || { echo "restore.sh: no such restore point: $1" >&2; usage; }
    vm_running && { echo "restore.sh: shut the VM down first" >&2; exit 1; }
    # Keep what we are about to overwrite, so a mistaken restore is undoable too.
    if [ -f "$DISK" ]; then
      undo=$SNAPS/replaced-$(date +%Y%m%d-%H%M%S)
      mkdir -p "$undo"
      cp -c "$DISK" "$undo/disk.img"
      [ -f "$NVRAM" ] && cp -c "$NVRAM" "$undo/efistore.nvram"
      echo "current state kept as $(basename "$undo")"
    fi
    rm -f "$DISK" "$NVRAM"
    cp -c "$src/disk.img" "$DISK"
    [ -f "$src/efistore.nvram" ] && cp -c "$src/efistore.nvram" "$NVRAM"
    echo "restored from $1"
    ;;
esac
