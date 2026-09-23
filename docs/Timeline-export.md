# Timeline final-mix export

Choose **Timeline > Export final mix...** or the timeline context menu. The
background job renders the complete arrangement from time zero using a snapshot
of the timeline and mixer. Playback position and looping in the open project
remain unchanged; export disables region looping in its snapshot. Export ends
at the arrangement end, matching timeline playback (no extra effect tail).

- WAV: 24-bit stereo PCM at the project sample rate.
- MP3: Windows-native encoding, 320 kbps, 48 kHz stereo.
- MP4 and M4A: Windows-native AAC, 192 kbps, 48 kHz stereo, audio only.
- PCM: raw signed 16-bit little-endian interleaved stereo at project sample rate.

All carry `UDAW (C) DJ Hobson, Australia, 2026-2027`. WAV uses RIFF INFO/ICOP;
MP3 uses ID3v2 TCOP; MP4/M4A use moov/udta/cprt. Raw PCM has no metadata
container: its adjacent `.pcm.txt` file contains attribution and the audio format.
The existing WAV, MP4 and MP3 file writers/test-tone exports also stamp output.

Rendering streams to disk in blocks. Compressed export requires the native
Windows media encoders. No third-party encoder is installed. Source decoding
still uses the existing in-memory media cache, so very large source files can
require substantial RAM. Missing/undecodable sources or invalid mixer routing
fail visibly instead of producing a silently incomplete mix. Temporary files
are removed on cancellation/failure; existing output is backed up during commit.
Cancel using the existing **Cancel all jobs** action. Status and Jobs show actual
decode/render/encode progress, and completion or failure.

Import now reports progress inside WAV, MP3, AAC/MP4 and FLAC decoding, throttled
to four updates per second, including decoded position and elapsed time. Waveform
construction reports its own measured progress. Short files may finish before a
second passes. Status repaint does not dispatch unrelated editing commands into
a synchronous import. Clip/track labels are fitted to their current pixel width
with `...`; extremely narrow clips omit labels rather than paint outside them.

Validation: Windows Debug build and full test suite, including decoding each
export format, checking attribution, snapshot isolation, mixer gain/pan, import
midpoint reporting, cancellation and preservation of an existing destination.
