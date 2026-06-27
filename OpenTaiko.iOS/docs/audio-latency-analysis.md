# iOS Audio Latency Analysis

## Root Causes (in order of impact)

### 1. Hardcoded 100ms safety margin
In `CSoundDeviceBASS.cs`, the iOS path sets:
```csharp
this.OutputDelay = info.Latency + 100;
```
Desktop BASS uses `info.Latency + bufferSize` (typically ~15ms). This 100ms padding alone accounts for most of the perceived delay.

### 2. Timer falls back to OS clock, not audio position
On desktop, `StreamProc` continuously updates `ElapsedTimeMs` by counting bytes transferred through the mixer — this is audio-synchronized timing. On iOS, since there's no mixer/StreamProc, the timer falls back to `Game.TimeMs` (a raw Stopwatch). Game logic and audio output are completely decoupled — the game has no idea where audio playback actually is.

### 3. No latency compensation in hit judgment
Hit timing windows (±25-75ms for Perfect) are applied identically on all platforms. Desktop with ~15ms latency is fine; iOS with ~100-150ms latency means hits are consistently late relative to the audio.

### 4. BASS iOS buffer configuration
iOS sets `DeviceBufferLength = 40ms` but doesn't set `UpdatePeriod` or `PlaybackBufferLength`. CoreAudio manages its own buffering on top of this, adding unknown latency.

## What can be measured automatically?

We can measure the **round-trip perceived latency** by comparing `Bass.ChannelGetPosition()` against the game timer. For any playing stream, `Bass.ChannelGetPosition` returns how many bytes BASS has fed to CoreAudio — comparing this timestamp against `Game.TimeMs` gives us the actual offset.

However, the **output latency** (CoreAudio buffer → speaker) can't be measured from software alone. We'd need user calibration or Apple's `AVAudioSession.outputLatency` property.

## Recommended fixes

1. **Query `AVAudioSession.outputLatency`** at startup for the real hardware latency instead of the hardcoded +100ms
2. **Reduce the safety margin** from 100ms to something much smaller (10-20ms)
3. **Add a user-configurable audio offset** in ConfigIni for manual calibration
4. **Periodically query `Bass.ChannelGetPosition()`** on active streams to track actual audio position instead of relying on OS timer

## Key files

| File | Role |
|------|------|
| `FDK/src/03.Sound/CSoundDeviceBASS.cs` | iOS vs desktop init, OutputDelay calculation |
| `FDK/src/03.Sound/CSoundTimer.cs` | Timer compensation logic, bUseOSTimer branching |
| `FDK/src/03.Sound/SoundManager.cs` | Configuration defaults, bUseOSTimer flag |
| `OpenTaiko/src/Stages/07.Game/CStage演奏画面共通.cs` | Hit timing judgment |
| `OpenTaiko/src/Common/CConfigIni.cs` | Timing zone windows |
