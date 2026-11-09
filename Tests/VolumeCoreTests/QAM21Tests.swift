import Foundation
import Testing

@testable import VolumeCore

@Suite("QA M2.1: hostile text (B-1)", .timeLimit(.minutes(1)))
struct QAHostileTextM21Tests {
  /// Every scalar that must never reach a terminal or a path decision.
  private static let hostileScalars: [(String, Unicode.Scalar)] = [
    ("ESC", "\u{1B}"), ("BEL", "\u{07}"), ("NUL", "\u{00}"), ("DEL", "\u{7F}"),
    ("CSI C1", "\u{9B}"), ("OSC C1", "\u{9D}"), ("C1 NEL", "\u{85}"), ("C1 low", "\u{80}"),
    ("C1 high", "\u{9F}"), ("RLO", "\u{202E}"), ("LRE", "\u{202A}"), ("RLI", "\u{2067}"),
    ("ZWSP", "\u{200B}"), ("BOM", "\u{FEFF}"), ("WJ", "\u{2060}"), ("SHY", "\u{AD}"),
    ("LRM", "\u{200E}"), ("tag", "\u{E0041}"),
  ]

  @Test func appPathRejectsEveryHostileScalarAnywhere() {
    for (label, scalar) in Self.hostileScalars {
      let middle = "/Applications/Ev\(scalar)il.app/Contents/MacOS/x"
      let end = "/Applications/Evil.app\(scalar)"
      #expect(AppPath.canonicalize(middle) == nil, "\(label) in the middle")
      #expect(AppPath.canonicalize(end) == nil, "\(label) at the end")
      #expect(AppPath.outermostAppPath(in: middle) == nil, "\(label) outermost")
    }
  }

  @Test func appPathStillAcceptsOrdinaryUnicode() {
    #expect(AppPath.canonicalize("/Applications/Música.app") == "/Applications/Música.app")
    #expect(AppPath.canonicalize("/Applications/日本語 アプリ.app") != nil)
    #expect(AppPath.canonicalize("/a/../b//c/./d") == "/b/c/d")
  }

  /// B-1 is only as good as its coverage: no `vmctl` print may interpolate a field that comes
  /// from another process or device without going through `ConsoleText`.
  @Test func vmctlNeverPrintsUntrustedFieldsDirectly() throws {
    let dir = RepositoryFiles.root.appendingPathComponent("Sources/vmctl")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".swift") }
    let untrusted = [
      "\\(process.bundleID", "\\(process.executablePath", "\\(app.name)", "\\(app.bundleID",
      "\\(device.uid", "\\(device.name", "\\(snapshot.defaultOutputUID", "\\(extra",
    ]
    for file in files {
      let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
      for line in source.split(separator: "\n") where !line.contains("ConsoleText") {
        for field in untrusted {
          #expect(!line.contains(field), "\(file): \(line)")
        }
      }
    }
  }
}

@Suite("QA M2.1: removed features stay removed", .timeLimit(.minutes(1)))
struct QARemovedFeaturesM21Tests {
  private func sources(_ sub: String) throws -> [(String, String)] {
    let dir = RepositoryFiles.root.appendingPathComponent(sub)
    var result: [(String, String)] = []
    let walker = FileManager.default.enumerator(atPath: dir.path)
    while let rel = walker?.nextObject() as? String {
      guard rel.hasSuffix(".swift") else { continue }
      result.append(
        (rel, try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)))
    }
    return result
  }

  @Test func noHotkeyOrMenuBarToggleLeftInSources() throws {
    for (file, text) in try sources("Sources") {
      #expect(!text.contains("HotkeyService"), "\(file)")
      #expect(!text.contains("showInMenuBar"), "\(file)")
      #expect(!text.contains("KeyboardShortcuts"), "\(file)")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: RepositoryFiles.root.appendingPathComponent(
          "Sources/VolumeCore/HotkeyService.swift"
        )
        .path))
  }

  @Test func securityCheckRejectsAnyDependencyAndAnyResolvedFile() throws {
    let script = try String(
      contentsOf: RepositoryFiles.root.appendingPathComponent("scripts/security-check.sh"),
      encoding: .utf8)
    #expect(script.contains("none are allowed"))
    #expect(script.contains("Package.resolved exists"))
    #expect(!script.lowercased().contains("keyboardshortcuts"))
    #expect(!script.contains("APPROVED_DEPENDENCY"))
  }
}
