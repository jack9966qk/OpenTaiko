using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using AVFoundation;
using CoreAnimation;
using CoreGraphics;
using Foundation;
using FDK;
using ObjCRuntime;
using OpenGLES;
using UIKit;

namespace OpenTaiko.iOS;

/// <summary>
/// Raw OpenGL ES 2.0 P/Invoke bindings for framebuffer management.
/// We use these instead of the Xamarin OpenGLES.GL wrapper (which has
/// a different API surface) for direct control over renderbuffers.
/// </summary>
internal static class GLES {
	private const string Lib = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES";

	public const uint GL_FRAMEBUFFER = 0x8D40;
	public const uint GL_RENDERBUFFER = 0x8D41;
	public const uint GL_COLOR_ATTACHMENT0 = 0x8CE0;
	public const uint GL_DEPTH_ATTACHMENT = 0x8D00;
	public const uint GL_DEPTH_COMPONENT16 = 0x81A5;
	public const uint GL_RENDERBUFFER_WIDTH = 0x8D42;
	public const uint GL_RENDERBUFFER_HEIGHT = 0x8D43;
	public const uint GL_FRAMEBUFFER_COMPLETE = 0x8CD5;

	[DllImport(Lib, EntryPoint = "glGenFramebuffers")]
	public static extern void GenFramebuffers(int n, out uint framebuffers);

	[DllImport(Lib, EntryPoint = "glBindFramebuffer")]
	public static extern void BindFramebuffer(uint target, uint framebuffer);

	[DllImport(Lib, EntryPoint = "glGenRenderbuffers")]
	public static extern void GenRenderbuffers(int n, out uint renderbuffers);

	[DllImport(Lib, EntryPoint = "glBindRenderbuffer")]
	public static extern void BindRenderbuffer(uint target, uint renderbuffer);

	[DllImport(Lib, EntryPoint = "glFramebufferRenderbuffer")]
	public static extern void FramebufferRenderbuffer(uint target, uint attachment, uint renderbuffertarget, uint renderbuffer);

	[DllImport(Lib, EntryPoint = "glRenderbufferStorage")]
	public static extern void RenderbufferStorage(uint target, uint internalformat, int width, int height);

	[DllImport(Lib, EntryPoint = "glGetRenderbufferParameteriv")]
	public static extern void GetRenderbufferParameteriv(uint target, uint pname, out int param);

	[DllImport(Lib, EntryPoint = "glCheckFramebufferStatus")]
	public static extern uint CheckFramebufferStatus(uint target);

	[DllImport(Lib, EntryPoint = "glDeleteFramebuffers")]
	public static extern void DeleteFramebuffers(int n, ref uint framebuffers);

	[DllImport(Lib, EntryPoint = "glDeleteRenderbuffers")]
	public static extern void DeleteRenderbuffers(int n, ref uint renderbuffers);

	[DllImport(Lib, EntryPoint = "glClearColor")]
	public static extern void ClearColor(float red, float green, float blue, float alpha);

	[DllImport(Lib, EntryPoint = "glClear")]
	public static extern void Clear(uint mask);
}

/// <summary>
/// UIView subclass that uses CAEAGLLayer instead of the default CALayer.
/// Required for OpenGL ES rendering — the layer class must be set at the view level.
/// </summary>
[Register("GLView")]
public class GLView : UIView {
	[Export("layerClass")]
	public static new Class GetLayerClass() {
		return new Class(typeof(CAEAGLLayer));
	}

	public GLView(CGRect frame) : base(frame) { }
}

/// <summary>
/// UIViewController that hosts the OpenTaiko game on iOS.
/// Creates an OpenGL ES 2.0 surface via CAEAGLLayer, drives the game loop
/// with CADisplayLink, and routes touch events to CInputTouch.
/// </summary>
public class GameViewController : UIViewController {
	private EAGLContext? _glContext;
	private uint _framebuffer;
	private uint _colorRenderbuffer;
	private uint _depthRenderbuffer;
	private int _backingWidth;
	private int _backingHeight;
	private int _swapDebug;
	private CADisplayLink? _displayLink;

