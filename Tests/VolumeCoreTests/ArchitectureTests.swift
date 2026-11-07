import Foundation
import Testing

/// Enforces the dependency direction of SPEC 12.1 by inspecting `import` lines.
@Suite("Architecture")
struct ArchitectureTests {
  /// Frameworks and modules each layer must never import.
  private static let forbidden: [String: Set<String>] = [
    "VolumeCore": [
      "CoreAudio", "AudioToolbox", "AudioUnit", "AVFoundation", "AppKit", "SwiftUI", "UIKit",
      "ServiceManagement", "KeyboardShortcuts", "CSystemShims",
      "VolumeAudio", "VolumeSystem", "VolumeUI", "VolumeManager",
    ],
    "VolumeAudio": ["AppKit", "SwiftUI", "VolumeSystem", "VolumeUI", "VolumeManager"],
    "VolumeSystem": [
      "SwiftUI", "CoreAudio", "AudioToolbox", "VolumeAudio", "VolumeUI", "VolumeManager",
    ],
    "VolumeUI": [
      "CoreAudio", "AudioToolbox", "ServiceManagement", "KeyboardShortcuts", "CSystemShims",
      "VolumeAudio", "VolumeSystem", "VolumeManager",
    ],
  ]

  private func imports(inModule module: String) throws -> [String: Set<String>] {
    let directory = RepositoryFiles.root.appendingPathComponent("Sources/\(module)")
    let enumerator = try #require(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
    var result: [String: Set<String>] = [:]
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      for line in text.split(separator: "\n") {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let index = words.firstIndex(of: "import") else { continue }
        // Accept attributes before `import` (`@testable`, `@_exported`) but nothing else.
        guard words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { continue }
        var rest = words[(index + 1)...]
        if let kind = rest.first,
          ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"].contains(kind)
        {
          rest = rest.dropFirst()
        }
        guard let name = rest.first else { continue }
        let root = String(name.split(separator: ".").first ?? name)
        result[root, default: []].insert(url.lastPathComponent)
      }
    }
    return result
  }

  @Test(arguments: ["VolumeCore", "VolumeAudio", "VolumeSystem", "VolumeUI"])
  func moduleRespectsDependencyDirection(module: String) throws {
    let found = try imports(inModule: module)
    let banned = try #require(Self.forbidden[module])
    for name in banned {
      #expect(found[name] == nil, "\(module) must not import \(name): \(found[name] ?? [])")
    }
  }

  @Test func coreOnlyImportsFoundationFamily() throws {
    let allowed: Set<String> = ["Foundation", "Observation", "os", "Synchronization"]
    let found = try imports(inModule: "VolumeCore")
    #expect(Set(found.keys).subtracting(allowed).isEmpty, "Unexpected: \(found.keys)")
  }
}
