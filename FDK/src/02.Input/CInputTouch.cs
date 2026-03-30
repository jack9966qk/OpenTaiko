namespace FDK;

/// <summary>
/// Touch input device for iOS (and potentially Android).
/// Maps touch events in screen zones to button indices:
///   0 = Left Rim (Ka-left)
///   1 = Left Center (Don-left)
///   2 = Right Center (Don-right)
///   3 = Right Rim (Ka-right)
/// The host platform feeds touch events via TouchBegan/TouchEnded.
/// </summary>
public class CInputTouch : CInputButtonsBase {
	public const int BUTTON_LEFT_RIM = 0;
	public const int BUTTON_LEFT_CENTER = 1;
	public const int BUTTON_RIGHT_CENTER = 2;
	public const int BUTTON_RIGHT_RIGHT = 3;
	public const int BUTTON_COUNT = 4;

	public CInputTouch() : base(BUTTON_COUNT) {
		this.CurrentType = InputDeviceType.Touch;
		this.Name = "Touch Screen";
		this.GUID = "touch-screen";
		this.ID = 0;
	}

	// IInputDevice.Device — touch has no Silk.NET backing device
	public new Silk.NET.Input.IInputDevice? Device => null;

	/// <summary>
	/// Called by the platform host when a touch begins.
	/// normalizedX is 0.0 (left edge) to 1.0 (right edge).
	/// </summary>
	public void TouchBegan(float normalizedX) {
		int button = GetButtonForPosition(normalizedX);
		ButtonDown(button);
	}

	/// <summary>
	/// Called by the platform host when a touch ends.
	/// </summary>
	public void TouchEnded(float normalizedX) {
		int button = GetButtonForPosition(normalizedX);
		ButtonUp(button);
	}

	/// <summary>
	/// Maps a horizontal screen position to a drum zone button index.
	/// Layout: [Ka-L 0-25%] [Don-L 25-50%] [Don-R 50-75%] [Ka-R 75-100%]
	/// </summary>
	private static int GetButtonForPosition(float normalizedX) {
		if (normalizedX < 0.25f) return BUTTON_LEFT_RIM;
		if (normalizedX < 0.50f) return BUTTON_LEFT_CENTER;
		if (normalizedX < 0.75f) return BUTTON_RIGHT_CENTER;
		return BUTTON_RIGHT_RIGHT;
	}

	public override string ToString() => "Touch Screen";
}
