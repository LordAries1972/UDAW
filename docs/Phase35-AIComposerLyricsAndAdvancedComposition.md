# Phase 35 - AI Composer: Lyrics/Vocals and Advanced Composition

Implements docs/AIPlan.md section 17 **PHASE 5 - LYRICS AND VOCALS** and
**PHASE 6 - ADVANCED COMPOSITION**, on top of the data model (Phase 32/33,
AIPlan Phases 1-2) and the AI provider + basic arrangement engine (Phase 34,
AIPlan Phases 3-4) that already existed. Project format is unchanged
(AISPEC v1, project v6) - everything here is either a pure read/generate
projection over the existing `TSongSpec`/`TLyricDocument` model, or content
the arrangement engine writes into the existing Timeline/MIDI/Mixer
subsystems exactly as Phase 34 already did for drums/bass/harmony.

## Phase 5 - Lyrics and Vocals

`src/composer/UDAW.Composer.Lyrics.pas`:

- `TLyricLine.Words` / `SyllablesPerWord` - phrase-level breakdown of the
  existing per-line vowel-run syllable heuristic (AIPlan section 7 step 3).
- `TLyricLine.ComputeSyllableTimings` - distributes the line's
  `StartBar..DurationBars` span across every syllable, proportionally by
  word (step 4/5: "Assign each line to measures" / "Generate phrase start
  and end positions"). Pure, no new persisted fields - AISPEC format is
  unchanged.
- `TLyricRegion` + `TLyricDocument.AllRegions` - every line across every
  section, flattened and sorted by `StartBar` (step 6: "Create lyric
  regions on the timeline"). `StartBar`/`DurationBars` are already absolute
  song bars, the same convention `TSongSection` uses, so a Timeline/Lyrics
  UI converts a region to seconds with the project's existing
  `UDAW.Timeline.Time.BarsToSeconds`, exactly like a section marker.

`src/composer/UDAW.Composer.VocalGuide.pas` (new unit):

- `GenerateVocalGuide(ASpec, ALyrics, ASectionId, APianoRoll, APPQ, ...)` -
  step 7, "Generate a guide vocal melody or MIDI reference". One MIDI note
  per syllable (from `ComputeSyllableTimings`), pitched from the section's
  chord progression when one exists (reuses
  `UDAW.Composer.Arrangement.ParseChordSymbol`) or the song's key/scale
  otherwise, with a small deterministic stepwise contour (seeded, so the
  same spec regenerates identically per AIPlan section 9) and clamped into
  a caller-supplied note range. No-ops for an instrumental section (no
  matching `TLyricSection`) - step 9's "singing is optional", never a
  hard dependency.

`src/composer/UDAW.Composer.Commands.pas` additions:

- `TRemoveLyricLineCommand` - manual-timing tool (step 9: "manual timing
  corrections"), the removal counterpart to the existing
  `TSetLyricLineCommand`.
- `TGenerateVocalGuideCommand` - one undo step that (re)generates a vocal
  track's guide notes from the document's current lyrics, replacing any
  previously-generated guide notes on that track/clip so repeated
  regeneration after an edit does not pile up stale notes.

## Phase 6 - Advanced Composition

All in `src/composer/UDAW.Composer.Arrangement.pas`, extending
`TApplyArrangementCommand.GenerateMidiForTrack` (previously a hard `Exit`
for any role but drums/bass/harmony) and `Execute`:

- **Melody generation** - `TrackRoleClass` now recognises a melody/lead
  role (4): a stepwise line over chord tones + scale passing tones, one
  note per beat (or per 8th note at higher section energy), octave-tracked
  to the previous note (`NearestOctaveTo`) so it reads as a line rather
  than random leaps.
- **Vocal role** (5) - calls `VocalGuide.GenerateVocalGuide` per section
  automatically whenever the arrangement engine resolves a vocal-role
  track, using the resolved instrument's note range when one was matched.
- **Drum fills / transitions** - a section's last bar gets a building
  16th-note snare/tom roll instead of the steady pattern whenever the next
  section's energy is meaningfully higher (AIPlan's "transition into a
  higher-energy section" case).
- **Section variations** - a deterministic per-track seed
  (`FSpec.GenerationSeed xor hash(track id)`) drives small, reproducible
  embellishments: occasional bass passing tones/octave drops, arpeggiated
  vs. block chords, ghost hats/snares - so a repeated section is not
  byte-identical every time, but the same spec always regenerates the same
  performance (AIPlan section 9).
- **Articulations** - the melody line's note length varies (0.55-0.95 of
  its slot) as a legato/detached gate; harmony occasionally arpeggiates at
  higher energy.
- **Automation** - `ApplyEnergyAutomation` adds a fader-automation lane per
  created strip, one breakpoint per section, riding gently between -6 dB
  and 0 dB with the section's declared `Energy` (AIPlan section 8 step 15 /
  section 11's "Automate ... during the breakdown").
- **Side-chaining** - `ApplySidechaining` wires the first bass-role strip's
  insert chain to duck against the first drum-role strip
  (`TMixInsert.Make('compressor', ...)` with `SidechainStripId`), the
  textbook AIPlan section 11 example ("Side-chain the bass to the kick").
- **Instrument-specific performance logic** - melodic/harmonic/bass note
  generation is clamped into the resolved instrument's
  `TCatalogueItem.NoteRangeLow/High` (octave-shifted, never dropped) when
  the arrangement engine matched one; a generic 2.5-octave register is used
  otherwise.

## Not in this pass

- No UI: this is backend/data-model work only, same as Phase 32-34 before
  it. There is still no AI Composer workspace tab (AIPlan section 15); the
  composer subsystem is driven programmatically / by tests only.
- Automation here is a flat per-section energy ride, not the frequency-
  conflict/gain-staging analysis of AIPlan's later PHASE 7 (Mixing
  Assistance) - that phase is still open.
- Vocal guide notes are a MIDI reference only, never synthesized audio
  (AIPlan section 7: "AI-generated singing should be treated as an
  optional provider feature").

**Unbuilt checkpoint** - written against the existing Delphi 12 codebase
conventions but not yet compiled; build and run `Tests` before trusting it,
per this project's "no build/test while spending credits" rule.
