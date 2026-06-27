# iOS Metal Rendering — Desktop ANGLE Investigation & Decision

_2026-06-17_

## TL;DR

The desktop build already has a "Metal" graphics option, so the natural question was
whether iOS could reuse it instead of the custom Metal present-boundary we built. The
answer is **no**: the desktop "Metal" option is **ANGLE** (a full GL→Metal *driver*
translation) wired to desktop GLFW/Silk.NET windowing, while the iOS work is a much
smaller **present-boundary** change that leaves the renderer on Apple's GLES. The two are
different layers solving different problems, and the desktop path is physically unable to
attach to an iOS UIKit surface, ships no iOS binary, and would not clearly fix the measured
iOS bottleneck. iOS keeps its own present-boundary, exposed behind a settings toggle.

## Background: the goal and the bottleneck

Target: **120 fps on a real device** (ProMotion). Profiling (see
[`ios-rendering-profiling.md`](ios-rendering-profiling.md)) showed the iOS frame was
**serialization-bound**, not CPU- or GPU-bound: neither CPU (~33%) nor GPU (~34%) was
saturated, yet the frame ran ~72–86 fps. The cost was the *in-frame* FBO render→sample tile
resolve plus the EAGL buffer swap, both forced through Apple's deprecated GLES-on-Metal shim
and the CoreAnimation compositor that every iOS app must go through.

## What the desktop "Metal" option actually is

Selecting "Metal" in Settings sets `nGraphicsDeviceType = 3`
(`OpenTaiko/src/Stages/04.Config/CActConfigList.cs`), which maps to
`AnglePlatformType.Metal` (`OpenTaiko/src/Common/OpenTaiko.cs:519,538`). At startup the
desktop creates an **ANGLE** context:

```
FDK/src/01.Framework/Core/Game.cs:675   Context = new AngleContext(GraphicsDeviceType_, Window_, ...)
FDK/src/01.Framework/Rendering/Angle/AngleContext.cs
```

[ANGLE](https://chromium.googlesource.com/angle/angle) is Google's library that
**translates every OpenGL ES call into a native backend** (Metal, D3D11, Vulkan, …). So the
desktop "Metal" option replaces the GL *driver* wholesale: the FDK renderer keeps emitting GL
ES, and ANGLE re-emits it as Metal commands.

This is fundamentally different from the iOS work, which leaves the FDK renderer on Apple's
real GLES and only moves the **present/composite boundary** to Metal — GL renders the scene
into a shared IOSurface, and Metal samples + presents it via a `CAMetalLayer`
(`OpenTaiko.iOS/MetalPresenter.cs`, ~200 lines, FDK untouched).

## Why iOS cannot reuse the desktop Metal path

**1. It is bolted to desktop GLFW/Silk.NET windowing, which iOS bypasses.**
`AngleContext`'s constructor requires a native desktop window handle —
`window.Native.{Win32, X11, Cocoa, Wayland}` — and throws `"Window not found"` for anything
else (`AngleContext.cs:42-45`). iOS has none of those; its surface is UIKit
(`UIWindow`/`CAEAGLLayer`/`CAMetalLayer`). The iOS host never creates a Silk.NET window at
all: `Game.cs:284` returns early on iOS and the host drives the loop through
`InitWithExternalContext` with a native `EAGLContext`. There is no `IWindow` to hand ANGLE.

**2. There is no ANGLE binary in the iOS build.** ANGLE's `Egl.*` entry points
(`AngleContext.cs`) resolve to ANGLE's native `libEGL`/`libGLESv2`, shipped only with the
desktop build. iOS uses Apple's built-in EAGL GLES instead. Porting ANGLE to iOS is a
heavyweight, Chromium-derived dependency (build, binary size, ongoing maintenance) — "ANGLE
-scale", explicitly out of scope for a minimal iOS fix.

**3. The desktop "Metal" option is itself half-vestigial.** ANGLE's Metal backend only makes
sense on macOS, but the macOS branch (`Game.cs:655-661`) uses the native `Window_.GLContext`,
**not** `AngleContext`. `AngleContext` is only constructed on the non-macOS branch
(Windows/Linux), where Apple Metal does not exist. So there is not even a clean, exercised
"desktop Metal rendering path" to lift onto iOS.

**4. It would not clearly fix the measured iOS bottleneck.** The iOS problem is serialization
at the present boundary plus the mandatory CoreAnimation compositor. ANGLE changes how GL
becomes GPU work (it *might* improve CPU↔GPU pipelining) but it does not remove the compositor
path, and the intermediate-FBO tile resolve is partly a tile-based-GPU (TBDR) fundamental, not
just a shim artifact. That makes ANGLE a large, uncertain lever versus the targeted present-
boundary that already reached 120 fps.

## The chosen iOS approach

Own only the **present/composite** step in Metal, leaving the shared FDK GLES renderer
untouched:

1. FDK renders the scene through GLES into an **IOSurface-backed FBO** at game resolution.
2. The iOS host wraps that same IOSurface as an `MTLTexture` and presents it via a
   `CAMetalLayer`, replacing the in-frame GL blit + EAGL `SwapBuffers`.

This breaks the CPU↔GPU serialization (GL render becomes fire-and-forget + `glFlush`) and
reached **~120 fps on device** versus ~86 on the GL path. Hard-won device constraints
(IOSurface compat keys, GL-before-Metal bind order, identity sampling UV, render-target
resolution tracking) are documented in `MetalPresenter.cs`.

## Decision and trade-offs

| | Desktop "Metal" (ANGLE) | iOS present-boundary (chosen) |
|---|---|---|
| Layer | Whole GL driver (translation) | Present/composite only |
| Shared FDK renderer | Re-routed through ANGLE | Untouched (stays GLES) |
| iOS feasibility | Needs ANGLE port + UIKit EGL surface | Works with native EAGL + Metal |
| Size | "ANGLE-scale" dependency | ~200 lines, iOS-only |
| Fixes the measured bottleneck | Uncertain | Yes (120 fps confirmed) |

**Decision:** keep the iOS present-boundary as its own mechanism, independent of the desktop
`nGraphicsDeviceType`/ANGLE selector. A future full GL→Metal renderer or ANGLE adoption stays
a last resort (only if iOS becomes a primary target and the present-boundary is insufficient).

## Settings implication

Because the choice is iOS-specific and independent of the desktop graphics-API option, iOS
gets its own toggle ("Metal Renderer") plus a frame-rate cap (60 / Unlimited). The desktop
graphics-API list — which is inert on iOS and even shows a bogus device list there — is hidden
on iOS. The Metal toggle is **restart-applied** because the view's layer class
(`CAMetalLayer` vs `CAEAGLLayer`) is fixed in `LoadView()`, before the FDK config system
loads; the host reads the persisted flag directly from `Documents/Config.ini` at launch.

## References

- `ios-rendering-profiling.md` — the profiling that identified the serialization bottleneck
- `OpenTaiko.iOS/MetalPresenter.cs` — the present-boundary implementation
- `FDK/src/01.Framework/Rendering/Angle/AngleContext.cs` — the desktop ANGLE context
- `FDK/src/01.Framework/Core/Game.cs:284,655-675` — desktop vs iOS context creation
