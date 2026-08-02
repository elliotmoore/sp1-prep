#!/bin/bash
#
# sp1-prep-batch.sh
#
# Runs sp1-prep.sh over every audio file in a directory. Handles spaces,
# apostrophes, and other special characters in filenames correctly.
#
# Usage:
#   ./sp1-prep-batch.sh "/path/to/folder"
#
# Non-recursive by default (only files directly in that folder). Add -r
# to also process subfolders:
#   ./sp1-prep-batch.sh -r "/path/to/folder"

set -e

RECURSIVE=0
if [ "$1" = "-r" ]; then
  RECURSIVE=1
  shift
fi

DIR="$1"

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "Usage: $0 [-r] \"/path/to/folder\""
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP1_PREP="$SCRIPT_DIR/sp1-prep.sh"

if [ ! -x "$SP1_PREP" ]; then
  echo "Error: sp1-prep.sh not found or not executable at $SP1_PREP"
  exit 1
fi

MAXDEPTH_ARGS=()
if [ "$RECURSIVE" -eq 0 ]; then
  MAXDEPTH_ARGS=(-maxdepth 1)
fi

COUNT=0
FAILED=()

# -print0 / read -d '' is the safe way to iterate filenames that may
# contain spaces, apostrophes, quotes, etc.
while IFS= read -r -d '' file; do
  COUNT=$((COUNT + 1))
  echo ""
  echo "=========================================="
  echo "Processing ($COUNT): $file"
  echo "=========================================="
  if ! "$SP1_PREP" "$file"; then
    echo "!! Failed: $file"
    FAILED+=("$file")
  fi
done < <(find "$DIR" "${MAXDEPTH_ARGS[@]}" -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.aiff" \) -print0)

echo ""
echo "=========================================="
echo "Batch complete: $COUNT file(s) processed."
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Failed (${#FAILED[@]}):"
  printf '  - %s\n' "${FAILED[@]}"
fi
