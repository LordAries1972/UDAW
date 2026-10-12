# Test fixtures

Small, self-contained conformance vectors. Not shipped with the product.

## MP3 (Phase 15)

| file | what it is | how it was made |
|------|------------|-----------------|
| `tone_cbr128.mp3` | 0.5 s, 44100 Hz stereo, CBR 128 kbps, Xing header. Left = 440 Hz sine, right = 1500 Hz sine. | `ffmpeg -f lavfi -i "sine=440...;sine=1500...;amerge" -c:a libmp3lame -b:a 128k` |
| `tone_vbr.mp3` | same source, LAME VBR `-q:a 2` | as above with `-q:a 2` |
| `tone_cbr128.f32` | golden PCM: ffmpeg's decode of `tone_cbr128.mp3`, raw `f32le`, interleaved L/R | `ffmpeg -i tone_cbr128.mp3 -f f32le` |
| `tone_src.f32` | the pre-encode source tone as `f32le` (absolute reference for the spectral check) | `ffmpeg -i tone.wav -f f32le` |
| `real_excerpt.mp3` | 0.6 s, 48000 Hz stereo, LAME 192 kbps. A re-encoded excerpt of the repo owner's own track (joint stereo, full Huffman-table + bit-reservoir coverage). | `ffmpeg -ss 30 -t 0.6 -i <owner track> -c:a libmp3lame -b:a 192k` |
| `real_excerpt.f32` | golden PCM: ffmpeg's decode of `real_excerpt.mp3` | `ffmpeg -i real_excerpt.mp3 -f f32le` |

`Tests.Phase15` decodes each `.mp3` with `UDAW.Codec.MP3.Decoder`, aligns to the
golden `.f32` by best-lag cross-correlation (MP3 has encoder delay), and asserts
the segmental SNR clears a threshold that separates a correct decoder (tens of
dB vs an independent reference) from a broken one (a single wrong Huffman-table
entry collapses SNR to near zero).

## Sound decoding of MP4 / M4A / MKV (Tests.MediaDecode)

Short clips made with FFmpeg's AAC encoder from the repo owner's own material
(tune1 / countdown-mix1), each paired with the reference decoder's output as raw
interleaved `f32le` (`ffmpeg -i x.m4a -f f32le`), trimmed to the real audio length
(the edit list removes encoder priming/padding, so the decoder must match that
length too).  A decoder with any AAC tool wrong lands near 7 dB against these;
the correct one is > 130 dB.

| file | what it covers |
|------|----------------|
| `aac_stereo_tools.m4a/.f32` | 1 s, 48 kHz stereo, 128 kbps; transients (short windows + start/stop windows), TNS, M/S, intensity stereo, PNS (`-aac_pns 1 -aac_is 1 -aac_tns 1 -aac_ms 1`) |
| `aac_mono22k_pns.m4a/.f32` | 1 s, 22.05 kHz mono, 48 kbps, PNS; the 22.05 kHz band tables |
| `aac_51_order.m4a/.f32` | 0.3 s, 5.1 (six different sines): SCE + CPE + CPE + LFE and the output channel order L R C LFE Ls Rs |
| `aac_fragmented.mp4` | `aac_stereo_tools.m4a` stream-copied into a fragmented MP4 (`-movflags +frag_keyframe+empty_moov`): decoded by the system pipeline |
| `video_aac_stereo.mkv` | 64x48 5 fps picture + the same AAC stream, 1 s: MKV probe, decode, import and export through the system pipeline |

The MKV / fragmented tests skip themselves (and say so) on a machine with no
DirectShow splitter for those containers.
