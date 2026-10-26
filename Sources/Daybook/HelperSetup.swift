import AppKit
import CryptoKit
import SwiftUI

@MainActor final class HelperInstaller: ObservableObject {
  @Published var status = "Download the matching helper, then connect your browser."
  @Published var busy = false
  @Published var prepared = false
  @Published var connected = false
  var browser = "Brave"
  var pairingCode = ""
  private var helperFolder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Daybook/BrowserHelper/Daybook-Helper", isDirectory: true)
  }
  private var extensionID: String {
    guard let data = try? Data(contentsOf: helperFolder.appendingPathComponent("manifest.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let key = json["key"] as? String, let der = Data(base64Encoded: key)
    else { return "" }
    let letters = Array("abcdefghijklmnop")
    return String(
      SHA256.hash(data: der).prefix(16).flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 15)]] })
  }

  func download() {
    guard !busy else { return }
    busy = true
    status = "Downloading Daybook Helper from GitHub…"
    Task {
      do {
        let version =
          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard !version.isEmpty,
          let url = URL(
            string:
              "https://github.com/baymac/Daybook/releases/download/v\(version)/Daybook-Helper.zip")
        else { throw SetupError.invalidDownload }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          throw SetupError.downloadUnavailable
        }
        try prepare(data)
      } catch {
        status = "\(error.localizedDescription) You can use the helper included with this app. "
      }
      busy = false
    }
  }

  func useIncluded() {
    guard !busy else { return }
    do {
      guard let url = Bundle.main.resourceURL?.appendingPathComponent("Daybook-Helper.zip") else {
        throw SetupError.invalidDownload
      }
      try prepare(Data(contentsOf: url))
    } catch { status = error.localizedDescription }
  }

  private func prepare(_ data: Data) throws {
    guard data.count < 5_000_000,
      let expected = Bundle.main.object(forInfoDictionaryKey: "DaybookHelperSHA256") as? String,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected
    else { throw SetupError.invalidDownload }
    let parent = helperFolder.deletingLastPathComponent()
    let fm = FileManager.default
    try fm.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stage = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    let zip = stage.appendingPathComponent("helper.zip")
    try data.write(to: zip)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    task.arguments = ["-x", "-k", zip.path, stage.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
    let extracted = stage.appendingPathComponent("Daybook-Helper", isDirectory: true)
    guard task.terminationStatus == 0,
      fm.fileExists(atPath: extracted.appendingPathComponent("manifest.json").path)
    else { throw SetupError.invalidDownload }
    // Generated only on this Mac; never included in release assets or the repository.
    let pairing = try JSONSerialization.data(withJSONObject: [
      "pairingCode": pairingCode, "enabled": true, "installID": UUID().uuidString,
    ])
    try pairing.write(to: extracted.appendingPathComponent("local-pairing.json"), options: .atomic)
    let previous = parent.appendingPathComponent("previous")
    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
    if fm.fileExists(atPath: helperFolder.path) { try fm.moveItem(at: helperFolder, to: previous) }
    do { try fm.moveItem(at: extracted, to: helperFolder) } catch {
      if fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: helperFolder) }
      throw error
    }
    try? fm.removeItem(at: previous)
    prepared = true
    status = "Helper verified and paired locally. Connect the browser next."
  }

  func connect() {
    let panel = NSOpenPanel()
    panel.title = "Connect Daybook Helper to \(browser)"
    panel.message =
      "Choose your Library/Application Support folder. Daybook adds only its native-messaging registration in your browser’s folder."
    panel.prompt = "Connect browser"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    if let home = NSHomeDirectoryForUser(NSUserName()) {
      panel.directoryURL = URL(fileURLWithPath: home).appendingPathComponent(
        "Library/Application Support")
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      guard url.lastPathComponent == "Application Support", !extensionID.isEmpty,
        let executable = Bundle.main.executableURL?.deletingLastPathComponent()
          .appendingPathComponent("DaybookVideoBridge")
      else { throw SetupError.wrongFolder }
      // Brave uses Chrome's compatibility location for native host manifests.
      let path =
        browser == "Edge"
        ? "Microsoft Edge/NativeMessagingHosts" : "Google/Chrome/NativeMessagingHosts"
      let hosts = url.appendingPathComponent(path, isDirectory: true)
      try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
      let manifest: [String: Any] = [
        "name": "local.daybook.video", "description": "Daybook Helper local connection",
        "path": executable.path,
        "type": "stdio", "allowed_origins": ["chrome-extension://\(extensionID)/"],
      ]
      try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: hosts.appendingPathComponent("local.daybook.video.json"), options: .atomic)
      connected = true
      status = "Connected. Load the helper in \(browser), then reload any open media tabs."
    } catch { status = error.localizedDescription }
  }

  func reveal() { NSWorkspace.shared.activateFileViewerSelecting([helperFolder]) }
  func openBrowser() {
    let id =
      browser == "Brave"
      ? "com.brave.Browser" : browser == "Edge" ? "com.microsoft.edgemac" : "com.google.Chrome"
    let scheme = browser == "Brave" ? "brave" : browser == "Edge" ? "edge" : "chrome"
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
      let url = URL(string: "\(scheme)://extensions")
    else {
      status = "Install \(browser) first."
      return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = [url.absoluteString]
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: app, configuration: config) { [weak self] _, error in
      if error != nil {
        Task { @MainActor in
          self?.status =
            "Open \(scheme)://extensions in \(self?.browser ?? "your browser") to load the helper."
        }
      }
    }
  }
  private enum SetupError: LocalizedError {
    case invalidDownload, downloadUnavailable, wrongFolder
    var errorDescription: String? {
      switch self {
      case .invalidDownload: return "The helper did not match this app’s verified release."
      case .downloadUnavailable: return "The GitHub download is unavailable."
      case .wrongFolder:
        return "Choose the Library/Application Support folder to connect the browser."
      }
    }
  }
}

