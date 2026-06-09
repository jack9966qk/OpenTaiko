# iOS crash reporting

OpenTaiko's iOS port writes crash reports to a local, user-retrievable directory so that
testers (who may not have App Store Connect / TestFlight console access) can hand back a report
that pins down the crash. It is self-contained: **no network, no backend, no third-party SDK.**

All of it lives in [`Main.cs`](Main.cs), class `CrashLog`. `CrashLog.Install()` is called from
`Application.Main` before `UIApplication.Main`, so handlers are in place before any game code runs.

## Goals & non-goals

- **Goal:** capture, to a local file, essentially every crash the process can observe — both
  **managed (C#) exceptions** and **native faults** — in a form that can be symbolicated later.
- **Non-goal:** OS terminations that deliver no signal/exception — **out of memory (jetsam),
  watchdog timeouts (`0x8badf00d`), and `SIGKILL`**. Nothing in-process can capture these; they
  exist only in Apple's on-device Analytics logs. A rhythm game loading large audio/textures on
  stage entry is a realistic OOM source, so a missing report there may be one of these.

## Two capture paths

The two crash classes want different artifacts, so there are two independent paths.

### Path A — managed / C# exceptions → `.log`

A managed exception's own `.ToString()` already contains the message and a **full C# stack with
method names** (from embedded PDBs), so these reports need **no symbolication**.

| Source | Mechanism |
| --- | --- |
| Main / render thread | `GameViewController.OnFrame`'s `try/catch` → `CrashLog.Write(ex, "OnFrame")` |
| Any other thread (background song/stage loaders, tasks, UIKit callbacks) | `AppDomain.CurrentDomain.UnhandledException` → `CrashLog.Write(ex, "UnhandledException")` |

`CrashLog.Write` writes `crash_<utc-timestamp>_<source>.log` containing `[source] <time>` followed
by `ex.ToString()`.

> The in-app Settings → "[TEST] Trigger crash" item throws on the render thread, so it exercises
> the `OnFrame` path. It does **not** test the background-thread or native paths.

### Path B — native faults → `.crash`

Native faults (SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGABRT / SIGTRAP / SIGSYS) from native code
(BASS, SkiaSharp, OpenGL ES, Lua, the Mono runtime), and the `SIGABRT` Mono raises after an
unhandled managed exception, are caught by a POSIX `sigaction` handler and written as an
Apple-style `.crash`.

The hard requirement here is **async-signal-safety**: a signal handler must not allocate, take
locks, or touch the managed heap / `File` API — after a real fault the crashing thread may hold
the GC or malloc lock, so doing any of that deadlocks or re-faults and **no report is written**.
(An earlier version did all of that; it worked for `kill -ABRT` at a "clean" point but silently
failed on real faults.)

To stay async-signal-safe, the work is split:

- **At `Install()` time** (`PrepareNativeReport`, ordinary managed code): pre-build and **pin**
  (`GCHandle`) two byte buffers — the report **prefix** (header + a full **Binary Images** table:
  every loaded image's load-address range + UUID, via `_dyld_*` + Mach-O parsing) and the report
  **file path**. Also install a dedicated **`sigaltstack`** so the handler can run even when the
  faulting thread's own stack is exhausted (stack overflow), and pre-create an empty pending file.
- **In the handler** (`NativeSignalHandler`, `[UnmanagedCallersOnly]`): only async-signal-safe
  calls — `open` the pending file, `write` the pinned prefix and a signal line formatted into a
  stack buffer (no-alloc hex/dec helpers), then `backtrace` + `backtrace_symbols_fd` to dump the
  crash backtrace straight to the fd, then `close`.

Handler guards:

- **Reentrancy guard** — if a fault occurs while handling, skip reporting and forward.
- **Near-null faults** (`< 0x1000`) are treated as managed null-derefs (which Mono turns into
  `NullReferenceException`) and forwarded rather than reported.
- After writing, it **restores the previous (Mono) handler** and re-raises / re-executes, so
  Mono's own crash dump and normal process termination still happen.

Because of that last point, an unhandled C# exception produces **both** a `.log` (Path A, the
useful one) and a `.crash` (Path B, a native backtrace of the abort). That redundancy is harmless.

## Storage & retrieval

- Everything goes to `Documents/CrashLogs/`, surfaced to the Files app via `UIFileSharingEnabled`.
  Reports are **never deleted**.
- Managed: `crash_<ts>_<source>.log` (one per crash, millisecond timestamp).
- Native: the handler writes a fixed `crash_native_latest.crash`. On the next launch
  `PrepareNativeReport` renames a non-empty one to `crash_<ts>_native.crash` (retain) and
  re-creates the empty pending file (the handler can't rename safely from signal context).
- `CrashLog.FlushPreviousCrashLogs()` (called once on launch) echoes retained reports to the device
  console (visible in Console.app / Xcode) and skips the empty pending file.

## Symbolicating a native `.crash`

The report contains a `Binary Images:` table (each image's load address + UUID) and a backtrace of
`<image> <absolute addr> <symbol + offset>`. For a precise source location, use the matching dSYM:

```
atos -o <App>.app.dSYM/Contents/Resources/DWARF/<App> -l <image load addr from Binary Images> <frame addr>
```

The dSYM must match the build (UUID). Release builds emit it as the `OpenTaiko_unsigned.dSYM.zip`
asset alongside the IPA — keep it per version.

Managed `.log` files are already symbolic (method names + lines) and need no dSYM.

## Build / runtime constraints

- The native handler and the `AppDomain.UnhandledException` hook are **Release/AOT only**
  (`#if !DEBUG`). Debug runs the Mono **interpreter**, which aborts at startup on these constructs
  (`[UnmanagedCallersOnly]`, function pointers); Debug therefore gets the managed `.log` path only.
- The handler uses `[UnmanagedCallersOnly]` + a `&method` function pointer for `sigaction`. This is
  the only form that works under `aot-only` mode — `Marshal.GetFunctionPointerForDelegate` throws
  `ExecutionEngineException` (its wrapper would need the JIT).
- Build/test via `scripts/deploy.sh` / `scripts/launch-test.sh`. **A change that "crashes at
  startup" in Release is almost always stale `obj/` pollution from incremental AOT builds**, not the
  code — re-test with a true clean (`deploy.sh --clean` wipes `obj/`+`bin/` of OpenTaiko.iOS, FDK,
  and OpenTaiko) before blaming the change.

## Verified

On a true-clean Release simulator build (which is `aot-only`, like device): app launches; an
unhandled **background-thread** C# exception produces a `.log` with the managed stack; a native
`SIGSEGV` produces a `.crash` with the header, Binary Images table, signal line + fault address,
and a backtrace pointing at the faulting frame. Device/TestFlight uses the same Release/AOT path.
