import Testing
import VolumeCore

@testable import vmctl

@Suite("ConsoleText (vmctl output of untrusted data)")
struct ConsoleTextTests {
  private static let hostile = "com.evil.x\u{1B}]0;PWNED\u{07}\u{1B}[2J\u{9B}31m\u{202E}"

  private func hasNoControlOrFormat(_ text: String) -> Bool {
    !text.unicodeScalars.contains { scalar in
      if scalar == "\t" { return false }
      switch scalar.properties.generalCategory {
      case .control, .format: return true
      default: return false
      }
    }
  }

  @Test func processLineNeverContainsEscapes() {
    let process = AudioProcessInfo(
      pid: 42, bundleID: Self.hostile, executablePath: "/Apps/x\u{1B}[31m\u{202E}/y",
      responsiblePID: 7, isRunningOutput: true)
    let line = ConsoleText.line(for: process)
    #expect(hasNoControlOrFormat(line))
    #expect(line.hasPrefix("42\tPLAYING\tcom.evil.x"))
    #expect(line.hasSuffix("\tresponsible=7"))
    #expect(!line.contains("\u{1B}"))
  }

  /// M5.3: a process with input running (in a call) and its app are marked.
  @Test func inCallIsShown() {
    let process = AudioProcessInfo(pid: 3, isRunningInput: true)
    #expect(ConsoleText.line(for: process) == "3\tidle   \t-\t-\tin-call")
    let app = AudioApp(
      id: "com.a.b", name: "Call", bundleID: "com.a.b", pids: [3], isPlaying: false,
      isInCall: true)
    #expect(ConsoleText.line(for: app).hasSuffix(" [IN-CALL]"))
  }

  @Test func missingValuesPrintADash() {
    let line = ConsoleText.line(for: AudioProcessInfo(pid: 1))
    #expect(line == "1\tidle   \t-\t-")
    #expect(ConsoleText.safe("\u{1B}\u{07}") == "-")
    #expect(ConsoleText.safe(nil) == "-")
  }

  @Test func appLineIsSanitizedAndLimited() {
    let app = AudioApp(
      id: "id\u{1B}[0m", name: String(repeating: "N", count: 5_000) + "\u{202E}",
      bundleID: Self.hostile, pids: [3, 4], isPlaying: false)
    let line = ConsoleText.line(for: app)
    #expect(hasNoControlOrFormat(line))
    #expect(line.count < 600)
    #expect(line.hasSuffix("pids: 3,4"))
  }

  @Test func pathsKeepMoreCharactersThanNames() {
    let path = "/" + String(repeating: "a", count: 500)
    #expect(ConsoleText.safe(path, limit: ConsoleText.maxPathLength) == path)
    #expect(ConsoleText.safe(path).count == TextSanitizer.maxLength)
  }
}
