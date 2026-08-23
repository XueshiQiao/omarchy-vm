#!/bin/bash
# Rolls the VM's disk back to a saved restore point.
#
# The disk is one APFS file, so a restore is a clone — instant, and it costs no
# extra space. Cloning is also why keeping several restore points is cheap.
set -euo pipefail
cd "$(dirname "$0")/vm"

usage() {
  echo "usage: restore.sh <restore-point>"
  echo
  echo "available:"
  for f in disk-*.img; do
    [ -e "$f" ] || continue
    printf "  %-30s %s\n" "${f%.img}" "$(du -h "$f" | cut -f1)"
  done
  exit 2
}

[ $# -eq 1 ] || usage
src="$1.img"
[ -f "$src" ] || { echo "restore.sh: no such restore point: $1"; echo; usage; }

if pgrep -f "omarchy-vm --" >/dev/null; then
  echo "restore.sh: the VM is still running — shut it down first" >&2
  exit 1
fi

# Keep what we are about to overwrite, so a mistaken restore is itself undoable.
if [ -f disk.img ]; then
  cp -c disk.img "disk-replaced-$(date +%Y%m%d-%H%M%S).img"
  echo "current disk saved as disk-replaced-*.img"
fi

rm -f disk.img
cp -c "$src" disk.img
echo "restored disk.img from $1"
du -h disk.img
