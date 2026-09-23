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
