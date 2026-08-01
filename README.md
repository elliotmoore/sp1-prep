# sp1-prep

One-command prep tool for loading songs onto the [Teenage Engineering SP-1 stem player](https://solderless.engineering/stemloader/help/).

It runs [Spleeter](https://github.com/deezer/spleeter) to split a track into 4 stems (vocals, drums, bass, other), looks up (or estimates) the song's BPM, and hands the result to [sp1-merge](https://github.com/softmodded/sp1-merge) to encode a single SP-1-compatible 8-channel WAV — ready to drag into the [SP-1 stem loader](https://solderless.engineering/stemloader/).

## Requirements

- `python3` with `pip`
- [`spleeter`](https://github.com/deezer/spleeter) (`pip install spleeter --break-system-packages`)
- [`sp1-merge`](https://github.com/softmodded/sp1-merge) built/installed and on your `PATH`
- `librosa` and `mutagen` — installed automatically on first run if missing

## Usage

```
./sp1-prep.sh "/path/to/song.mp3"
```

Output goes into a `sp1_output` folder next to the input file by default. Pass a second argument to override that:

```
./sp1-prep.sh "/path/to/song.mp3" "/some/other/output/dir"
```

## BPM detection

The SP-1 stem loader needs a BPM per song. This script tries, in order:

1. **Online lookup** via the [GetSongBPM API](https://getsongbpm.com/api) (free, requires your own API key), using the song's title/artist tags if present in the file.
2. **Local audio signature detection**, if no online match is found: `librosa`'s beat tracker analyzes the track's own onset/rhythm signature to estimate tempo directly from the waveform, no tags or internet required. This can be inaccurate (particularly half/double-time errors), so double-check it for songs you know.

To enable the online lookup, get a free API key from [getsongbpm.com/api](https://getsongbpm.com/api) and export it before running:

```
export GETSONGBPM_API_KEY=your_key_here
./sp1-prep.sh "/path/to/song.mp3"
```

BPM data provided by [GetSongBPM.com](https://getsongbpm.com).

## Credits

- [solderless](https://solderless.engineering/) — SP-1 stem loader and file format docs
- [softmodded/sp1-merge](https://github.com/softmodded/sp1-merge) — stem encoder CLI
- [deezer/spleeter](https://github.com/deezer/spleeter) — stem separation
- [GetSongBPM](https://getsongbpm.com) — BPM lookups

## License

Apache 2.0, see [LICENSE](LICENSE).
