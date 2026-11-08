import Darwin
import Foundation

@testable import VolumeAudio

/// A test process that "plays" digital silence with `afplay -v 0` (SPEC 12.8.1: nothing
/// audible, ever). Terminated when `stop()` is called or the object is released.
final class SilentPlayer {
  private let process = Process()
  private let file: URL
  let pid: Int32

  /// Starts the player and waits until Core Audio lists it as an audio process.
  /// Returns `nil` if that does not happen (the hardware tests then skip themselves).
  init?(catalog: ProcessCatalog = ProcessCatalog()) async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("volume-audio-tests-\(UUID().uuidString)")
    guard
      (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true))
        != nil
    else { return nil }
    file = directory.appendingPathComponent("silence.wav")
    guard (try? Self.silentWAV(seconds: 120).write(to: file)) != nil else { return nil }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    process.arguments = ["-v", "0", file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else {
      try? FileManager.default.removeItem(at: directory)
      return nil
    }
    pid = process.processIdentifier
    for _ in 0..<100 {
      if catalog.processInfo(pid: pid)?.isRunningOutput == true { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
    stop()
    return nil
  }

  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
  }

  deinit { stop() }

  /// An 8 kHz mono 16-bit WAV that is all zeros.
  private static func silentWAV(seconds: Int) -> Data {
    let dataSize = seconds * 8_000 * 2
    var data = Data()
    func append32(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append32(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(8_000)
    append32(16_000)
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(UInt32(dataSize))
    data.append(Data(count: dataSize))
    return data
  }
}
