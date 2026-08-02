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

META_FILE="$(mktemp)"

python3 - "$INPUT" "${GETSONGBPM_API_KEY:-}" "$META_FILE" <<'PYEOF'
import sys, warnings, json, urllib.request, urllib.parse, shlex, re
warnings.filterwarnings("ignore")

path = sys.argv[1]
api_key = sys.argv[2] if len(sys.argv) > 2 else ""
meta_file = sys.argv[3]

def normalize(s):
    # Strip punctuation (apostrophes, periods, etc.) that trips up exact
    # search matching, e.g. "Jennifers body" vs "Jennifer's Body".
    return re.sub(r"[^\w\s]", "", s).strip() if s else s

def strip_suffixes(s):
    # Drop parenthetical/bracketed suffixes like "(Club Mix)", "(Radio Edit)",
    # "[Remastered]", "(feat. X)" that often aren't in the canonical DB title.
    if not s:
        return s
    return re.sub(r"\s*[\(\[][^\)\]]*[\)\]]\s*", " ", s).strip()

def getsongbpm_search(api_key, type_, lookup, timeout=10):
    url = "https://api.getsong.co/search/?" + urllib.parse.urlencode({
        "api_key": api_key, "type": type_, "lookup": lookup, "limit": 5
    })
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.load(resp)

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
    norm_title, norm_artist = normalize(title), normalize(artist)
    try:
        # Attempt 1: combined title+artist search (as-tagged)
        data = getsongbpm_search(api_key, "both", f"song:{title} artist:{artist}")
        results = data.get("search")

        # Attempt 2: same, but with punctuation stripped (handles missing
        # apostrophes etc. in file tags vs. the canonical title)
        if not (isinstance(results, list) and results) and (norm_title != title or norm_artist != artist):
            data = getsongbpm_search(api_key, "both", f"song:{norm_title} artist:{norm_artist}")
            results = data.get("search")

        # Attempt 3: title-only search, accept a result only if its artist
        # loosely matches our tag's artist (avoids grabbing the wrong song)
        if not (isinstance(results, list) and results):
            data = getsongbpm_search(api_key, "song", norm_title)
            candidates = data.get("search")
            if isinstance(candidates, list):
                for c in candidates:
                    c_artist = normalize((c.get("artist") or {}).get("name") or "")
                    if c_artist.lower() == norm_artist.lower():
                        results = [c]
                        break

        # Attempt 4: strip "(Club Mix)"/"(Radio Edit)"/"[Remastered]"-style
        # suffixes and retry title-only, e.g. "One More Time (Club Mix)"
        # doesn't exist as a distinct DB entry from "One More Time".
        if not (isinstance(results, list) and results):
            stripped_title = normalize(strip_suffixes(title))
            if stripped_title and stripped_title != norm_title:
                data = getsongbpm_search(api_key, "song", stripped_title)
                candidates = data.get("search")
                if isinstance(candidates, list):
                    for c in candidates:
                        c_artist = normalize((c.get("artist") or {}).get("name") or "")
                        if c_artist.lower() == norm_artist.lower():
                            results = [c]
                            break

        if isinstance(results, list) and results and results[0].get("tempo"):
            bpm = int(round(float(results[0]["tempo"])))
            bpm_source = "GetSongBPM lookup"
        else:
            print(f"(No GetSongBPM match for '{title}' by '{artist}')")
    except Exception as e:
        print(f"(Online BPM lookup failed: {type(e).__name__}: {e})")

# 2) Fall back to local audio analysis if no online match
if bpm is None:
    import signal as _signal

    class _TimeoutError(Exception):
        pass

    def _on_timeout(signum, frame):
        raise _TimeoutError("local BPM analysis timed out (likely a corrupted/slow-decoding file)")

    try:
        # Guard against corrupted MP3s that make the decoder hang instead
        # of raising cleanly (seen with mpg123 "dequantization failed").
        _signal.signal(_signal.SIGALRM, _on_timeout)
        _signal.alarm(60)

        # Compat shim: recent scipy versions removed the deprecated
        # scipy.signal.{hann,hamming,blackman,...} aliases that older
        # librosa/resampy code still calls directly.
        import scipy.signal
        import scipy.signal.windows as _sig_windows
        for _name in ("hann", "hamming", "blackman", "bartlett", "kaiser"):
            if not hasattr(scipy.signal, _name) and hasattr(_sig_windows, _name):
                setattr(scipy.signal, _name, getattr(_sig_windows, _name))

        import librosa
        y, sr = librosa.load(path, sr=None, mono=True)
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        bpm = int(round(float(tempo)))
        bpm_source = "local estimate (librosa, can be off - especially half/double time)"
    except Exception as e:
        print(f"(Local BPM detection failed: {e})")
    finally:
        _signal.alarm(0)

# SP-1 stem loader only accepts BPM in the 30-300 range. If a bad detection
# lands outside that (common librosa failure mode: half/double time), clamp
# it into range rather than handing the loader a value it won't accept.
if bpm is not None and not (30 <= bpm <= 300):
    clamped = min(max(bpm, 30), 300)
    print(f"(Detected BPM {bpm} is outside SP-1's 30-300 range, clamping to {clamped})")
    bpm = clamped
    bpm_source = (bpm_source or "") + " [clamped to valid range]"

