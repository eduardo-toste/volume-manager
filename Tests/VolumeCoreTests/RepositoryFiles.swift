import Foundation

/// Locates files of the repository from the test source location.
enum RepositoryFiles {
  /// Repository root (this file lives in `Tests/VolumeCoreTests`).
  static let root: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
