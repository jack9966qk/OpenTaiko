# iOS Release rendering fixes — black screen + performance (2026-06-18)

Record of two device-**Release**-only rendering issues and how they were fixed, so the next
person (or me) can see how it was diagnosed.

## 1. Black screen on the Metal present path (device Release only)

### Symptom
With the Metal present path enabled (`iOSUseMetalPresenter=1`), the app **ran** on device but
the scene **never drew** — pure black. It worked everywhere else:

| Build | Result |
|---|---|
| Device **Debug** (interpreter) | renders ✅ |
| **Simulator** Release (interpreter) | renders ✅ |
| Device **Release** (full AOT) | **black** ❌ |

The GL fallback path also rendered fine on device Release, which isolated the bug to the Metal
path specifically.

### Root cause
`MetalPresenter` binds the shared `IOSurface` to a GL texture via the private selector
`-[EAGLContext texImageIOSurface:target:internalFormat:width:height:format:type:plane:]`, which
has no managed binding, so it's called through `objc_msgSend` (`[DllImport("/usr/lib/libobjc.dylib")]`).

The P/Invoke declared the GL enum/size args as **32-bit `uint`/`int`**, but the selector takes
**`NSUInteger` (64-bit on arm64)**. Under the **Debug/simulator interpreter** the high 32 bits get
zero-extended, so the call works. Under **device Release (full AOT)** the high bits are left as
garbage → the method receives bogus `target`/`internalFormat`/`format`/`type` → returns `NO`
(without setting a GL error) → the GL texture has no storage → the FBO is
`GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT` (`0x8CD6`) → every draw fails with
`GL_INVALID_FRAMEBUFFER_OPERATION` (`0x506`) → black.

### Fix
Widen the args to `nuint` so the full 64-bit register/stack slots are written
(`OpenTaiko.iOS/MetalPresenter.cs`, the `MsgSendTexImageIOSurface` P/Invoke + call site).
After the fix the device log shows `texImage=1 status=0x8CD5` (`GL_FRAMEBUFFER_COMPLETE`) and zero
`0x506` errors.

### How it was diagnosed (after several wrong turns)
1. The in-app `[Frame]` profiler / launch console showed `glErr=0x506` every frame → a framebuffer
   completeness problem, not trimming/AOT-managed code (earlier hypotheses about the IL trimmer
   and `MtouchLink=None` were wrong — `MtouchLink=None` also made builds unusably slow by AOT-
   compiling the whole runtime via LLVM; reverted).
2. Pulled the device's full `Documents/OpenTaiko.log` (the 30s console stream misses early-launch
   lines). That revealed `[MetalPresenter] … status=0x8CD6 texImage=0` — i.e. the IOSurface bind
   itself failed.
3. Instrumented the call to log the handles + GL error: `texImage=0 texErr=0x0` with **valid**
   context/IOSurface/selector handles → the call was made correctly but the method returned NO →
   the only remaining suspect was **argument widths** → the `NSUInteger`-vs-`uint` mismatch.

### Lesson
- **Validate Release (AOT) on device, not just Debug (interpreter).** Debug device uses the Mono
  interpreter which masks ABI/marshaling bugs that only bite under AOT.
- `objc_msgSend` P/Invokes must match the selector's real arg widths exactly; `NSUInteger` is
  64-bit on arm64 — declaring it `uint` is a latent Release-only bug.

### Tooling added
`OpenTaiko.iOS/scripts/deploy.sh device` now pulls `Documents/OpenTaiko.log` off the device via
`devicectl device copy from … --domain-type appDataContainer` to `/tmp/opentaiko-device.log` after
the run — the launch-time lines the live console stream misses are what cracked this.

## 2. Performance — Release reaches 120fps

With the Metal present path working on device Release, **most scenes now hit 120fps** (the present
path breaks the in-frame GL-blit/EAGL-swap serialization that the GL fallback still has — the GL
path renders correctly but only ~70–90fps). The remaining sub-120 cases (dense gameplay hitches,
dojo ~40fps) are **main-thread CPU/draw-submission bound**, a separate workstream (see the per-
section draw profiling notes) — not this black-screen fix.
