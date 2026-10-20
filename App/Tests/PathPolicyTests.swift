import Foundation
import Testing

@testable import Prowl

struct PathPolicyTests {
  @Test func trimmingTrailingSlashKeepsTheRootAndOtherPathsIntact() {
    #expect(PathPolicy.trimmingTrailingSlash("/") == "/")
    #expect(PathPolicy.trimmingTrailingSlash("/Users/me/repo") == "/Users/me/repo")
    #expect(PathPolicy.trimmingTrailingSlash("/Users/me/repo/") == "/Users/me/repo")
  }

  /// macOS 15's Foundation appends "/" to an existing directory's path and drops it once the
  /// directory is gone, so a canonical worktree path (the worktree id) must not depend on whether
  /// the directory still exists.
  @Test func canonicalWorktreePathIgnoresTheExistingDirectoryTrailingSlash() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let whileExisting = GitClient.canonicalWorktreePath(directory.path(percentEncoded: false))
    #expect(whileExisting == PathPolicy.trimmingTrailingSlash(whileExisting))
    #expect(!whileExisting.hasSuffix("/"))

    try FileManager.default.removeItem(at: directory)
    #expect(GitClient.canonicalWorktreePath(directory.path(percentEncoded: false)) == whileExisting)
  }

  /// The same directory addressed with and without a trailing slash, and before and after it
  /// exists, is always one normalized path string.
  @Test func normalizePathNeverKeepsTheTrailingSlash() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let normalized = try #require(PathPolicy.normalizePath(directory.path(percentEncoded: false)))
    #expect(!normalized.hasSuffix("/"))
    #expect(PathPolicy.normalizePath(normalized + "/") == normalized)

    try FileManager.default.removeItem(at: directory)
    #expect(PathPolicy.normalizePath(directory.path(percentEncoded: false)) == normalized)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "prowl-path-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
