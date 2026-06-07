using System;
using System.IO;
using UIKit;
#if !DEBUG
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Foundation;
#endif

namespace OpenTaiko.iOS;

public class Application {
	static void Main(string[] args) {
		// Install native crash handlers before the run loop starts (Release builds only — see
		// CrashLog). No-op on Debug builds.
		CrashLog.Install();
		UIApplication.Main(args, null, typeof(AppDelegate));
	}
}

/// <summary>
/// In-app crash reporter that writes crash reports to Documents/CrashLogs/ so they survive
/// app termination and can be retrieved via the Files app / iTunes file sharing
/// (UIFileSharingEnabled). Useful when TestFlight's crash console is not accessible. Reports
/// are retained (never deleted) and echoed to the device console on the next launch.
///
/// Managed .NET exceptions are captured via <see cref="Write"/>, called from the game-loop
/// try/catch (GameViewController.OnFrame); their stack traces already contain method names,
/// so no symbolication is needed — read the .log files directly.
///
/// Native crashes (POSIX signals from BASS/OpenGL/Skia/Lua/Mono) are captured by signal
/// handlers that write an Apple-style ".crash" report (Thread backtrace + Binary Images
/// table with load address + UUID per image) so it can be symbolicated against the build's
/// dSYM:
///     atos -o &lt;binary&gt;.dSYM/Contents/Resources/DWARF/&lt;binary&gt; -l &lt;load addr&gt; &lt;frame addr&gt;
///
/// IMPORTANT: the native signal-handler path is compiled into Release builds only (#if
/// !DEBUG). On the Mono runtime used by Debug/simulator builds, marshalling a managed
/// delegate / unmanaged function pointer as a signal handler — and even adding the extra
/// BCL API surface this code uses — aborts the process during startup (an AOT-module-load
/// fatal at runtime init). Release/device (TestFlight) uses AOT, where these constructs are
/// supported. See memory: project_ios_crash_reporting.
/// </summary>
internal static class CrashLog {
	private static string GetCrashDir() =>
		Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "CrashLogs");

	/// <summary>Record a managed exception. Called from GameViewController's try/catch sites.</summary>
	public static void Write(Exception? ex, string source) {
		if (ex == null) return;
		try {
			string crashDir = GetCrashDir();
			Directory.CreateDirectory(crashDir);
			string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss");
			string filename = $"crash_{timestamp}_{source}.log";
			string content = $"[{source}] {DateTime.UtcNow:O}\n{ex}\n";
			File.WriteAllText(Path.Combine(crashDir, filename), content);
			Console.Error.WriteLine($"[OpenTaiko CRASH] {content}");
		} catch {
		}
	}

	/// <summary>
	/// On launch: echo retained crash reports (.log managed + .crash native) to the console
	/// (visible in Console.app / Xcode device logs). Reports are NOT deleted — they must stay
	/// retrievable via the Files app / file sharing.
	/// </summary>
	public static void FlushPreviousCrashLogs() {
		try {
			string crashDir = GetCrashDir();
			if (!Directory.Exists(crashDir)) return;
			foreach (string file in Directory.GetFiles(crashDir, "crash_*.log")) {
				string content = File.ReadAllText(file);
				Console.WriteLine($"[OpenTaiko] Previous crash log ({Path.GetFileName(file)}):\n{content}");
			}
			foreach (string file in Directory.GetFiles(crashDir, "crash_*.crash")) {
				string content = File.ReadAllText(file);
				Console.WriteLine($"[OpenTaiko] Previous crash report ({Path.GetFileName(file)}):\n{content}");
			}
		} catch {
		}
	}

