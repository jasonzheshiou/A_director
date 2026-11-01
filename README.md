# A_director — one GPU, two tenants, one video pipeline

Architecture notes and the core code for a two-box setup that renders short films
with **MiniMax H3** on a single AMD GPU that is *also* the machine's LLM server.

There is no orchestration framework here. The interesting part is the handover:
how one GPU is rented from an LLM, used for a 36-minute render, and given back
with proof that the box is in the state you claim it is.

---

## The constraint that shapes everything

| | role | notes |
|---|---|---|
| **workstation** `192.0.2.158` | drives the pipeline, archives clips, serves the dashboard, holds a small local standby model | consumer GPUs, no `ffmpeg`/`ffprobe` installed on purpose |
| **model host** `192.0.2.59` | every heavy model | 122 GiB unified AMD memory (gfx1151), rootless podman, no passwordless sudo |

One GPU, **one tenant at a time**:

```
        ┌──────────────── model host ────────────────┐
        │                                            │
        │   LLM        :8080   ┐                     │
        │                      ├─ mutually exclusive │
        │   MiniMax H3 :8189   ┘  (~57.5 GiB weights)│
        └────────────────────────────────────────────┘
```

H3's weights cannot coexist with the LLM, so **every render is a full handover**:

```
llm down → video up → render → clip archived → llm up
```

Two consequences that drive the whole design:

* a render is a *state transition*, not a command — it can be interrupted at any arrow
* the box is shared with the user's own work, so an interrupted handover is a bug report,
  not an inconvenience

---

## Model swapping — `code/host-reset.sh`

The host-side primitive. It hands the GPU over from whatever holds it, **proves** the
memory came back, and only then starts one named tenant.

```
host-reset.sh status          containers, units, servers, memory   (no change)
host-reset.sh stop            release everything, verify, start nothing
host-reset.sh abl | stock     release everything, start that LLM checkpoint
host-reset.sh video           release everything, start the MiniMax H3 node
host-reset.sh ... --dry-run   print every action, change nothing
host-reset.sh ... --force     also TERM/KILL host servers no container owns
```

Three rules, each learned expensively:

**1. Stop each container through whatever owns it.**
A systemd user unit is stopped with `systemctl --user` — its `ExecStop` knows the grace
period. Launcher-owned containers are stopped *and removed* after their log is saved,
because a launcher refuses to run over a dead container of its own name: there,
"stopped" is not "released". Unit-owned containers are only ever stopped, because
removing one breaks the unit that starts it with `podman start`.

**2. Nothing new starts until memory is measurably free.** Not assumed — polled:

```bash
GTT_MAX_GIB=2      # device memory tolerated when "released"
MEM_FLOOR_GIB=110  # RAM required before a 57 GiB model starts
```

`verify_released()` reads `mem_info_gtt_used` and `MemAvailable` in a loop until both
clear, and says so in the log:

```
released: gtt 1.8 GiB (limit 2), MemAvailable 118.4 GiB (floor 110) in 11s
```

A container podman has forgotten can still leave the AMD driver holding device memory —
that is how a box refuses a model it plainly has room for. Cache reclaim needs root, so
`drop_caches` runs only when `sudo -n` works; otherwise the shortfall is reported
rather than hidden.

**3. Starting is confirmed by published identity, not liveness.**
After a swap, the script polls `GET :8080/v1/models` until the returned model id
*contains the expected string* — and dies if it answers as anything else:

```
FAIL: started but answers as '<other-checkpoint>', expected a model containing 'Abliterated'
```

An abliterated box must never come back serving the stock checkpoint, silently.

**Why it is a script and not a systemd unit:** a swap happens only when a human asks.
Nothing here auto-starts an LLM — no unit, no cron, no boot hook. That is a deliberate
invariant, because the box is shared with interactive work.

---

## Run lifecycle — `code/vgen`

Runs on the workstation, drives the host over ssh. Owns the whole cycle above.

```
vgen render "…" --seconds 5            one clip; --dry-run to plan
vgen batch --file shots.txt            N prompts, ONE handover
vgen film --film <name>                a shot list from the host, stitched after
vgen status | facts | doctor           state, machine-readable state, preflight
vgen progress | watch | dash           is a render running, and how far along
vgen collect [run-id]                  fetch clips a finished run left on the host
vgen abort                             stop a runaway batch, keep the clips
vgen heal                              finish an interrupted handover (idempotent)
vgen recover                           abort → collect → heal, in one call
```

Three rules this script exists to enforce:

**1. Restore the model that was actually live, not the one a state file prefers.**
The published id is captured *before* anything is stopped and compared afterwards.

**2. A render is finished when the artefact appears — never by the clock, never by an
ssh exit code.** The work is detached on the host, which records its own return code;
completion is the clip showing up in `out/`. The ssh tunnel may die at any point without
changing either the outcome or the verdict.

**3. Never leave the box in a state nobody can finish.** The owed variant is written to
the host *before* anything is stopped, so `vgen heal` — or, with no workstation at all,
`~/host-reset.sh abl` on the host — closes the handover. Both are idempotent converges,
not a replay of a half-run sequence.

> **Why it is built this way.** Measured 2026-10-25: the WiFi link between the two boxes
> dropped for ~10 minutes in the middle of a 4-minute render. The clip was produced, the
> ssh carrying it was not, and the single best-effort restore that followed ran over that
> same dead tunnel — so a successful render was reported failed and the LLM stayed down
> until it was started by hand. Every rule above is the fix for that afternoon.

A related consequence: the workstation has no `ffmpeg`/`ffprobe`. Media is probed where
the tools live, and only verdicts cross the wire.

---

## The render node — `code/animate`

