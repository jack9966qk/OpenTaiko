namespace FDK;

/// <summary>
/// No-op sound device for platforms without audio (e.g. iOS prototype).
/// All sound creation returns null; all properties return safe defaults.
/// </summary>
internal class CSoundDeviceNull : ISoundDevice {
	public ESoundDeviceType SoundDeviceType => ESoundDeviceType.Unknown;
	public int nMasterVolume { get; set; }
	public long OutputDelay => 0;
	public long BufferSize => 0;
	public long ElapsedTimeMs => 0;
	public long UpdateSystemTimeMs => 0;
	public CTimer SystemTimer => null;

	public CSound tCreateSound(string strファイル名, ESoundGroup soundGroup) => null;
	public void tCreateSound(string strファイル名, CSound sound) { }
	public void Dispose() { }
}
