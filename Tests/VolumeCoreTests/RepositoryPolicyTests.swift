import Foundation
import Testing

/// Independent QA checks of repository-level policy (SPEC 12.1, 12.3, 12.9.2, 12.9.6).
@Suite("Repository policy")
struct RepositoryPolicyTests {
  private func text(_ path: String) throws -> String {
    try String(
      contentsOf: RepositoryFiles.root.appendingPathComponent(path), encoding: .utf8)
  }

  private func plist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: RepositoryFiles.root.appendingPathComponent(path))
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(object as? [String: Any])
  }

  private func swiftFiles(under directory: String) throws -> [(path: String, body: String)] {
    let base = RepositoryFiles.root.appendingPathComponent(directory)
    let enumerator = try #require(
      FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
    var result: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let relative = url.path.replacingOccurrences(of: RepositoryFiles.root.path + "/", with: "")
      result.append((relative, try String(contentsOf: url, encoding: .utf8)))
    }
    return result
  }

  // MARK: Info.plist and entitlements

  @Test func infoPlistMatchesSpec() throws {
    let info = try plist("Resources/Info.plist")
    #expect(info["CFBundleIdentifier"] as? String == "com.volumemanager.app")
    #expect(info["CFBundleName"] as? String == "Volume")
    #expect(info["LSUIElement"] as? Bool == true)
    #expect(info["LSMinimumSystemVersion"] as? String == "15.0")
    #expect(info["CFBundleExecutable"] as? String == "VolumeManager")
  }

  @Test func infoPlistRequestsOnlyAudioCapturePermission() throws {
    let info = try plist("Resources/Info.plist")
    let usageKeys = info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
    #expect(usageKeys == ["NSAudioCaptureUsageDescription"])
    let description = info["NSAudioCaptureUsageDescription"] as? String ?? ""
    #expect(!description.isEmpty)
  }

  @Test func entitlementsHaveNoRuntimeExceptions() throws {
    let entitlements = try plist("Resources/VolumeManager.entitlements")
    let forbidden = [
      "com.apple.security.cs.disable-library-validation",
      "com.apple.security.cs.allow-dyld-environment-variables",
      "com.apple.security.cs.allow-unsigned-executable-memory",
      "com.apple.security.cs.allow-jit",
      "com.apple.security.get-task-allow",
      "com.apple.security.cs.debugger",
    ]
    for key in forbidden { #expect(entitlements[key] == nil, "forbidden entitlement \(key)") }
    #expect(entitlements.isEmpty, "release entitlements must stay minimal: \(entitlements.keys)")
  }

  @Test func localizationCatalogIsPortugueseAndHasPopoverTitle() throws {
    let data = try Data(
      contentsOf: RepositoryFiles.root.appendingPathComponent("Resources/Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(catalog["sourceLanguage"] as? String == "pt-BR")
    let strings = try #require(catalog["strings"] as? [String: Any])
    #expect(strings["popover.title"] != nil)
  }

  // MARK: CI workflow (SPEC 12.9.6)

  @Test func workflowIsHardened() throws {
    let workflow = try text(".github/workflows/ci.yml")
    #expect(!workflow.contains("pull_request_target"))
    #expect(!workflow.contains("secrets."))
    #expect(workflow.contains("contents: read"))
    #expect(!workflow.contains("write"), "workflow must not request write permissions")
    for line in workflow.split(separator: "\n") {
      guard let range = line.range(of: "uses:") else { continue }
      let reference = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
      let pinned = reference.split(separator: "@").last.map(String.init) ?? ""
      let isSHA = pinned.count == 40 && pinned.allSatisfy { $0.isHexDigit && !$0.isUppercase }
      #expect(isSHA, "action must be pinned by commit SHA: \(reference)")
    }
  }

  // MARK: Package manifest (SPEC 12.1, 12.9.6)

  @Test func manifestDeclaresMacOS15AndNoUnapprovedDependency() throws {
    let manifest = try text("Package.swift")
    #expect(manifest.contains(".macOS(.v15)"))
    let remote = manifest.components(separatedBy: ".package(").count - 1
    #expect(remote <= 1)
    if remote == 1 {
      #expect(manifest.contains("KeyboardShortcuts"))
      #expect(manifest.contains("exact:"))
    }
    #expect(!manifest.contains("from:"))
    #expect(!manifest.contains(".upToNextMajor"))
    #expect(!manifest.contains("branch:"))
  }

  @Test func uiTargetDoesNotDependOnInfrastructureModules() throws {
    let manifest = try text("Package.swift")
    let start = try #require(manifest.range(of: "name: \"VolumeUI\""))
    let tail = manifest[start.upperBound...]
    let end = try #require(tail.range(of: "swiftSettings"))
    let block = tail[..<end.lowerBound]
    #expect(!block.contains("VolumeAudio"))
    #expect(!block.contains("VolumeSystem"))
  }

  @Test func coreTargetHasNoDependencies() throws {
    let manifest = try text("Package.swift")
    let start = try #require(manifest.range(of: ".target(name: \"VolumeCore\""))
    let line = manifest[start.upperBound...].prefix { $0 != "\n" }
    #expect(!line.contains("dependencies"))
  }

  // MARK: Source hygiene (SPEC 12.3)

  @Test func sourcesAvoidForbiddenConstructs() throws {
    let banned = ["try!", "as!", "dlopen", "dlsym", "NSAppleScript", "@_silgen_name", "URLSession"]
    for (path, body) in try swiftFiles(under: "Sources") {
      for token in banned { #expect(!body.contains(token), "\(path) contains \(token)") }
      if !path.hasPrefix("Sources/vmctl/") {
        let hasPrint = body.range(of: #"(^|[^A-Za-z0-9_.])print\s*\("#, options: .regularExpression)
        #expect(hasPrint == nil, "\(path) uses print")
      }
    }
  }

  @Test func sourcesHaveNoForceUnwrap() throws {
    // Strings and comments are removed first so punctuation in text does not count.
    for (path, body) in try swiftFiles(under: "Sources") {
      var code = body.replacingOccurrences(
        of: #""(\\.|[^"\\])*""#, with: "\"\"", options: .regularExpression)
      code = code.replacingOccurrences(of: #"//.*"#, with: "", options: .regularExpression)
      let hit = code.range(of: #"[A-Za-z0-9_\)\]]!(?!=)"#, options: .regularExpression)
      #expect(hit == nil, "\(path) appears to contain a force unwrap")
    }
  }

  /// Real `UserDefaults` makes the system create files in ~/Library/Preferences, which tests must
  /// never do. The QA file only reads `.standard` to prove nothing was written there.
  @Test func testsNeverUseRealUserDefaults() throws {
    let suite = "UserDefaults(" + "suiteName"
    let standard = "UserDefaults." + "standard"
    for (path, body) in try swiftFiles(under: "Tests") {
      if path.hasSuffix("RepositoryPolicyTests.swift") { continue }
      #expect(!body.contains(suite), "\(path) creates a real UserDefaults suite")
      if !path.hasSuffix("QAM3Tests.swift") {
        #expect(!body.contains(standard), "\(path) uses the standard UserDefaults")
      }
    }
  }

  @Test func sourcesContainNoLiveNetworkOrCommentedOutCode() throws {
    for (path, body) in try swiftFiles(under: "Sources") {
      #expect(!body.contains("import Network"), "\(path) imports Network")
      #expect(!body.contains("TODO"), "\(path) has TODO")
      for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isPlainComment = trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        let looksLikeCode =
          trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}")
          || trimmed.hasPrefix("// let ") || trimmed.hasPrefix("// func ")
        #expect(!(isPlainComment && looksLikeCode), "\(path): commented-out code: \(trimmed)")
      }
    }
  }

  @Test func onlyCSystemShimsContainsCSources() throws {
    let root = RepositoryFiles.root
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
    let cExtensions: Set<String> = ["c", "h", "m", "mm", "cpp", "cc", "hpp"]
    for case let url as URL in enumerator where cExtensions.contains(url.pathExtension) {
      #expect(url.path.contains("/Sources/CSystemShims/"), "\(url.path) is C code outside shims")
    }
  }

  @Test func buildScriptNeverCopiesVmctlIntoTheBundle() throws {
    let script = try text("scripts/build-app.sh")
    for line in script.split(separator: "\n") where !line.hasPrefix("#") {
      #expect(!line.contains("vmctl"), "build-app.sh must not touch vmctl: \(line)")
    }
    #expect(script.contains("--options runtime"))
  }

  @Test func publicDeclarationsAreDocumented() throws {
    for (path, body) in try swiftFiles(under: "Sources") where !path.hasPrefix("Sources/vmctl/") {
      let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("public ") || trimmed.hasPrefix("open ") else { continue }
        var cursor = index - 1
        while cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("@") {
          cursor -= 1
        }
        let previous = cursor >= 0 ? lines[cursor].trimmingCharacters(in: .whitespaces) : ""
        #expect(previous.hasPrefix("///"), "\(path):\(index + 1) public API without ///")
      }
    }
  }
}
