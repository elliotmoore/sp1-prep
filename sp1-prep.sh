#!/bin/bash
#
# sp1-prep.sh
#
# One-command wrapper: identifies BPM/metadata, splits a track into 4
# stems with Spleeter, then hands the result to sp1-merge to encode it
# into an SP-1-compatible 8-channel WAV.
#
# Usage:
#   ./sp1-prep.sh "/path/to/song.mp3"
#
# By default, output goes into a subfolder next to the input file.
# Pass a second argument to override that.
#   ./sp1-prep.sh "/path/to/song.mp3" "/some/other/output/dir"
#
# Requirements:
#   - spleeter installed and on PATH (or reachable via `python3 -m spleeter`)
#   - sp1-merge installed and on PATH
#     (see: https://github.com/softmodded/sp1-merge)
#   - python3 with librosa + mutagen for BPM/metadata detection
#     (auto-installed on first run if missing)
#
# Optional:
#   - GETSONGBPM_API_KEY env var for real BPM lookups (free key at
#     https://getsongbpm.com/api). Falls back to local estimation if unset.

set -e

INPUT="$1"

if [ -z "$INPUT" ]; then
  echo "Usage: $0 \"/path/to/song.mp3\" [output_base_dir]"
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "Error: input file not found: $INPUT"
  exit 1
fi

INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
OUTBASE="${2:-$INPUT_DIR/sp1_output}"

# Figure out how to invoke spleeter (direct command, or module fallback)
if command -v spleeter >/dev/null 2>&1; then
  SPLEETER_CMD="spleeter"
else
  echo "Note: 'spleeter' not found on PATH, falling back to 'python3 -m spleeter'"
  SPLEETER_CMD="python3 -m spleeter"
fi

if ! command -v sp1-merge >/dev/null 2>&1; then
  echo "Error: sp1-merge not found on PATH."
  echo "Install it from https://github.com/softmodded/sp1-merge and make sure"
  echo "the built binary is somewhere in your PATH (e.g. /usr/local/bin)."
  exit 1
fi

BASENAME="$(basename "$INPUT")"
TRACKNAME="${BASENAME%.*}"

# --- BPM + metadata detection -------------------------------------------
echo "== Step 1/3: Detecting BPM and metadata =="

python3 -c "import librosa" >/dev/null 2>&1 || pip install librosa --break-system-packages -q
python3 -c "import mutagen" >/dev/null 2>&1 || pip install mutagen --break-system-packages -q

python3 - "$INPUT" "${GETSONGBPM_API_KEY:-}" <<'PYEOF'
import sys, warnings, json, urllib.request, urllib.parse
warnings.filterwarnings("ignore")

path = sys.argv[1]
api_key = sys.argv[2] if len(sys.argv) > 2 else ""

# Existing tag metadata (title/artist), if embedded in the file
title, artist = None, None
try:
    from mutagen import File
    f = File(path, easy=True)
    if f:
        title = (f.get("title") or [None])[0]
        artist = (f.get("artist") or [None])[0]
except Exception:
    pass

bpm = None
bpm_source = None

# 1) Try an online lookup via GetSongBPM if we have both a known title/artist
#    and an API key (https://getsongbpm.com/api - free, requires signup)
if title and artist and api_key:
    try:
        lookup = f"song:{title} artist:{artist}"
        url = "https://api.getsong.co/search/?" + urllib.parse.urlencode({
            "api_key": api_key, "type": "both", "lookup": lookup, "limit": 1
        })
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.load(resp)
        results = data.get("search") or []
        if results and results[0].get("tempo"):
            bpm = int(round(float(results[0]["tempo"])))
            bpm_source = "GetSongBPM lookup"
    except Exception as e:
        print(f"(Online BPM lookup failed: {e})")

# 2) Fall back to local audio analysis if no online match
if bpm is None:
    try:
        import librosa
        y, sr = librosa.load(path, sr=None, mono=True)
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        bpm = int(round(float(tempo)))
        bpm_source = "local estimate (librosa, can be off - especially half/double time)"
    except Exception as e:
        print(f"(Local BPM detection failed: {e})")

print("----------------------------------------")
if bpm:
    print(f"Detected BPM:   {bpm}  [{bpm_source}]")
else:
    print("Detected BPM:   unknown (defaults to 80 in stem loader)")
print(f"Title (tag):    {title if title else 'not found in file metadata'}")
print(f"Artist (tag):   {artist if artist else 'not found in file metadata'}")
print("----------------------------------------")
if not api_key:
    print("Tip: set GETSONGBPM_API_KEY (free key from https://getsongbpm.com/api)")
    print("to look up real BPM for known songs instead of relying on estimation.")
print("Enter title/artist/BPM manually in the stem loader web UI.")
PYEOF

# -------------------------------------------------------------------------

echo ""
echo "== Step 2/3: Separating stems with Spleeter =="
$SPLEETER_CMD separate -p spleeter:4stems -o "$OUTBASE" "$INPUT"

STEM_DIR="$OUTBASE/$TRACKNAME"

if [ ! -d "$STEM_DIR" ]; then
  echo "Error: expected stem output folder not found at $STEM_DIR"
  echo "Check the Spleeter output above for the actual folder name."
  exit 1
fi

echo ""
echo "== Step 3/3: Encoding SP-1-compatible file with sp1-merge =="
echo "Stems folder: $STEM_DIR"
echo ""

# sp1-merge prompts interactively for "folder path (q to quit):". Feed it
# the exact folder we just validated exists, instead of relying on manual
# typing (which was failing, likely due to the space in track names).
printf '%s\n' "$STEM_DIR" | sp1-merge

echo ""
echo "Done. Check $STEM_DIR (or your configured sp1-merge output directory)"
echo "for the final merged WAV, then load it via https://solderless.engineering/stemloader/"
