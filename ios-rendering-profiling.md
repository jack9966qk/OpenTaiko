# iOS Rendering Profiling Guide

How to find what costs time each frame on iOS, working toward the **120 fps** target
(8.3 ms budget) on a real device. Written as the rendering counterpart to
`ios-memory-profiling.md`.

## Background: the frame and the budget

`GameViewController.OnFrame` (driven by `CADisplayLink`) calls `Game.iOSFrame(delta)`,
which runs four phases:

```
Update()  →  Draw()  →  BlitFullScreen()  →  SwapBuffers()
 logic      scene to    intermediate FBO     present + vsync
            game-res     → device FB at
            FBO          native res
```

At 120 fps every phase shares an **8.3 ms** wall. At 60 fps it's 16.6 ms. The first
question is never "what's slow" but **"are we CPU-bound or GPU-bound?"** — they need
completely different fixes, and you cannot tell them apart by staring at the code.

> **To even measure 120 fps you must request it.** The `szs` commit ("WIP unlock FPS")
> sets `CADisableMinimumFrameDurationOnPhone` in `Info.plist` and a
> `CAFrameRateRange(60, max, max)` on the display link. Without it `CADisplayLink` caps
> at 60 and the profiler can never show better than 16.6 ms frames. Land szs first.

---

## Why GL timing is subtle

GL calls don't execute when you call them — they queue commands and return. The GPU
drains that queue later. So a CPU timer around a block measures the cost of **building
and submitting** commands, not of the GPU running them. Consequences:

- `Update`, `Draw`, `Blit` timers = **CPU submission time**.
- The GPU's actual work, plus the wait for the next vsync slot, surfaces in
  **`SwapBuffers`**, because that's where the driver blocks.

This is the lever for the CPU-vs-GPU question without any external tool.

---

## Step 1 — in-app frame profiler (always on, all builds)

`iOSFrame` times each phase and folds it into an exponential moving average (α = 0.05,
so the readout is stable, not per-frame jitter). `CTexture.DrawCallCount` counts
`glDrawElements` calls across the scene render.

**On-screen HUD** (`GameViewController.UpdateDebugHud`, updates every 60 frames):

```
 Frame: u1.2 d4.8 b1.1 s9.0 ms  dc320
         │    │    │    │        └ scene draw calls
         │    │    │    └ SwapBuffers (GPU catch-up + vsync wait)
         │    │    └ Blit (full-screen FBO → device, CPU submit)
         │    └ Draw (scene → FBO, CPU submit)
         └ Update (game logic)
```

**Log** (`Documents/OpenTaiko.log`, every ~10 s) via `LogFrame()`:

```
[Frame] fps=118, update=1.20 ms, draw=4.80 ms, blit=1.10 ms, swap=9.00 ms, cpu=7.10 ms, drawcalls=320, stage=...
```

`cpu = update + draw + blit` is the total CPU submission time — the number to compare
against the budget.

### How to read it (the triage)

| Pattern | Verdict | Next step |
|---|---|---|
| `cpu` alone ≳ budget (8.3 / 16.6 ms) | **CPU-bound** | Reduce submission: batch draws, kill per-draw work. Go to Step 2 → Time Profiler. |
| `cpu` small, `swap` large, frame interval ≈ budget | Healthy — just **vsync-throttled** | You're hitting target; idle slack is fine. |
| `cpu` small, `swap` large, frame interval **> budget** | **GPU-bound** | Fill-rate/overdraw/the FBO bandwidth pass. Go to Step 2 → GPU tools. |
| `draw` high **+ high `dc`** | Submission-bound on call count | Batch sprites sharing a texture. |
| `draw` high **+ modest `dc`** | Per-draw CPU cost | The matrix math / uniform uploads / the per-draw `DateTime.Now` in `t描画`. |

Step 1 gives a precise CPU picture and only an *inferred* GPU signal (via swap). It
cannot name a GPU hotspot — that's what Step 2 is for. Its job is to tell you **which
side to profile** so you don't waste an Instruments session on the wrong one.