	private global::OpenTaiko.OpenTaiko? _game;
	private iOSGLContext? _fdkContext;
	private CInputTouch? _touchInput;
	private CInputKeyboard_iOS? _keyboardInput;
	private bool _initialized;
	private NSObject? _resignActiveObserver;
	private NSObject? _becomeActiveObserver;
	private UILabel? _debugHud;
	private int _debugHudFrameCount;

	public override void LoadView() {
		// Install our custom GLView so that View.Layer is a CAEAGLLayer
		View = new GLView(UIScreen.MainScreen.Bounds);
	}

	public override void ViewDidLoad() {
		base.ViewDidLoad();

		// Enable multi-touch and configure the CAEAGLLayer
		View!.MultipleTouchEnabled = true;
		View.ContentScaleFactor = UIScreen.MainScreen.Scale;
		var eaglLayer = (CAEAGLLayer)View.Layer;
		eaglLayer.Opaque = true;
		eaglLayer.DrawableProperties = new NSDictionary(
			"kEAGLDrawablePropertyRetainedBacking", false,
			"kEAGLDrawablePropertyColorFormat", "kEAGLColorFormatRGBA8"
		);

		// Create OpenGL ES 2.0 context
		_glContext = new EAGLContext(EAGLRenderingAPI.OpenGLES2);
		if (_glContext == null) {
			throw new Exception("Failed to create EAGLContext");
		}
		EAGLContext.SetCurrentContext(_glContext);

		// Register for app lifecycle notifications
		_resignActiveObserver = NSNotificationCenter.DefaultCenter.AddObserver(
			UIApplication.WillResignActiveNotification, _ => OnResignActive());
		_becomeActiveObserver = NSNotificationCenter.DefaultCenter.AddObserver(
			UIApplication.DidBecomeActiveNotification, _ => OnBecomeActive());
	}

	public override void ViewDidLayoutSubviews() {
		base.ViewDidLayoutSubviews();

		Console.WriteLine($"[OpenTaiko] ViewDidLayoutSubviews: bounds={View!.Bounds.Width}x{View.Bounds.Height} scale={View.ContentScaleFactor}");

		// (Re)create framebuffer when the view size changes
		DestroyFramebuffer();
		CreateFramebuffer();

		Console.WriteLine($"[OpenTaiko] Framebuffer: {_backingWidth}x{_backingHeight}");

		if (!_initialized) {
			InitializeGame();
			_initialized = true;
		} else {
			_game?.iOSResize(_backingWidth, _backingHeight);
		}
	}

	private void CreateFramebuffer() {
		GLES.GenFramebuffers(1, out _framebuffer);
		GLES.BindFramebuffer(GLES.GL_FRAMEBUFFER, _framebuffer);

		GLES.GenRenderbuffers(1, out _colorRenderbuffer);
		GLES.BindRenderbuffer(GLES.GL_RENDERBUFFER, _colorRenderbuffer);

		// Allocate storage from the CAEAGLLayer drawable
		_glContext!.RenderBufferStorage((nuint)GLES.GL_RENDERBUFFER, (CAEAGLLayer)View!.Layer);

		GLES.GetRenderbufferParameteriv(GLES.GL_RENDERBUFFER, GLES.GL_RENDERBUFFER_WIDTH, out _backingWidth);
		GLES.GetRenderbufferParameteriv(GLES.GL_RENDERBUFFER, GLES.GL_RENDERBUFFER_HEIGHT, out _backingHeight);

		GLES.FramebufferRenderbuffer(GLES.GL_FRAMEBUFFER, GLES.GL_COLOR_ATTACHMENT0,
			GLES.GL_RENDERBUFFER, _colorRenderbuffer);

		// Depth buffer
		GLES.GenRenderbuffers(1, out _depthRenderbuffer);
		GLES.BindRenderbuffer(GLES.GL_RENDERBUFFER, _depthRenderbuffer);
		GLES.RenderbufferStorage(GLES.GL_RENDERBUFFER, GLES.GL_DEPTH_COMPONENT16, _backingWidth, _backingHeight);
		GLES.FramebufferRenderbuffer(GLES.GL_FRAMEBUFFER, GLES.GL_DEPTH_ATTACHMENT,
			GLES.GL_RENDERBUFFER, _depthRenderbuffer);

		var status = GLES.CheckFramebufferStatus(GLES.GL_FRAMEBUFFER);
		if (status != GLES.GL_FRAMEBUFFER_COMPLETE) {
			Trace.TraceError($"Framebuffer incomplete: 0x{status:X}");
		}
	}

