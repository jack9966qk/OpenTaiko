using System.Runtime.InteropServices;
using Silk.NET.Core.Contexts;

namespace FDK;

/// <summary>
/// IGLContext implementation for iOS using EAGLContext.
/// The iOS host (GameViewController) creates the actual EAGLContext and renderbuffer,
/// then wraps it in this class so FDK's GL pipeline can use it.
///
/// GL function pointers are resolved via dlsym from the OpenGLES framework.
/// </summary>
public class iOSGLContext : IGLContext {
	private readonly nint _glFrameworkHandle;
	private readonly Action _swapBuffersAction;
	private readonly Action _makeCurrentAction;

	/// <summary>
	/// Creates a new iOS GL context wrapper.
	/// </summary>
	/// <param name="swapBuffers">Action to present the renderbuffer (call from host).</param>
	/// <param name="makeCurrent">Action to make the EAGLContext current (call from host).</param>
	public iOSGLContext(Action swapBuffers, Action makeCurrent) {
		_swapBuffersAction = swapBuffers;
		_makeCurrentAction = makeCurrent;

		// Load the OpenGLES framework to resolve GL function pointers
		_glFrameworkHandle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY);
		if (_glFrameworkHandle == IntPtr.Zero) {
			throw new Exception("Failed to load OpenGLES.framework");
		}
	}

	public nint Handle { get; set; }

	public IGLContextSource? Source { get; set; }

	public bool IsCurrent { get; set; } = true;

	public nint GetProcAddress(string proc, int? slot = null) {
		var addr = dlsym(_glFrameworkHandle, proc);
		if (_procDebugCount++ < 30)
			Console.WriteLine($"[iOSGL] GetProcAddress({proc}) => 0x{addr:X}");
		return addr;
	}
	private int _procDebugCount;

	public bool TryGetProcAddress(string proc, out nint addr, int? slot = null) {
		addr = dlsym(_glFrameworkHandle, proc);
		return addr != IntPtr.Zero;
	}

	public void SwapInterval(int interval) {
		// iOS uses CADisplayLink for vsync; swap interval is controlled by the host.
	}

	public void SwapBuffers() {
		_swapBuffersAction();
	}

	public void MakeCurrent() {
		_makeCurrentAction();
		IsCurrent = true;
	}

	public void Clear() {
	}

	public void Dispose() {
		if (_glFrameworkHandle != IntPtr.Zero) {
			dlclose(_glFrameworkHandle);
		}
	}

	// Native interop for dynamic library loading
	private const int RTLD_LAZY = 0x1;

	[DllImport("libdl.dylib")]
	private static extern nint dlopen(string path, int mode);

	[DllImport("libdl.dylib")]
	private static extern nint dlsym(nint handle, string symbol);

	[DllImport("libdl.dylib")]
	private static extern int dlclose(nint handle);
}
