import AppKit

@main enum NativeScriptTests {
  @MainActor static func main() {
    for id in [
      "com.apple.Music", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.spotify.client",
    ] {
      guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { continue }
      var error: NSDictionary?
      let script = NSAppleScript(source: NativePlayback.script(id))!
      guard script.compileAndReturnError(&error) else {
        fatalError("Native adapter failed to compile for \(id): \(String(describing:error))")
      }
      print("Native adapter compiles:", id)
    }
  }
}