	private void DestroyFramebuffer() {
		if (_framebuffer != 0) {
			GLES.DeleteFramebuffers(1, ref _framebuffer);
			_framebuffer = 0;
		}
		if (_colorRenderbuffer != 0) {
			GLES.DeleteRenderbuffers(1, ref _colorRenderbuffer);
			_colorRenderbuffer = 0;
		}
		if (_depthRenderbuffer != 0) {
			GLES.DeleteRenderbuffers(1, ref _depthRenderbuffer);
			_depthRenderbuffer = 0;
		}
	}

	/// <summary>
	/// Copy writable/user-facing assets from the app bundle to the Documents directory.
	/// Only copies if the target doesn't exist yet (first launch or new directory).
	/// Read-only assets (Global/, Lang/, Encyclopedia/, BGScriptAPI.lua) stay in the bundle
	/// and are resolved at runtime via OpenTaiko.ResolveAssetPath().
	/// </summary>
	private static void CopyBundleAssetsToDocuments() {
		string bundlePath = NSBundle.MainBundle.BundlePath;
		string docsPath = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

		// Copy writable directories to Documents. System/ is read directly from
		// the bundle via ResolveAssetPath()/GetMergedDirectories().
		// Songs/ is copied because the game writes uniqueID.json into song folders.
		string[] copyDirs = { "Songs", "Databases", ".init" };

		foreach (string dir in copyDirs) {
			string src = Path.Combine(bundlePath, dir);
			string dst = Path.Combine(docsPath, dir);
			if (!Directory.Exists(src)) continue;
			if (Directory.Exists(dst)) continue;
			CopyDirectory(src, dst);
		}

		// Create empty System/ in Documents so users can add custom skins via file sharing.
		// The bundled skin is resolved at runtime via GetMergedDirectories().
		string systemDir = Path.Combine(docsPath, "System");
		if (!Directory.Exists(systemDir))
			Directory.CreateDirectory(systemDir);
	}

	private static void CopyDirectory(string src, string dst) {
		Directory.CreateDirectory(dst);
		foreach (string file in Directory.GetFiles(src))
			File.Copy(file, Path.Combine(dst, Path.GetFileName(file)));
		foreach (string dir in Directory.GetDirectories(src))
			CopyDirectory(dir, Path.Combine(dst, Path.GetFileName(dir)));
	}

	/// <summary>
	/// Register a DllImport resolver so ManagedBass P/Invoke calls find the iOS xcframeworks.
	/// [DllImport("bass")] → @rpath/bass.framework/bass, etc.
	/// </summary>
	private static void RegisterBassResolver() {
		System.Runtime.InteropServices.DllImportResolver resolver =
			(libraryName, assembly, searchPath) => {
				// Map P/Invoke names to framework paths
				string frameworkName = libraryName switch {
					"bass" => "@rpath/bass.framework/bass",
					"bassmix" => "@rpath/bassmix.framework/bassmix",
					"bass_fx" => "@rpath/bass_fx.framework/bass_fx",
					_ => libraryName
				};
				if (System.Runtime.InteropServices.NativeLibrary.TryLoad(frameworkName, out var handle))
					return handle;
				return IntPtr.Zero;
			};
		// Register for all BASS assemblies (each is a separate DLL)
		System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(
			typeof(ManagedBass.Bass).Assembly, resolver);
		System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(
			typeof(ManagedBass.Mix.BassMix).Assembly, resolver);
		System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(
			typeof(ManagedBass.Fx.BassFx).Assembly, resolver);
	}