struct HelperSetupView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var installer = HelperInstaller()
  @State private var browser = "Brave"
  let pairingCode: String
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Image(systemName: "puzzlepiece.extension.fill").font(.title).foregroundStyle(Paper.teal)
        VStack(alignment: .leading, spacing: 4) {
          Text("Daybook Helper").font(.title2.weight(.semibold))
          Text("Visible video. Background music. All tracked locally.").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text("1  Get the helper").font(.headline)
        Text(
          "Download the matching release from GitHub. Daybook verifies it and pairs it on this Mac."
        ).font(.callout).foregroundStyle(.secondary)
        HStack {
          Button("Download from GitHub", action: installer.download).buttonStyle(.borderedProminent)
            .disabled(installer.busy)
          Button("Use included helper", action: installer.useIncluded).disabled(installer.busy)
          if installer.busy { ProgressView().controlSize(.small) }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        Text("2  Connect your browser").font(.headline)
        HStack {
          Picker("Browser", selection: $browser) {
            ForEach(["Brave", "Chrome", "Edge"], id: \.self) { Text($0) }
          }.frame(width: 190)
          Button("Connect browser", action: installer.connect).disabled(!installer.prepared)
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        Text("3  Allow the extension").font(.headline)
        Text(
          "Open Extensions, enable Developer mode, choose Load unpacked, and select the Daybook-Helper folder. Approve website access for embedded players, then reload media tabs. Pairing is already prepared."
        ).font(.callout).foregroundStyle(.secondary)
        HStack {
          Button("Open Extensions", action: installer.openBrowser)
          Button("Show helper folder", action: installer.reveal)
        }.disabled(!installer.connected)
      }
      Text(installer.status).font(.callout).foregroundStyle(Paper.teal).fixedSize(
        horizontal: false, vertical: true)
      Text(
        "The GitHub request downloads software only. Activity and pairing data are never sent. The helper exchanges domain, playback, sound and visibility signals locally; no page text, video or audio recordings."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.padding(28).frame(width: 590).controlSize(.large)
      .background(Paper.background).foregroundStyle(Paper.ink).tint(Paper.controlAccent)
      .onAppear {
        installer.pairingCode = pairingCode
        installer.browser = browser
      }
      .onChange(of: browser) { _, value in
        installer.browser = value
        installer.connected = false
      }
  }
}
