import Foundation
import Testing

@testable import Prowl

/// Claude Code's pid registry as the pane's session identity (docs-ai 079.004): the
/// `sessionId` in `<root>/sessions/<pid>.json` follows `/clear` and an in-process
/// `/resume` at once, so a delegated tick needs no screen text to track a rotation.
struct ClaudeSessionRegistryTests {
  private let sessionA = "d5afa682-cb4a-4d23-95a0-16a4bb621be6"
  private let sessionB = "2ee704b0-df65-4bd5-a89e-5d947adad4d6"
  /// The registry stores `TZ=UTC ps -o lstart` (whole seconds); the live process start
  /// carries a fraction.
  private let start = Date(timeIntervalSince1970: 1_789_402_075.4)

  private func registry(
    sessionID: String,
    pid: Int = 42,
    procStart: String = "Mon Sep 14 16:07:55 2026",
    kind: String = "interactive",
    cwd: String = "/tmp/experiment",
    status: String = "idle"
  ) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": sessionID, "cwd": cwd, "kind": kind, "pidDomain": "darwin",
      "procStart": procStart, "status": status,
      "updatedAt": 1_789_402_087_000, "statusUpdatedAt": 1_789_402_087_000,
    ])
  }

  private func makeRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-claude-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
    return root
  }

  @Test func registryYieldsThePidsSessionAndItsTranscriptOnceWritten() throws {
    let root = try makeRoot("registry")
    defer { try? FileManager.default.removeItem(at: root) }
    try registry(sessionID: sessionA).write(to: root.appending(path: "sessions/42.json"))

    // Before the first prompt the transcript does not exist: the id is exact, the path absent.
    let early = ClaudeSessionRegistry.session(root: root, pid: 42, processStartedAt: start)
    #expect(early?.id == sessionA)
    #expect(early?.source == .processLog)
    #expect(early?.confidence == .exact)
    #expect(early?.transcriptPath == nil)

    let project = root.appending(path: "projects/-tmp-experiment")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let transcript = project.appending(path: "\(sessionA).jsonl")
    try Data("{}\n".utf8).write(to: transcript)
    let session = ClaudeSessionRegistry.session(root: root, pid: 42, processStartedAt: start)
    #expect(session?.id == sessionA)
    #expect(session?.transcriptPath?.resolvingSymlinksInPath() == transcript.resolvingSymlinksInPath())
    #expect(ClaudeSessionRegistry.session(root: root, pid: 43, processStartedAt: start) == nil)
  }

  @Test func registryRejectsClaimsThatDoNotBelongToTheLiveProcess() throws {
    let root = try makeRoot("stale")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "sessions/42.json")

    // The file survives a crash, so a start second other than the live process's marks
    // a previous owner of the reused pid.
    try registry(sessionID: sessionA).write(to: url)
    #expect(ClaudeSessionRegistry.session(root: root, pid: 42, processStartedAt: start.addingTimeInterval(2)) == nil)
    for data in [
      try registry(sessionID: sessionA, kind: "background"),
      try registry(sessionID: "../../other"),
      try registry(sessionID: sessionA, cwd: "relative"),
      Data("{".utf8),
      Data(repeating: 32, count: 65_537),
    ] {
      try data.write(to: url)
      #expect(ClaudeSessionRegistry.session(root: root, pid: 42, processStartedAt: start) == nil)
    }
    // A status the native decoder does not know still carries the identity.
    try registry(sessionID: sessionA, status: "future-state").write(to: url)
    #expect(ClaudeSessionRegistry.session(root: root, pid: 42, processStartedAt: start)?.id == sessionA)
  }

  @Test func claudeProfileReadsTheRegistryUnderTheHomeAndUnderARelocatedRoot() throws {
    let home = FileManager.default.temporaryDirectory
      .appending(path: "prowl-claude-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appending(path: ".claude/sessions"), withIntermediateDirectories: true)
    try registry(sessionID: sessionA).write(to: home.appending(path: ".claude/sessions/42.json"))
    let relocated = home.appending(path: "relocated")
    try FileManager.default.createDirectory(
      at: relocated.appending(path: "sessions"), withIntermediateDirectories: true)
    try registry(sessionID: sessionB).write(to: relocated.appending(path: "sessions/42.json"))

    let profile = AgentSessionProfile.profile(for: .claude)
    #expect(profile.pidKeyedSession?(home, 42, start)?.id == sessionA)
    #expect(profile.rootedPIDKeyedSession?(relocated, 42, start)?.id == sessionB)
  }

  /// End to end through the resolver with this test process as the agent: the registry
  /// decides, the screen text is never consulted, and a rewrite shows up as soon as the
  /// 5 s result cache expires.
  @Test func rotationReplacesTheSessionWithoutScreenText() async throws {
    let pid = getpid()
    let startedAt = try #require(ProcessDetection.processStartDate(pid: pid))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    let procStart = formatter.string(from: startedAt)
    let home = FileManager.default.temporaryDirectory
      .appending(path: "prowl-claude-rotation-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appending(path: ".claude/sessions"), withIntermediateDirectories: true)
    let registryURL = home.appending(path: ".claude/sessions/\(pid).json")
    try registry(sessionID: sessionA, pid: Int(pid), procStart: procStart).write(to: registryURL)

    let resolver = AgentSessionResolver(
      homeDirectory: home, tuiOpenFilePaths: { _ in [] }, daemonBinding: { _, _, _ in .unavailable })
    let identified = IdentifiedAgentProcess(
      agent: .claude, name: "claude",
      process: ForegroundProcess(pid: pid, name: "claude", argv0: nil, cmdline: nil))
    let now = Date()
    let first = await resolver.resolve(identified: identified, workingDirectory: nil, activeText: "", now: now)
    #expect(first.session?.id == sessionA)
    #expect(first.session?.source == .processLog)
    #expect(first.session?.confidence == .exact)

    try registry(sessionID: sessionB, pid: Int(pid), procStart: procStart).write(to: registryURL)
    // The frame still shows the outgoing session. The result cache replays A for 5 s;
    // the next uncached resolution follows the registry regardless of that text.
    let cached = await resolver.resolve(
      identified: identified, workingDirectory: nil, activeText: "outgoing session text",
      now: now.addingTimeInterval(1))
    #expect(cached.session?.id == sessionA)
    #expect(cached.isFresh == false)
    let rotated = await resolver.resolve(
      identified: identified, workingDirectory: nil, activeText: "outgoing session text",
      now: now.addingTimeInterval(6))
    #expect(rotated.session?.id == sessionB)
    #expect(rotated.isFresh == true)
  }
}
