# Better TTS for the voice call — options, measurements, recommendation

Investigation branch: `feat/better-tts`. Nothing here is wired up yet; this is the
decision record plus the benchmarks that back it.

## Why look at all

Today `VoiceManager.synthesizeAndPlay()` renders every sentence with
`AVSpeechSynthesizer.write()` and schedules the buffers on the duplex engine's
`playerNode`. That is fast and free, but the voice is the weak link: on a
phone call the user is listening to Claude for minutes at a time, and Apple's
*compact* voices are tiring over that span.

Worth knowing before spending any effort: `bestEnglishVoice()` already prefers
premium → enhanced → default, but only over **installed** voices, and premium /
enhanced voices ship as a manual download in
Settings → Accessibility → Spoken Content → Voices. On the Mac used for these
measurements, `AVSpeechSynthesisVoice.speechVoices()` reported **41 English
voices, 0 enhanced, 0 premium** — so the "robotic" voice may simply be the
compact fallback, with the good one one download away. Check the iPhone before
building anything.

## Constraints any replacement has to satisfy

1. **PCM into the existing graph.** Playback must stay on `playerNode` inside
   the one `AVAudioEngine`, or the voice-processing echo canceller loses its
   reference signal and the mic starts hearing Claude. Anything returning
   MP3/Opus has to be decoded to `playbackFormat` before `scheduleBuffer`.
2. **Cancellable mid-sentence.** Barge-in calls `flushSpeech()`; an in-flight
   network request or model run must be abandonable.
3. **Streaming-shaped.** Text arrives as deltas and is already chunked into
   sentences; latency to the *first* sentence of a turn is what the user feels.
4. **Degrades gracefully.** Cellular drops, quota exhaustion, and API errors
   must fall back to `AVSpeechSynthesizer`, not silence. This is an
   accessibility tool someone depends on.
5. **Privacy.** Claude's spoken output quotes the user's source, paths, and
   file contents. Routing it to a third party is a real change in data egress.

## Measurements

All on the target machine: **Apple M1, 8 GB, macOS 26.6.2**. Four sentences of
representative length, warm (second pass), `af_heart` for Kokoro. "first" is
time-to-first-audio-buffer, RTF is total synthesis time ÷ audio duration
(< 1.0 means synthesis outruns playback).

### Baseline — AVSpeechSynthesizer.write(), voice "Samantha" (compact)

| chars | audio | first | total | RTF |
|---|---|---|---|---|
| 97 | 5.36 s | **57 ms** | 96 ms | 0.018 |
| 196 | 10.00 s | **82 ms** | 150 ms | 0.015 |

### Kokoro-82M, MLX GPU path (`mlx-audio`, `Kokoro-82M-4bit`)

| chars | audio | first | total | RTF |
|---|---|---|---|---|
| 5 | 1.30 s | 467 ms | 471 ms | 0.36 |
| 42 | 3.00 s | 395 ms | 406 ms | 0.14 |
| 97 | 6.15 s | 753 ms | 772 ms | 0.13 |
| 196 | 11.95 s | 1404 ms | 1437 ms | 0.12 |

Model load 0.4 s. mlx-audio yields one segment per call, so "first" ≈ "total".

### Kokoro-82M, ONNX CPU path (`kokoro-onnx`)

| chars | fp32 total | fp32 RTF | int8 total | int8 RTF |
|---|---|---|---|---|
| 5 | 311 ms | 0.47 | 712 ms | 1.08 |
| 42 | 757 ms | 0.31 | 1732 ms | 0.70 |
| 97 | 1735 ms | 0.31 | 3483 ms | 0.62 |
| 196 | 3141 ms | 0.28 | 6746 ms | 0.60 |

**int8 is slower than fp32 on this ARM CPU** — roughly 2×, and int8 crosses
RTF 1.0 on short input, meaning it cannot keep up with playback. Do not reach
for the quantised model as an optimisation. onnxruntime's CoreML execution
provider was not tested and is the obvious next lever if this path is chosen.

### Install footprint

| Path | Deps | Model | Total |
|---|---|---|---|
| `mlx-audio` + `misaki[en]` | 1.0 GB (torch 491 MB, mlx 196 MB, spacy, transformers) | 609 MB | **~1.6 GB** |
| `kokoro-onnx` | 126 MB | 310 MB fp32 + 27 MB voices | **~460 MB** |

Both also need `espeak-ng` data for G2P. The `espeakng-loader` wheel shipped a
broken data path (`phontab` missing); Homebrew's `espeak-ng` via
`ESPEAK_DATA_PATH` fixed it, which is a packaging hazard for the notarized app.

mlx-audio pulling **torch** is pure dead weight for Kokoro inference but is a
hard dependency. For anything that has to fit in the signed DMG, ONNX is the
realistic local option; MLX is the faster one.

## Hosted options

Prices are per 1M characters. ~750 chars ≈ 1 minute of speech, so
1M chars ≈ **22 hours** of Claude talking.