#if !DEBUG
	// ======================================================================================
	//  Native crash capture (Release builds only)
	// ======================================================================================

	// ---- Darwin signal / ABI constants -------------------------------------------------
	private const int SIGILL = 4, SIGTRAP = 5, SIGABRT = 6, SIGFPE = 8, SIGBUS = 10, SIGSEGV = 11, SIGSYS = 12;
	private const int SA_SIGINFO = 0x0040, SA_ONSTACK = 0x0001;
	private static readonly int[] HandledSignals = { SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS };

	// Faults below this address are treated as managed null-derefs that Mono converts to
	// NullReferenceExceptions; we forward them rather than reporting a crash.
	private const ulong NullDerefGuardLimit = 0x1000;

	private static readonly sigaction_t[] _oldHandlers = new sigaction_t[64];
	private static int _handling; // reentrancy guard for the signal handler
	private static bool _installed;

	// Environment captured once at install time (UIKit/Foundation access is unsafe from
	// within a signal handler, so we snapshot everything up front).
	private static string _procName = "OpenTaiko";
	private static string _bundleId = "";
	private static string _version = "";
	private static string _build = "";
	private static string _os = "";
	private static string _model = "";

	public static void Install() {
		if (_installed) return;
		_installed = true;
		CaptureEnvironment();
		InstallSignalHandlers();
	}

	private static unsafe void InstallSignalHandlers() {
		try {
			// [UnmanagedCallersOnly] + &method gives a native function pointer whose
			// native→managed wrapper is generated at AOT time. (Marshal.GetFunctionPointerForDelegate
			// fails here: its wrapper would need JIT, unavailable in aot-only mode.)
			IntPtr fp = (IntPtr)(delegate* unmanaged<int, IntPtr, IntPtr, void>)&NativeSignalHandler;
			foreach (int sig in HandledSignals) {
				var act = new sigaction_t {
					sa_handler = fp,
					sa_mask = 0,
					sa_flags = SA_SIGINFO | SA_ONSTACK,
				};
				sigaction(sig, ref act, out _oldHandlers[sig]);
			}
		} catch (Exception ex) {
			Console.Error.WriteLine($"[OpenTaiko CRASH] Failed to install signal handlers: {ex}");
		}
	}

	[UnmanagedCallersOnly]
	private static void NativeSignalHandler(int sig, IntPtr info, IntPtr ucontext) {
		bool reentrant = Interlocked.Exchange(ref _handling, 1) != 0;
		IntPtr faultAddr = info != IntPtr.Zero ? Marshal.ReadIntPtr(info, 24 /* si_addr offset */) : IntPtr.Zero;

		// Skip reporting for (a) reentrant faults (a crash while handling) and (b) likely
		// managed null-derefs Mono converts to NullReferenceExceptions. In both cases we just
		// forward to the previously installed (Mono/default) handler.
		bool likelyManagedNull = (sig == SIGSEGV || sig == SIGBUS) && (ulong)faultAddr < NullDerefGuardLimit;
		if (!reentrant && !likelyManagedNull) {
			try {
				WriteNativeReport(sig, faultAddr);
			} catch {
			}
		}

		// Hand off to the previously installed handler so Mono's own dump + termination (and
		// any OS/TestFlight report, or Mono's null-deref → NRE conversion) still happen.
		// Restore the previous disposition, then let the faulting instruction re-execute (for
		// hardware faults) or re-raise (for the rest). We forward this way rather than calling
		// the old handler via a function pointer because `calli` through an unmanaged function
		// pointer is rejected at load time by the Mono interpreter (non-AOT) builds.
		try {
			sigaction(sig, ref _oldHandlers[sig], out _);
		} catch {
		}
		_handling = 0;

		bool reExecutes = sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGFPE;
		if (!reExecutes)
			raise(sig);
		// else: return — the faulting instruction re-runs and hits the restored handler.
	}

	private static unsafe void WriteNativeReport(int sig, IntPtr faultAddr) {
		const int MaxFrames = 128;
		IntPtr* frames = stackalloc IntPtr[MaxFrames];
		int n = backtrace((void**)frames, MaxFrames);

		var sb = new StringBuilder();
		sb.Append(BuildHeader($"{SignalName(sig)} (signal {sig})", $"fault address 0x{(ulong)faultAddr:x16}"));

		sb.Append("Thread 0 Crashed:\n");
		// Track unique images appearing in the backtrace for the Binary Images section.
		var imageBases = new System.Collections.Generic.List<IntPtr>();
		for (int i = 0; i < n; i++) {
			IntPtr addr = frames[i];
			string imageName = "???";
			ulong fbase = 0;
			string symbolSuffix = "";
			if (dladdr(addr, out Dl_info dl) != 0) {
				fbase = (ulong)dl.dli_fbase;
				if (dl.dli_fname != IntPtr.Zero)
					imageName = Path.GetFileName(Marshal.PtrToStringAnsi(dl.dli_fname) ?? "???");
				if (!imageBases.Contains(dl.dli_fbase) && dl.dli_fbase != IntPtr.Zero)
					imageBases.Add(dl.dli_fbase);
				if (dl.dli_sname != IntPtr.Zero) {
					string sname = Marshal.PtrToStringAnsi(dl.dli_sname) ?? "";
					ulong saddr = (ulong)dl.dli_saddr;
					symbolSuffix = $"  ({sname} + {(ulong)addr - saddr})";
				}
			}
			// Apple frame layout: "<idx> <image> <absoluteAddr> <imageLoadAddr> + <offset>"
			ulong off = fbase != 0 ? (ulong)addr - fbase : 0;
			sb.Append(i.ToString().PadRight(4))
			  .Append(imageName.PadRight(32))
			  .Append("0x").Append(((ulong)addr).ToString("x16"))
			  .Append(" 0x").Append(fbase.ToString("x"))
			  .Append(" + ").Append(off)
			  .Append(symbolSuffix)
			  .Append('\n');
		}

		sb.Append("\nBinary Images:\n");
		foreach (IntPtr header in imageBases) {
			string name = "???";
			string path = "";
			if (dladdr(header, out Dl_info dl) != 0 && dl.dli_fname != IntPtr.Zero) {
				path = Marshal.PtrToStringAnsi(dl.dli_fname) ?? "";
				name = Path.GetFileName(path);
			}
			TryGetImageInfo(header, out string uuid, out ulong textSize, out int cpuType);
			ulong start = (ulong)header;
			ulong end = textSize > 0 ? start + textSize - 1 : start;
			sb.Append("0x").Append(start.ToString("x"))
			  .Append(" - 0x").Append(end.ToString("x"))
			  .Append(' ').Append(name)
			  .Append(' ').Append(CpuName(cpuType))
			  .Append("  <").Append(uuid).Append("> ")
			  .Append(path)
			  .Append('\n');
		}

		sb.Append("\nSymbolicate a frame with:\n")
		  .Append("  atos -o <binary>.dSYM/Contents/Resources/DWARF/<binary> -l <image load addr> <frame addr>\n");

		WriteReportFile(sb.ToString(), SignalName(sig));
		Console.Error.WriteLine($"[OpenTaiko CRASH] Native {SignalName(sig)} captured to Documents/CrashLogs/");
	}

	private static void WriteReportFile(string content, string source) {
		try {
			string crashDir = GetCrashDir();
			Directory.CreateDirectory(crashDir);
			string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff");
			string filename = $"crash_{timestamp}_{source}.crash";
			File.WriteAllText(Path.Combine(crashDir, filename), content);
		} catch {
		}
	}

	private static string BuildHeader(string exceptionType, string detail) {
		var sb = new StringBuilder();
		sb.Append("Incident Identifier: ").Append(Guid.NewGuid().ToString().ToUpperInvariant()).Append('\n');
		sb.Append("Process:             ").Append(_procName).Append('\n');
		sb.Append("Identifier:          ").Append(_bundleId).Append('\n');
		sb.Append("Version:             ").Append(_version).Append(" (").Append(_build).Append(")\n");
		sb.Append("OS Version:          ").Append(_os).Append("  Device: ").Append(_model).Append('\n');
		sb.Append("Date/Time:           ").Append(DateTime.UtcNow.ToString("O")).Append('\n');
		if (!string.IsNullOrEmpty(detail))
			sb.Append("Exception Codes:     ").Append(detail).Append('\n');
		sb.Append('\n');
		sb.Append("Exception Type:      ").Append(exceptionType).Append("\n\n");
		return sb.ToString();
	}

	// ---- Mach-O header parsing (read-only; used only while building a report) -----------

	private static unsafe bool TryGetImageInfo(IntPtr header, out string uuid, out ulong textSize, out int cpuType) {
		uuid = "00000000-0000-0000-0000-000000000000";
		textSize = 0;
		cpuType = 0;
		try {
			if (header == IntPtr.Zero) return false;
			byte* p = (byte*)header;
			uint magic = *(uint*)p;
			if (magic != 0xFEEDFACF) return false; // MH_MAGIC_64
			cpuType = *(int*)(p + 4);
			uint ncmds = *(uint*)(p + 16);
			byte* cmd = p + 32; // sizeof(mach_header_64)
			for (uint i = 0; i < ncmds; i++) {
				uint c = *(uint*)cmd;
				uint csize = *(uint*)(cmd + 4);
				if (csize < 8) break;
				if (c == 0x1B) { // LC_UUID
					uuid = FormatUuid(cmd + 8);
				} else if (c == 0x19) { // LC_SEGMENT_64
					if (SegNameIs(cmd + 8, "__TEXT"))
						textSize = *(ulong*)(cmd + 8 + 16 + 8); // segname[16], vmaddr(8), then vmsize(8)
				}
				cmd += csize;
			}
			return true;
		} catch {
			return false;
		}
	}

	private static unsafe string FormatUuid(byte* u) {
		var sb = new StringBuilder(36);
		for (int i = 0; i < 16; i++) {
			sb.Append(u[i].ToString("X2"));
			if (i == 3 || i == 5 || i == 7 || i == 9) sb.Append('-');
		}
		return sb.ToString();
	}

	private static unsafe bool SegNameIs(byte* seg, string name) {
		for (int i = 0; i < name.Length; i++)
			if (seg[i] != (byte)name[i]) return false;
		return seg[name.Length] == 0;
	}

	private static string CpuName(int cpuType) => cpuType switch {
		0x0100000C => "arm64",
		0x01000007 => "x86_64",
		_ => $"cpu_0x{cpuType:x}",
	};

	private static string SignalName(int sig) => sig switch {
		SIGILL => "SIGILL",
		SIGTRAP => "SIGTRAP",
		SIGABRT => "SIGABRT",
		SIGFPE => "SIGFPE",
		SIGBUS => "SIGBUS",
		SIGSEGV => "SIGSEGV",
		SIGSYS => "SIGSYS",
		_ => $"SIG{sig}",
	};

	private static void CaptureEnvironment() {
		try {
			_bundleId = NSBundle.MainBundle.BundleIdentifier ?? "";
			var info = NSBundle.MainBundle.InfoDictionary;
			_procName = info?["CFBundleName"]?.ToString() ?? "OpenTaiko";
			_version = info?["CFBundleShortVersionString"]?.ToString() ?? "";
			_build = info?["CFBundleVersion"]?.ToString() ?? "";
			var dev = UIDevice.CurrentDevice;
			_os = $"{dev.SystemName} {dev.SystemVersion}";
			_model = HwMachine(dev);
		} catch {
		}
	}

	private static string HwMachine(UIDevice dev) {
		try {
			nuint len = 0;
			if (sysctlbyname("hw.machine", null, ref len, IntPtr.Zero, 0) != 0 || len == 0)
				return dev.Model;
			var buf = new byte[(int)len];
			if (sysctlbyname("hw.machine", buf, ref len, IntPtr.Zero, 0) != 0)
				return dev.Model;
			int n = (int)len;
			if (n > 0 && buf[n - 1] == 0) n--;
			return Encoding.ASCII.GetString(buf, 0, n);
		} catch {
			return dev.Model;
		}
	}

	// ---- P/Invoke ----------------------------------------------------------------------

	[StructLayout(LayoutKind.Sequential)]
	private struct sigaction_t {
		public IntPtr sa_handler; // union of sa_handler / sa_sigaction (function pointer)
		public uint sa_mask;      // sigset_t is uint32 on Darwin
		public int sa_flags;
	}

	[StructLayout(LayoutKind.Sequential)]
	private struct Dl_info {
		public IntPtr dli_fname;
		public IntPtr dli_fbase;
		public IntPtr dli_sname;
		public IntPtr dli_saddr;
	}

	[DllImport("libc", SetLastError = true)]
	private static extern int sigaction(int sig, ref sigaction_t act, out sigaction_t oldact);

	[DllImport("libc")]
	private static extern int raise(int sig);

	[DllImport("libc")]
	private static extern unsafe int backtrace(void** array, int size);

	[DllImport("libc")]
	private static extern int dladdr(IntPtr addr, out Dl_info info);

	[DllImport("libc")]
	private static extern int sysctlbyname(string name, byte[]? oldp, ref nuint oldlenp, IntPtr newp, nuint newlen);
#else
	/// <summary>No-op on Debug builds (see class summary for why native handlers are Release-only).</summary>
	public static void Install() { }
#endif
}