	private void InitializeGame() {
		Thread.CurrentThread.CurrentCulture = CultureInfo.InvariantCulture;
		Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

		// Activate iOS audio session and measure hardware output latency
		try {
			var audioSession = AVAudioSession.SharedInstance();
			audioSession.SetCategory(AVAudioSessionCategory.Playback);
			audioSession.SetActive(true);
			double hwLatency = audioSession.OutputLatency; // seconds
			double bufferDuration = audioSession.IOBufferDuration; // seconds
			int totalMs = (int)((hwLatency + bufferDuration) * 1000);
			FDK.CSoundDeviceBASS.iOSHardwareLatencyMs = totalMs;
		} catch (Exception ex) {
			System.Diagnostics.Trace.TraceWarning($"AVAudioSession activation failed: {ex.Message}");
		}

		// Register BASS native library resolver before any ManagedBass calls
		RegisterBassResolver();

		// Copy writable/user-facing assets from bundle to Documents directory.
		// Read-only assets (Global/, Lang/, etc.) are resolved from the bundle at runtime.
		CopyBundleAssetsToDocuments();
		global::OpenTaiko.OpenTaiko.strBundleフォルダ = NSBundle.MainBundle.BundlePath + Path.DirectorySeparatorChar;

		// Create input devices
		_touchInput = new CInputTouch();
		_keyboardInput = new CInputKeyboard_iOS();

		// Create the FDK GL context wrapper
		_fdkContext = new iOSGLContext(
			swapBuffers: () => {
				GLES.BindRenderbuffer(GLES.GL_RENDERBUFFER, _colorRenderbuffer);
				bool presented = _glContext!.PresentRenderBuffer((nuint)GLES.GL_RENDERBUFFER);
				if (_swapDebug++ % 300 == 0)
					Console.WriteLine($"[OpenTaiko] SwapBuffers: presented={presented}, fb={_framebuffer}, rb={_colorRenderbuffer}");
			},
			makeCurrent: () => {
				EAGLContext.SetCurrentContext(_glContext);
			}
		);

		// Register input devices for the game's input manager
		global::OpenTaiko.OpenTaiko.ExternalInputDevices = new List<FDK.IInputDevice> { _touchInput, _keyboardInput };

		// Create and initialize the game
		_game = new global::OpenTaiko.OpenTaiko();
		_game.InitWithExternalContext(_fdkContext, _backingWidth, _backingHeight);

		// Add touch overlay controls
		CreateTouchOverlay();
		CreateDebugHud();

		// Start the display link
		_displayLink = CADisplayLink.Create(OnFrame);
		_displayLink.PreferredFramesPerSecond = 60;
		_displayLink.AddToRunLoop(NSRunLoop.Current, NSRunLoopMode.Default);
	}

	private double _lastTimestamp;
	private int _lastDrumVisual = -1;
	private void OnFrame() {
		// Rebuild touch overlay if drum size settings changed
		int currentVisual = global::OpenTaiko.OpenTaiko.ConfigIni?.nTouchDrumVisual ?? 30;
		if (currentVisual != _lastDrumVisual) {
			_lastDrumVisual = currentVisual;
			_touchOverlay?.RemoveFromSuperview();
			CreateTouchOverlay();
		}

		if (_game == null || _game.IsExiting) {
			_displayLink?.Invalidate();
			return;
		}

		double now = _displayLink!.Timestamp;
		double delta = _lastTimestamp > 0 ? now - _lastTimestamp : 1.0 / 60.0;
		_lastTimestamp = now;

		EAGLContext.SetCurrentContext(_glContext);
		GLES.BindFramebuffer(GLES.GL_FRAMEBUFFER, _framebuffer);

		_game.iOSFrame(delta);

		if (++_debugHudFrameCount % 60 == 0)
			UpdateDebugHud();
	}

	#region Touch Input

	// HID usage codes: D=0x07(Ka-left), F=0x09(Don-left), J=0x0D(Don-right), K=0x0E(Ka-right), Escape=0x29
	private const long HID_D = 0x07, HID_F = 0x09, HID_J = 0x0D, HID_K = 0x0E, HID_ESC = 0x29;

	// Escape zone (normalized coords)
	private static readonly CGRect EscapeZone = new CGRect(0, 0, 0.10, 0.15);

	// Don circle: large semicircle centered below bottom edge, top portion visible
	private const double DonCenterX = 0.5;
	private const double DonCenterY = 1.05;
	// Single radius for both visual and hit detection
	private double DonRadius => (global::OpenTaiko.OpenTaiko.ConfigIni?.nTouchDrumVisual ?? 30) / 100.0;

	private UIView? _touchOverlay;
	private readonly Dictionary<IntPtr, long> _activeTouches = new();

