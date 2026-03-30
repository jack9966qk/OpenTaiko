// On iOS, the Mono AOT compiler requires [MonoPInvokeCallback] on methods
// called from native code via delegates. FDK targets net8.0 (not net8.0-ios)
// so it doesn't have ObjCRuntime — we define a compatible attribute here.
// The AOT compiler matches by full type name (ObjCRuntime.MonoPInvokeCallbackAttribute).

namespace ObjCRuntime {
	[AttributeUsage(AttributeTargets.Method)]
	internal sealed class MonoPInvokeCallbackAttribute : Attribute {
		public MonoPInvokeCallbackAttribute(Type delegateType) { }
	}
}
