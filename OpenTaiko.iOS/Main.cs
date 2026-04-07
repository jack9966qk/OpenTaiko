using System;
using System.IO;
using UIKit;

namespace OpenTaiko.iOS;

public class Application {
	static void Main(string[] args) {
		UIApplication.Main(args, null, typeof(AppDelegate));
	}
}

/// <summary>
/// Writes .NET exception stack traces to Documents/CrashLogs/ so they survive
/// app termination. On next launch, previous crash logs are dumped to Console
/// (visible in device logs and retrievable via Xcode/iTunes file sharing).
/// </summary>
internal static class CrashLog {
	private static string GetCrashDir() =>
		Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "CrashLogs");

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

	public static void FlushPreviousCrashLogs() {
		try {
			string crashDir = GetCrashDir();
			if (!Directory.Exists(crashDir)) return;
			foreach (string file in Directory.GetFiles(crashDir, "crash_*.log")) {
				string content = File.ReadAllText(file);
				Console.WriteLine($"[OpenTaiko] Previous crash log ({Path.GetFileName(file)}):\n{content}");
				File.Delete(file);
			}
		} catch {
		}
	}
}
