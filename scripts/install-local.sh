#!/bin/sh
set -eu

usage() {
  echo "Usage: scripts/install-local.sh [--replace] /absolute/path/to/factorio/mods" >&2
  exit 2
}

replace=false
if [ "${1:-}" = "--replace" ]; then
  replace=true
  shift
fi
[ "$#" -eq 1 ] || usage

mods_dir=$1
case "$mods_dir" in
  /*) ;;
  *) echo "The mods directory must be an absolute path." >&2; exit 2 ;;
esac
[ -d "$mods_dir" ] || { echo "Mods directory does not exist: $mods_dir" >&2; exit 2; }

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/sceatorio-install.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM

archive=$(python3 "$script_dir/package.py" --output "$staging_dir")
python3 "$script_dir/validate.py" --archive "$archive"
destination=$mods_dir/$(basename -- "$archive")

if [ -e "$destination" ] && [ "$replace" != true ]; then
  echo "Refusing to overwrite $destination; pass --replace for that exact file." >&2
  exit 1
fi
if [ -e "$destination" ]; then
  rm -- "$destination"
fi
cp -- "$archive" "$destination"
echo "Installed $(basename -- "$destination") in $mods_dir"