---

## Step 2 — Xcode / Instruments (the authoritative measurement)

**Profile on device, never the simulator.** The sim uses a software GL renderer and the
Mono interpreter; its CPU and GPU numbers bear no relation to AOT-on-GPU hardware (same
caveat as the memory guide).

### 2.0 — Build for profiling

A Debug build distorts CPU numbers (no AOT, extra checks). Build a Release/AOT build on
device and keep the `[Frame]`/`[Mem]` logging (it compiles into all configs):

```bash
OpenTaiko.iOS/scripts/deploy.sh device          # device unlocked at launch
```

Then attach Instruments to the running app rather than letting it build a Debug target.

### 2.1 — Time Profiler (the workhorse — use this when Step 1 says CPU-bound)

This is the most reliable iOS rendering tool, because OpenGL ES draw submission is all
CPU work and Time Profiler captures CPU perfectly.

1. **Xcode → Open Developer Tool → Instruments → Time Profiler.**
2. Choose the device + OpenTaiko as the target (or attach to the running process).
3. Record while driving the suspect scene (gameplay with many notes, song select).
4. In the call tree, enable **Invert Call Tree** + **Hide System Libraries**, and set
   the track to the **GL/main thread**.
5. Look for the frame's hot leaves. Expected suspects from the code:
   - `CTexture.t描画` and its `Matrix4X4` multiply chain (≈8 per sprite).
   - `glUniform*` / `glDrawElements` thunks (Silk.NET → driver) — high self-time here
     = submission-bound, confirms "batch the sprites."
   - `DateTime.Now` inside `t描画` (a clock read per sprite).
   - Any managed allocation showing GC activity (look for `gc` frames).

The weights here tell you exactly which of the Step-1 hypotheses is real before you
change any code.

### 2.2 — GPU utilization & FPS (use when Step 1 says GPU-bound)

OpenGL ES is deprecated on iOS and modern Xcode **cannot do a GLES "Capture GPU Frame"**
(that's Metal-only now). So GPU work is measured indirectly:

- **Instruments → Game Performance** (or **Core Animation**) template: gives **FPS**,
  plus **GPU vs CPU utilization %** and the hitch/frame-time timeline. If GPU % pins at
  ~100 while CPU has headroom, you're GPU-bound — confirms the Step-1 swap reading.
- **Instruments → Metal System Trace:** iOS runs GLES *on top of* Metal, so this shows
  the underlying Metal command buffers and per-encoder GPU time on a timeline. Attribution
  back to individual GLES draws is poor (the shim batches them), but it reveals total GPU
  time per frame and whether the bottleneck is the render encoder (fill/overdraw) vs the
  blit.

### 2.3 — Confirming fill-rate / overdraw

The two prime GPU suspects here are **overdraw** (layered alpha-blended 2D) and the
**intermediate-FBO blit** (a full game-res store + reload every frame — a documented
follow-up in `CLAUDE.md`). To test cheaply:

- **Drop the render resolution** (game-res FBO smaller) and re-read `[Frame]`. If `swap`
  collapses and frame interval hits budget, you're **fill-rate bound** → attack overdraw
  and/or remove the FBO blit (integer-snap quads, per CLAUDE.md).
- **Bypass the FBO** for one experiment (draw straight to the device FB) and compare
  `blit` + `swap`. Quantifies exactly what the blit costs at native resolution.

---

## Putting it together

1. Land `szs` so 120 fps is actually requested.
2. Read the **`[Frame]` HUD/log** → CPU-bound or GPU-bound? (Step 1)
3. CPU-bound → **Time Profiler**, fix the hottest submission cost (batching, per-draw waste).
4. GPU-bound → **Game Performance / Metal System Trace** + the resolution/FBO experiments.
5. Re-read `[Frame]` after each change — it's the same number on every build, so it's the
   regression check too.
