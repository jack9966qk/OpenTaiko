# iOS Memory Profiling Guide

How to diagnose OpenTaiko's memory use on iOS — from a quick "is it leaking?" glance
to naming the exact C++ allocation that's growing. Written from the workflow that found
the SkiaSharp typeface leak (1.8 GB → 780 MB).

## Background: what iOS actually kills you on

iOS jetsam kills a foreground app when its **`phys_footprint`** exceeds the per-process
limit (~2 GB on 4 GB devices, ~3 GB on 6 GB devices). `phys_footprint` counts dirty
private memory **plus compressed (swapped-out) pages** — so memory that looks "swapped
out" in `vmmap` still counts against you. The footprint splits into three buckets:

```
phys_footprint  ≈  managed (C# GC heap)  +  GL textures  +  everything-else-native
                                                            (skia, BASS, Mono, GL driver)
```

The whole game of profiling is attributing that **"everything-else-native"** bucket,
because it's the one no single number names for you.

---

## Step 0 — In-app diagnostics (always on, all builds)

`OpenTaiko.iOS/GameViewController.cs` reports memory every frame to the on-screen debug
HUD and every ~10 s to `Documents/OpenTaiko.log`:

```
[Mem] periodic: footprint=749 MB, managed=6 MB, textures=303 MB (349 live), stage=CStage演奏ドラム画面
```

`GetMemoryMB()` returns `(phys_footprint, GC.GetTotalMemory(false), CTexture.TotalTextureBytes)`.

**How to read it — this is the first triage:**

| Symptom | Meaning |
|---|---|
| `managed` large & growing | A C# retention bug (managed heap) |
| `managed` small, `textures` large | Texture residency — tune lazy-load / eviction |
| `managed` small, `textures` small, **`footprint` large** | **Native leak** (skia/BASS/GL) — go to Step 2 |
| `footprint` flat during gameplay, jumps at stage transitions | Per-load leak (cache miss), not per-frame |

The HUD's `Mem: fp.. mg.. tx..` line shows the same live on device.

---

## Step 1 — Forced-GC probe (managed vs unfinalized-native)

SkiaSharp/BASS objects are thin managed wrappers over native memory, freed only when the
wrapper's **finalizer** runs. Under a small managed heap the GC rarely runs, so native
memory balloons even though nothing is truly leaked. To tell "leaked" from "not yet
finalized", force a full collect + finalizer drain and re-read footprint:

```csharp
GC.Collect(2, GCCollectionMode.Forced, blocking: true);
GC.WaitForPendingFinalizers();
GC.Collect();
// then LogMemory("after-forced-gc")
```