	private void CreateTouchOverlay() {
		_touchOverlay = new UIView(View!.Bounds) {
			UserInteractionEnabled = false,
			BackgroundColor = UIColor.Clear
		};

		var bounds = View.Bounds;
		var w = bounds.Width;
		var h = bounds.Height;

		// Escape button (top-left rounded rect, inset by safe area)
		var safeInsets = View.SafeAreaInsets;
		var escRect = new CGRect(safeInsets.Left + 8, safeInsets.Top + 8, EscapeZone.Width * w - 8, EscapeZone.Height * h - 8);
		var escView = new UILabel(escRect) {
			BackgroundColor = UIColor.White.ColorWithAlpha(0.15f),
			Text = "ESC",
			TextColor = UIColor.White.ColorWithAlpha(0.5f),
			TextAlignment = UITextAlignment.Center,
			Font = UIFont.BoldSystemFontOfSize(14),
		};
		escView.Layer.CornerRadius = 10;
		escView.ClipsToBounds = true;
		_touchOverlay.AddSubview(escView);

		// Don circle — centered below bottom edge, clipped to show top portion
		var r = DonRadius * w;
		var cx = DonCenterX * w;
		var cy = DonCenterY * h;
		var donView = new UIView(new CGRect(cx - r, cy - r, r * 2, r * 2));
		donView.BackgroundColor = UIColor.FromRGBA(0xFF, 0x44, 0x44, 0x20);
		donView.Layer.CornerRadius = (nfloat)r;
		donView.Layer.BorderWidth = 1.5f;
		donView.Layer.BorderColor = UIColor.FromRGBA(0xFF, 0x44, 0x44, 0x40).CGColor;
		_touchOverlay.AddSubview(donView);

		View.AddSubview(_touchOverlay);
		View.ClipsToBounds = true;
	}

	private long HitTestTouchZone(CGPoint location) {
		var bounds = View!.Bounds;
		double w = bounds.Width;
		double h = bounds.Height;

		// Check escape zone (offset by safe area to match visual button)
		var safeInsets = View.SafeAreaInsets;
		if (location.X <= safeInsets.Left + EscapeZone.Width * w && location.Y <= safeInsets.Top + EscapeZone.Height * h) {
			return HID_ESC;
		}

		// Check Don circle in pixel space
		double dx = location.X - DonCenterX * w;
		double dy = location.Y - DonCenterY * h;
		double r = DonRadius * w;

		bool isLeft = location.X < w * 0.5;

		if (dx * dx + dy * dy <= r * r) {
			// Inside Don circle: F (left) / J (right)
			return isLeft ? HID_F : HID_J;
		}

		// Everywhere else is Ka: D (left) / K (right)
		return isLeft ? HID_D : HID_K;
	}

	public override void TouchesBegan(NSSet touches, UIEvent? evt) {
		base.TouchesBegan(touches, evt);
		foreach (UITouch touch in touches.Cast<UITouch>()) {
			var location = touch.LocationInView(View);
			long hidCode = HitTestTouchZone(location);
			if (hidCode >= 0) {
				_activeTouches[touch.Handle] = hidCode;
				_keyboardInput?.KeyDown(hidCode);
			}
		}
	}

	public override void TouchesEnded(NSSet touches, UIEvent? evt) {
		base.TouchesEnded(touches, evt);
		foreach (UITouch touch in touches.Cast<UITouch>()) {
			if (_activeTouches.TryGetValue(touch.Handle, out long hidCode)) {
				_keyboardInput?.KeyUp(hidCode);
				_activeTouches.Remove(touch.Handle);
			}
		}
	}

	public override void TouchesCancelled(NSSet touches, UIEvent? evt) {
		base.TouchesCancelled(touches, evt);
		foreach (UITouch touch in touches.Cast<UITouch>()) {
			if (_activeTouches.TryGetValue(touch.Handle, out long hidCode)) {
				_keyboardInput?.KeyUp(hidCode);
				_activeTouches.Remove(touch.Handle);
			}
		}
	}

	#endregion

	#region Keyboard Input

	public override void PressesBegan(NSSet<UIPress> presses, UIPressesEvent evt) {
		base.PressesBegan(presses, evt);
		foreach (UIPress press in presses.Cast<UIPress>()) {
			if (press.Key != null)
				_keyboardInput?.KeyDown((long)press.Key.KeyCode);
		}
	}

