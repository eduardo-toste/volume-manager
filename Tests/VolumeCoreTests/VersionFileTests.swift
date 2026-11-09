import Foundation
import Testing

@testable import VolumeCore

@Suite("Resources/Version", .timeLimit(.minutes(1)))
struct VersionFileTests {
  private func values() throws -> [String: String] {
    let url = RepositoryFiles.root.appendingPathComponent("Resources/Version")
    let text = try String(contentsOf: url, encoding: .utf8)
    var result: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let pair = line.split(separator: "=", maxSplits: 1)
      if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
    }
    return result
  }

  @Test func versionIsSemanticVersion() throws {
    let version = try #require(try values()["VERSION"])
    #expect(AppVersion(version) != nil)
  }

  @Test func buildIsPositiveInteger() throws {
    let build = try #require(try values()["BUILD"])
    #expect((Int(build) ?? 0) > 0)
  }
}