- Footprint **collapses toward `mg+tx`** ⇒ the bytes were unfinalized native wrappers
  (the GC just wasn't running). Disposing them explicitly fixes it.
- Footprint **stays high** ⇒ something *retains* a managed reference (a cache, a static
  field) preventing finalization. Fix the retention, not just add `using`.

---

## Step 2 — Native heap attribution on the **simulator**

The simulator process is a **real macOS process**, so the full native heap toolchain
works on it — and the leaks here are platform-agnostic (skia/BASS), so the sim is a valid
place to find them. Launch with malloc stack logging so every allocation records a
backtrace (`SIMCTL_CHILD_` forwards env vars into the app):

```bash
# build + install
OpenTaiko.iOS/scripts/deploy.sh sim
# relaunch with stack logging armed
xcrun simctl terminate booted com.opentaiko.OpenTaiko
SIMCTL_CHILD_MallocStackLogging=1 xcrun simctl launch booted com.opentaiko.OpenTaiko
PID=$(pgrep -n OpenTaiko)
```

Drive the app through the suspect transitions (the sim does **not** auto-advance past the
StartUp screen — navigate manually), then:

```bash
# 1. Where did the bytes go? (footprint + malloc zones)
vmmap --summary $PID | grep -iE "Physical footprint|MALLOC_LARGE|MallocStackLogging|^TOTAL"

# 2. Which call stacks own the live allocations, largest first
malloc_history $PID -allBySize > /tmp/mh.txt          # one line per unique stack:
                                                       #   "N calls for X bytes: frame | frame | ..."

# 3. Strict leaks (definitely-unreachable), with backtraces
leaks $PID
```

`malloc_history -allBySize` groups live allocations by backtrace; grep it for managed
frames (`CSkiaSharpTextRenderer`, `SKTypeface_FromStream`, `CTexture`, `glTexImage`, …)
and sum the byte counts to rank the leak sources.

> **Caveats**
> - **Corpse cost:** `malloc_history`/`leaks`/`heap`/`vmmap` first freeze a *corpse*
>   (full copy) of the process and symbolicate it. On a 1–2 GB process this takes
>   **4–10 minutes** and a lot of RAM — slowness scales with leak size.
> - **Lite-mode undercount:** `MallocStackLogging=1` keeps a bounded ring of backtraces
>   and evicts older ones, so `malloc_history` may attribute only a *fraction* of the
>   live heap (the largest blocks). Treat its totals as a floor. Use Instruments →
>   Allocations (full recording) if you need every allocation.

---

## Step 3 — `heap` by-type classification (no stack logging)

`heap` classifies *all* live allocations by C++/ObjC type without needing stack logging,
and prints a size histogram — fast way to see the shape of the heap:

```bash
heap $PID > /tmp/heap.txt
```

Read two parts:

- **Class table** — `non-object` is raw `malloc` (skia/GL/BASS allocate this way, so
  most of OpenTaiko's heap shows here and `heap` *can't* name it without stack logging).
  The named rows below it (CFString, LLVM, UIKit…) are usually system noise.
- **`All zones: … Sizes:` histogram** — localizes the leak by block size even when
  untyped. e.g. `8112KB[48]` = 48 × 8.1 MB = ~389 MB of 1920×1080×4 **full-screen
  buffers**; `16640KB[2]` ≈ a couple of font typefaces. Match a suspicious size class to
  a `malloc_history` stack to confirm what it is.

---

## Step 4 — Device profiling (the number that matters)

The simulator distorts the picture (see below), so validate on hardware. The `[Mem]`
logging is compiled into all builds, so just deploy and pull the log:

```bash
# edited FDK/source? wipe obj/bin first to avoid the stale-AOT startup abort,
# then deploy WITHOUT --clean (preserves the installed app + its prior logs)
rm -rf OpenTaiko.iOS/obj OpenTaiko.iOS/bin FDK/obj FDK/bin OpenTaiko/obj OpenTaiko/bin
OpenTaiko.iOS/scripts/deploy.sh device     # device must be UNLOCKED at launch

# play through the suspect flow, then pull the log (destination must be a FILE, not a dir)
DEV=$(xcrun devicectl list devices | awk '/connected/{print $3; exit}')
xcrun devicectl device copy from --device "$DEV" \
  --domain-type appDataContainer --domain-identifier com.opentaiko.OpenTaiko \
  --source Documents/OpenTaiko.log --destination /tmp/dev_OpenTaiko.log
grep -a "\[Mem\]" /tmp/dev_OpenTaiko.log | tail -25
```

If the device launch is denied with `FBSOpenApplicationErrorDomain … Locked`, unlock the
phone and relaunch:
`xcrun devicectl device process launch --device "$DEV" com.opentaiko.OpenTaiko`.

---

## Simulator vs device — read with care

The simulator **inflates** memory in ways the device does not:

- **No eviction on the sim.** Texture eviction is triggered by `DidReceiveMemoryWarning`,
  and the simulator can't send memory warnings (`simctl` has no trigger). So *every*
  visited scene's textures stay resident on the sim; on device they're capped by the
  eviction tolerance.
- **LLVM / software-GL / Mono JIT overhead.** The sim runs a software GL renderer and the
  Mono interpreter/JIT (the `libLLVM…` entries in `heap`). A device Release build is
  AOT-compiled with a real GPU — hundreds of MB of sim-only overhead simply don't exist.

So: **find leaks on the sim** (precise native tooling, platform-agnostic bugs), but
**measure the real footprint on device** (`[Mem]` log).

---

## Worked example — the SkiaSharp typeface leak

1. **HUD/log triage:** `footprint` large, `managed` ≈ 6 MB, `textures` small → native leak.
2. **`malloc_history -allBySize` on the sim:** 300 MB (55 % of live native) in 18
   `CFontRenderer.Initialize → SKTypeface.FromStream` stacks — each loading the whole
   ~16.5 MB CJK font. Root cause: `SKPaint` doesn't own its `Typeface`, so it leaked even
   on dispose, and renderers were created per stage/HUD element.
3. **Fix:** cache `SKTypeface` by (font, style) and share it across paints.
4. **`heap` for the rest:** the residual `8112KB[48]` = 389 MB was full-screen GL
   textures — but that's the sim's no-eviction artifact, not a device bug.
5. **Device validation:** full song cycle landed at **~780 MB, flat in gameplay**
   (was OOM-ing at 3.0 GB in the field). Done.
