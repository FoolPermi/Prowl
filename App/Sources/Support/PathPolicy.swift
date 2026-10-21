import Foundation

nonisolated enum PathPolicy {
  static func normalizePath(
    _ rawPath: String,
    relativeTo baseURL: URL? = nil,
    resolvingSymlinks: Bool = true
  ) -> String? {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    let url: URL
    if expanded.hasPrefix("/") {
      url = URL(fileURLWithPath: expanded)
    } else if let baseURL {
      url = baseURL.standardizedFileURL.appending(path: expanded, directoryHint: .inferFromPath)
    } else {
      url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: expanded, directoryHint: .inferFromPath)
    }
    return trimmingTrailingSlash(
      normalizeURL(url, resolvingSymlinks: resolvingSymlinks).path(percentEncoded: false))
  }

  /// A path string without the trailing slash Foundation appends to an existing directory on
  /// macOS 15 (it does not on macOS 26), so one directory always renders as the same string:
  /// before and after it exists, and before and after it moves away.
  ///
  /// Every path-derived identifier and every path comparison goes through this.
  static func trimmingTrailingSlash(_ path: String) -> String {
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
  }

  /// The identifier a URL stands for: its standardized path, without the trailing slash Foundation
  /// appends to an existing directory on macOS 15 (it does not on macOS 26, see
  /// `trimmingTrailingSlash`). Repositories, worktrees and the snapshots that persist them are all
  /// keyed by this string, so every derived key has to come from here. A bare
  /// `url.standardizedFileURL.path(percentEncoded: false)` compares unequal to the same directory's
  /// id on macOS 15 while matching on macOS 26, which silently empties every path-keyed lookup.
  static func identifier(for url: URL) -> String {
    trimmingTrailingSlash(url.standardizedFileURL.path(percentEncoded: false))
  }

  static func normalizeURL(
    _ url: URL,
    resolvingSymlinks: Bool = true
  ) -> URL {
    var normalized = url.standardizedFileURL
    if resolvingSymlinks,
      FileManager.default.fileExists(atPath: normalized.path(percentEncoded: false))
    {
      normalized = normalized.resolvingSymlinksInPath().standardizedFileURL
    }
    return normalized
  }

  static func contains(_ path: URL, in baseDirectory: URL) -> Bool {
    let normalizedPath = normalizeURL(path).pathComponents
    let normalizedBase = normalizeURL(baseDirectory).pathComponents
    guard normalizedPath.count >= normalizedBase.count else {
      return false
    }
    return Array(normalizedPath.prefix(normalizedBase.count)) == normalizedBase
  }
}
