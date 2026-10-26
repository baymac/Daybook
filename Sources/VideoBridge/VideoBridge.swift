import AppKit
import CryptoKit
import Foundation

func readExactly(_ count: Int) -> Data? {
  var data = Data()
  while data.count < count {
    guard let part = try? FileHandle.standardInput.read(upToCount: count - data.count),
      !part.isEmpty
    else { return nil }
    data.append(part)
  }
  return data
}
func reply(_ body: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
  var length = UInt32(data.count).littleEndian
  withUnsafeBytes(of: &length) { FileHandle.standardOutput.write(Data($0)) }
  FileHandle.standardOutput.write(data)
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let manifest = executable.deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Resources/VideoExtension/manifest.json")
let infoURL = executable.deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Info.plist")
guard let infoData = try? Data(contentsOf: infoURL),
  let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
    as? [String: Any],
  let appID = info["CFBundleIdentifier"] as? String
else { exit(1) }
guard let data = try? Data(contentsOf: manifest),
  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
  let key = json["key"] as? String, let der = Data(base64Encoded: key)
else { exit(1) }
let digest = Array(SHA256.hash(data: der).prefix(16))
let alphabet = Array("abcdefghijklmnop")
let id = String(digest.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] })
guard CommandLine.arguments.dropFirst().first == "chrome-extension://\(id)/" else { exit(1) }
reply([
  "kind": "ready", "browserPID": getppid(),
  "appRunning": !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty,
])
while let header = readExactly(4) {
  let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
  guard length > 0, length <= 8192, let message = readExactly(Int(length)),
    let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
    Set(object.keys) == Set(["version", "nonce", "ciphertext"]),
    object["version"] as? Int == 2,
    let nonce = object["nonce"] as? String, nonce.count == 16,
    Data(base64Encoded: nonce)?.count == 12,
    let ciphertext = object["ciphertext"] as? String, ciphertext.count <= 5500,
    let sealed = Data(base64Encoded: ciphertext), sealed.count >= 16
  else { exit(1) }
  let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty
  if appRunning, let string = String(data: message, encoding: .utf8) {
    // Opaque authenticated ciphertext only. The bridge never has the pairing key.
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("local.daybook.mediaHeartbeat.v2"), object: string, userInfo: nil,
      deliverImmediately: true)
  }
  reply(["forwarded": appRunning, "appRunning": appRunning])
}