Renders one H3 clip (video **and** stereo audio) against the local ComfyUI
(`127.0.0.1:8189`). Prints the output path on the last line of stdout and timing on
stderr, so it composes: `play "$(animate --seconds 2 '…')"`.

Notes that matter to anyone touching the graph:

* **Do not poll ComfyUI's HTTP while it is sampling.** It does not answer, and each poll
  stalls 18–43 s. `animate` polls at 45 s with 10 retries for exactly this reason.
* `CLIPLoader type` **must** be `minimax`. The text encoder is a Qwen3-VL-32B truncated to
  50 language layers, exported without the final LM norm, vision tower and three DeepStack
  mergers intact. A generic Qwen3-VL will not substitute — and the wrong type fails at
  tokenize time, not load time.
* `cfg` is **1.0 and is not a stylistic choice**: H3 is distilled and cfg-free. The negative
  branch is never evaluated at 1.0, which is why it is wired to the positive conditioning —
  KSampler's schema still requires the input.
* The AV latent is a `NestedTensor` pair — video `[B,24,T,H/16,W/16]` plus audio
  `[B,32,2,T40]` — decoded by **two different VAEs**, so one sampler feeds both a
  `VAEDecode` and a `VAEDecodeAudio`. Frames snap up to a `17k+5` grid at 24 fps.
* `shift_video`/`shift_audio` (defaults 12.0/3.0) drive the flow schedule *and* are handed
  to the DiT, which derives the audio schedule from the video one. Changing one without the
  other desyncs sound from picture.
* `SaveVideo` needs `codec` as well as `format` on ComfyUI 0.31; omitting it executes every
  other node and then fails at the write.

---

## Measured cost (864×480, `--turbo 4step`, first-frame, with audio)

| frames | seconds of video | wall | sampling | non-sampler |
|---|---|---|---|---|
| 56 | 2.3 s | 4 m 03 s | 0:55 | 3:08 |
| 124 | 5.2 s | **10 m 30 s** | 4:49 | 5:40 |
| 243 | 10.1 s | **36 m 17 s** | 23:52 | 12:25 |

Sampling grows ~quadratic **up to 124 frames and then collapses** (exponent ≈3.37 above
it). Non-sampler work is linear at ~3 s/frame. The practical rule: short takes are the
unit of exploration, long takes are for a shot that has already earned it.

Measured and **closed** — do not re-try, each cost hours: `<4` steps, `--cache-none`
(forces a full weight reload per job), 1344×768 (54 min, then out of RAM), parallel
renders (one job already holds ~54–64 GiB of GTT), INT8 attention on the `hip` backend
(no attention capability there), and `HIP_FORCE_DEV_KERNARG` + `expandable_segments`
(null on H3, −33% elsewhere).

---

## The dashboard

`vgen dash` for the terminal; a small Python server for the browser. Two design points
worth keeping:

* the page is rendered from a **cached** reading refreshed by one background poll, so a
  page full of viewers costs one ssh round-trip per poll instead of one per refresh, and
  an unreachable host shows as a *stale reading with its age* instead of a broken page
* it binds to a VPN-only address by default and **refuses `0.0.0.0`** — the page shows
  model paths, run state and a button that starts a process

---

## The example

`sample/imagine_2035_final_v27+brand-vo-v04en-e3.mp4` — the delivered cut this pipeline
produced, shipped here as a concrete reference for what comes out the other end.

| | |
|---|---|
| duration | **99.96 s** |
| container / codecs | MP4, **H.264** (`avc1`) + **AAC** (`mp4a`) |
| size / bitrate | 19.4 MB, ≈1.6 Mbps |

*(Container facts parsed directly from `moov`/`mvhd` — no other tooling needed.)*

It is the end of this chain, each stage a separate one-shot process that exits and leaves
nothing resident:

```
shot list → keyframes (image stage) → H3 clips (video tenant) → narration → score → mux
```

**Rights on the sample:** the score is generated with `m-a-p/YuE2-3B`
(**CC-BY-NC-4.0**) and the narration is a voice clone rendered with Qwen3-TTS.
It is published here as a **non-commercial** technical sample; clear both licences before
any commercial use.

---

## Layout

```
A_director/
  README.md
  code/host-reset.sh    host-side tenant swap + proof gate
  code/vgen             run lifecycle: render, batch, collect, heal, recover
  code/animate          single H3 clip render against local ComfyUI
  sample/               the one delivered clip, as a reference
  tools/publish-check.sh  leak gate run before every push
```

### Reuse

Both long scripts read their environment, so they are portable to any host with an AMD
GPU of the same class:

| variable | default | meaning |
|---|---|---|
| `NUCBOX_HOST` | `model-host` | ssh alias of the model host |
| `MODEL_PORT` | `8080` | OpenAI-compatible port the swap must confirm on |
| `VIDEO_SANDBOX` | `~/Video_Sandbox` | where the ComfyUI node lives |
| `VIDEO_COMFY` | `127.0.0.1:8189` | ComfyUI address for `animate` |
| `VIDEO_CONTAINER` | `video-comfy` | container name the video tenant runs in |
| `GTT_MAX_GIB` / `MEM_FLOOR_GIB` | `2` / `110` | the release proof thresholds |

Addresses in `code/` are placeholders from RFC 5737 documentation space, and the ssh
alias is neutralised; container and unit names are the real ones.

---

## The short version

1. **One tenant at a time, and prove the handover with measurements** — `gtt` and
   `MemAvailable`, plus the published model id. Never trust an exit code.
2. **Completion is an artefact.** The clip appearing in `out/`, not a log line.
3. **Every state must be finishable by someone.** Write what you owe before you take the
   GPU, so recovery is an idempotent converge rather than a replay.