print("----------------------------------------")
if bpm:
    print(f"Detected BPM:   {bpm}  [{bpm_source}]")
    if bpm_source and "local estimate" in bpm_source:
        print(f"                (sanity check: could actually be half-time ~{round(bpm/2)}")
        print(f"                 or double-time ~{bpm*2} - local estimation often confuses these)")
else:
    print("Detected BPM:   unknown (defaults to 80 in stem loader)")
print(f"Title (tag):    {title if title else 'not found in file metadata'}")
print(f"Artist (tag):   {artist if artist else 'not found in file metadata'}")
print("----------------------------------------")
if not api_key:
    print("Tip: set GETSONGBPM_API_KEY (free key from https://getsongbpm.com/api)")
    print("to look up real BPM for known songs instead of relying on estimation.")
print("Enter title/artist/BPM manually in the stem loader web UI.")

# Write machine-readable metadata for the shell script to pick up (used to
# name the final output file: $artist-$songtitle-$bpm-stem.wav)
with open(meta_file, "w") as f:
    f.write(f"BPM={bpm if bpm else 80}\n")
    f.write(f"ARTIST={shlex.quote(artist if artist else 'Unknown')}\n")
    f.write(f"TITLE={shlex.quote(title if title else 'Unknown')}\n")
PYEOF

# shellcheck disable=SC1090
source "$META_FILE"
rm -f "$META_FILE"

# Trim leading/trailing whitespace without re-parsing quote characters.
# (xargs does this too, but chokes on literal apostrophes/quotes in tag
# text - e.g. "Robert De Niro' waiting" - with "unterminated quote".)
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Filesystem-safe versions (strip slashes/quotes, collapse whitespace to underscores, lowercase)
SAFE_ARTIST="$(trim "$(echo "$ARTIST" | tr -d "\"'\`" | tr '/' '-' | tr -s ' ' '_' | tr '[:upper:]' '[:lower:]')")"
SAFE_TITLE="$(trim "$(echo "$TITLE" | tr -d "\"'\`" | tr '/' '-' | tr -s ' ' '_' | tr '[:upper:]' '[:lower:]')")"
SAFE_TRACKNAME="$(trim "$(echo "$TRACKNAME" | tr -d "\"'\`" | tr '/' '-' | tr -s ' ' '_' | tr '[:upper:]' '[:lower:]')")"

# Fall back to the original filename instead of "unknown" for any piece
# that had no tag data, rather than baking literal "unknown" into the name.
if [ "$ARTIST" = "Unknown" ] && [ "$TITLE" = "Unknown" ]; then
  FINAL_NAME="${SAFE_TRACKNAME}-${BPM}BPM-stem.wav"
elif [ "$ARTIST" = "Unknown" ]; then
  FINAL_NAME="${SAFE_TRACKNAME}-${SAFE_TITLE}-${BPM}BPM-stem.wav"
elif [ "$TITLE" = "Unknown" ]; then
  FINAL_NAME="${SAFE_ARTIST}-${SAFE_TRACKNAME}-${BPM}BPM-stem.wav"
else
  FINAL_NAME="${SAFE_ARTIST}-${SAFE_TITLE}-${BPM}BPM-stem.wav"
fi

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

# sp1-merge prompts interactively for "folder path (q to quit):", processes
# it, then loops back asking for another folder (it supports batch runs).
# Feed it our folder, then "q" to quit cleanly once that one finishes —
# without the q it spins in a fast empty-read loop once stdin hits EOF.
printf '%s\nq\n' "$STEM_DIR" | sp1-merge

# sp1-merge writes its output as "<stems folder name>.wav" inside that same
# folder (e.g. ".../01 Rio/01 Rio.wav" for a "01 Rio" stems folder).
OUTPUT_FILE="$STEM_DIR/${TRACKNAME}.wav"

echo ""
if [ -f "$OUTPUT_FILE" ]; then
  # Clean up intermediate files now that the merge succeeded: the raw
  # Spleeter stems and any leftover sp1-merge temp files.
  rm -f "$STEM_DIR/vocals.wav" "$STEM_DIR/drums.wav" "$STEM_DIR/bass.wav" "$STEM_DIR/other.wav" "$STEM_DIR"/*.sp1tmp.flac 2>/dev/null

  # Flatten the output: Spleeter always nests per-track output under its
  # own subfolder, but there's no need to keep the final file buried in
  # there once it's the only thing left. Move it up next to sp1_output/
  # and remove the now-empty per-track folder.
  FINAL_PATH="$OUTBASE/$FINAL_NAME"
  mv "$OUTPUT_FILE" "$FINAL_PATH"
  rmdir "$STEM_DIR" 2>/dev/null

  echo "Done. Final file: $FINAL_PATH"
else
  echo "Done, but couldn't find sp1-merge's output at $OUTPUT_FILE to rename."
  echo "Check $STEM_DIR and rename it manually to: $FINAL_NAME"
  echo "(Leaving intermediate stem files in place since the merge may not have succeeded.)"
fi
echo "Load it via https://solderless.engineering/stemloader/"
