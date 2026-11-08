import Testing
import VolumeCore

@testable import vmctl

@Suite("QA M2.1: vmctl console text (B-1)")
struct QAConsoleTextM21Tests {
  private static let hostileScalars: [(String, Unicode.Scalar)] = [
    ("ESC", "\u{1B}"), ("BEL", "\u{07}"), ("NUL", "\u{00}"), ("DEL", "\u{7F}"),
    ("CSI C1", "\u{9B}"), ("OSC C1", "\u{9D}"), ("C1 NEL", "\u{85}"), ("C1 low", "\u{80}"),
    ("C1 high", "\u{9F}"), ("RLO", "\u{202E}"), ("LRE", "\u{202A}"), ("RLI", "\u{2067}"),
    ("ZWSP", "\u{200B}"), ("BOM", "\u{FEFF}"), ("WJ", "\u{2060}"), ("SHY", "\u{AD}"),
    ("LRM", "\u{200E}"), ("tag", "\u{E0041}"),
  ]

  @Test func consoleTextRemovesEveryHostileScalar() {
    for (label, scalar) in Self.hostileScalars {
      let text = ConsoleText.safe("ok\(scalar)\u{1B}]0;title\u{07}x\(scalar)")
      let bad = text.unicodeScalars.contains {
        switch $0.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
      }
      #expect(!bad, "\(label) survived: \(text.debugDescription)")
      #expect(text.hasPrefix("ok"))
    }
  }

  @Test func newlinesCannotForgeExtraOutputLines() {
    let process = AudioProcessInfo(
      pid: 1, bundleID: "a\nPLAYING FAKE\r\n9\tidle", executablePath: "/x\u{2028}y",
      isRunningOutput: false)
    let line = ConsoleText.line(for: process)
    #expect(!line.contains("\n") && !line.contains("\r") && !line.contains("\u{2028}"))
    // The tab separators come only from the formatter: four columns, no more.
    #expect(line.split(separator: "\t", omittingEmptySubsequences: false).count == 4)
  }

  @Test func hugeValuesAreBounded() {
    let huge = String(repeating: "A\u{200B}", count: 1_000_000)
    let process = AudioProcessInfo(pid: 1, bundleID: huge, executablePath: "/" + huge)
    #expect(ConsoleText.line(for: process).count < 2_200)
  }
}