| Service | Free per month | After free | Notes |
|---|---|---|---|
| **Google Chirp 3: HD** | **1M chars** (≈22 h) | $30/M ($1.35/h) | Recurring, not a trial. Streaming synthesis endpoint. Needs a billing account attached — set a budget cap. |
| Google Standard / WaveNet | 4M chars | $4/M | Cheap, but WaveNet is not clearly better than a premium Apple voice. |
| Google Neural2 | 1M chars | $16/M | |
| **Azure Neural** | **500k chars** (≈11 h) | $16/M ($0.72/h) | F0 tier, recurring, does not expire. Cheaper overflow than Google. |
| Amazon Polly Neural | 1M chars / 12 months only | $16/M | Free tier expires — disqualifying for a long-lived personal tool. |
| **Kokoro-82M hosted** (DeepInfra / OpenRouter) | — | **$0.62–0.80/M (~$0.03/h)** | Same model as the local option, none of the compute or bundle cost. Genuinely near-free. |
| Google Gemini-TTS | **none** | $10/M audio tokens ≈ $20/M chars | No free tier on Google Cloud. The AI Studio free tier exists but trains on submitted data — unacceptable here, see below. |
| ElevenLabs / Cartesia / Rime | 10k credits or trial | $50–300/M | Best-in-class latency (37–100 ms TTFB) and quality, priced out of "near free". |

**Do not use `edge-tts`.** It is free and sounds good because it is an
undocumented Microsoft Edge read-aloud endpoint. It is outside Microsoft's
terms, has no availability guarantee, and has broken without notice before.
Wrong foundation for something a blind user relies on to reach their machine.

## Privacy note

Claude's spoken output contains file paths, code, and whatever it read in the
working directory. Sending that text to Google or Azure is new egress. Their
**paid** tiers do not train on submitted content; free/consumer tiers
(notably the Gemini API free tier) generally do. If any of the working
directories are sensitive, that alone argues for the local Kokoro path, which
sends nothing anywhere.

## Recommendation

**Step 0 — free, no code, do this first.** Download a Premium English voice on
the iPhone (Settings → Accessibility → Spoken Content → Voices → English →
e.g. Ava, Zoe, Evan) and listen on a real call. `preferredVoice()` will pick it
up with no change. This keeps 60–80 ms latency, full offline operation, and
zero egress. Add a Settings check that reports "no enhanced or premium voice
installed" — there is no API to trigger the download, so the app can only tell
the user (or their sighted helper) to go get one. Only build the rest if a
premium Apple voice is still not good enough.

**Step 1 — Google Chirp 3: HD, synthesized on the Mac.** 22 hours a month free
and recurring is very likely more than this user consumes, the quality gap over
a compact voice is large, and the API key stays on the Mac instead of on the
phone. Azure Neural is the equivalent choice if the cheaper $16/M overflow
matters more than the larger free allowance.

**Step 2 — Kokoro-82M locally, if quota or privacy ever bites.** Apache-2.0, no
account, no key, nothing leaves the machine. Costs ~400–750 ms to first audio
(MLX) and CPU contention with Claude on an 8 GB M1. Hosted Kokoro at ~$0.03/h
gets the same voices with none of that, if egress is acceptable.

## Implementation sketch (shared by steps 1 and 2)

Synthesize on the Mac either way — the server sees the text first, keeps the
credential off the phone, and puts the choice of engine in one place.

- **Server:** new `tts.py` behind a small interface (`synthesize(text) -> bytes`)
  with `google` / `kokoro` / `none` backends selected in `config.json`. Encode
  per sentence to MP3 or AAC at ~32 kbps: a 3 s sentence is ~12 KB, negligible
  over ngrok even on cellular.
- **Protocol:** add `audio_chunk {seq, mime, data_b64}` alongside
  `assistant_delta`, and a `tts` field in `session` telling the client whether
  the server will supply audio. Client keeps speaking deltas locally when it
  will not.
- **Client:** decode each chunk with `AVAudioFile`/`AVAudioConverter` into
  `playbackFormat` and hand it to the existing `PlaybackCoordinator` — the
  playback, barge-in, and echo-cancellation paths do not change. On any
  decode/network/timeout failure, fall through to `AVSpeechSynthesizer` for
  that sentence.
- **Latency:** the current pump is strictly serial (`isSynthesizing` gates one
  sentence at a time). Since every candidate runs at RTF < 0.5, prefetch
  sentence N+1 while N plays so only the *first* sentence of a turn exposes
  latency, and split that first chunk at a clause boundary (~40 chars) to make
  it as short as possible.

## Reproducing the benchmarks

`bench_kokoro_mlx.py`, `bench_kokoro_onnx.py`, and `bench_avspeech.swift` in
this directory. Both Python scripts need `ESPEAK_DATA_PATH` pointed at a real
espeak-ng data dir (`brew install espeak-ng`); the ONNX one needs
`kokoro-v1.0.onnx` and `voices-v1.0.bin` from the kokoro-onnx releases page.