	public override void PressesEnded(NSSet<UIPress> presses, UIPressesEvent evt) {
		base.PressesEnded(presses, evt);
		foreach (UIPress press in presses.Cast<UIPress>()) {
			if (press.Key != null)
				_keyboardInput?.KeyUp((long)press.Key.KeyCode);
		}
	}

	public override void PressesCancelled(NSSet<UIPress> presses, UIPressesEvent evt) {
		base.PressesCancelled(presses, evt);
		foreach (UIPress press in presses.Cast<UIPress>()) {
			if (press.Key != null)
				_keyboardInput?.KeyUp((long)press.Key.KeyCode);
		}
	}

	#endregion

	public override bool PrefersStatusBarHidden() => true;

	public override bool ShouldAutorotate() => true;

	public override UIInterfaceOrientationMask GetSupportedInterfaceOrientations() {
		return UIInterfaceOrientationMask.Landscape;
	}

	public override UIInterfaceOrientation PreferredInterfaceOrientationForPresentation() {
		return UIInterfaceOrientation.LandscapeLeft;
	}

	#region App Lifecycle

	/// <summary>
	/// Called when the app resigns active (home button, Control Center, phone call, etc.).
	/// During gameplay, sends ESC to trigger in-game pause. Always pauses the display link.
	/// </summary>
	public void OnResignActive() {
		if (_displayLink == null || _game == null) return;

		// Only send ESC during gameplay (other stages: ESC navigates back or exits)
		bool isInGameplay = global::OpenTaiko.OpenTaiko.rCurrentStage?.eStageID == CStage.EStage.Game;
		if (isInGameplay) {
			// Press ESC down, run a frame so the game polls and detects the press, then release
			_keyboardInput?.KeyDown(HID_ESC);

			EAGLContext.SetCurrentContext(_glContext);
			GLES.BindFramebuffer(GLES.GL_FRAMEBUFFER, _framebuffer);
			_game.iOSFrame(1.0 / 60.0);

			_keyboardInput?.KeyUp(HID_ESC);
		}

		// Pause the display link
		_displayLink.Paused = true;
	}

	/// <summary>
	/// Called when the app becomes active again.
	/// Resumes the display link only — game stays paused until user manually unpauses.
	/// </summary>
	public void OnBecomeActive() {
		if (_displayLink == null) return;
		_displayLink.Paused = false;
	}

	#endregion

	private void CreateDebugHud() {
		var safeInsets = View!.SafeAreaInsets;
		_debugHud = new UILabel(new CGRect(
			View.Bounds.Width - 220 - safeInsets.Right,
			safeInsets.Top + 4,
			220, 60)) {
			BackgroundColor = UIColor.Black.ColorWithAlpha(0.5f),
			TextColor = UIColor.FromRGBA(0x00, 0xFF, 0x00, 0xCC),
			Font = UIFont.FromName("Menlo", 10) ?? UIFont.SystemFontOfSize(10),
			Lines = 0,
			TextAlignment = UITextAlignment.Left,
			UserInteractionEnabled = false,
		};
		_debugHud.Layer.CornerRadius = 6;
		_debugHud.ClipsToBounds = true;
		View.AddSubview(_debugHud);
	}

	private void UpdateDebugHud() {
		if (_debugHud == null) return;
		int fps = global::OpenTaiko.OpenTaiko.FPS?.NowFPS ?? 0;
		string stage = global::OpenTaiko.OpenTaiko.rCurrentStage?.eStageID.ToString() ?? "?";
		_debugHud.Text = $" FPS: {fps}  Stage: {stage}\n GL: {_backingWidth}x{_backingHeight}";
	}

	protected override void Dispose(bool disposing) {
		if (disposing) {
			if (_resignActiveObserver != null)
				NSNotificationCenter.DefaultCenter.RemoveObserver(_resignActiveObserver);
			if (_becomeActiveObserver != null)
				NSNotificationCenter.DefaultCenter.RemoveObserver(_becomeActiveObserver);
			_displayLink?.Invalidate();
			_game?.iOSShutdown();
			_game?.Dispose();
			DestroyFramebuffer();
			_fdkContext?.Dispose();
			if (_glContext != null) {
				if (EAGLContext.CurrentContext == _glContext) {
					EAGLContext.SetCurrentContext(null);
				}
				_glContext.Dispose();
			}
		}
		base.Dispose(disposing);
	}
}
