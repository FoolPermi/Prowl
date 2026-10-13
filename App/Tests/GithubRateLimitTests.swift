import ComposableArchitecture
import Foundation
import Testing

@testable import Prowl

struct GithubRateLimitClassifierTests {
  // The refusal Prowl received on 2026-09-30, as `gh api graphql --include` prints it.
  nonisolated static let graphQLRefusal = """
    HTTP/2.0 200 OK
    Content-Type: application/json; charset=utf-8
    X-Ratelimit-Remaining: 4979

    {"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit",\
    "message":"API rate limit already exceeded for user ID 1."}]}
    """

  @Test func graphQLRateLimitErrorIsARefusal() {
    let signal = GithubRateLimitClassifier.classify(
      stdout: Self.graphQLRefusal,
      stderr: "gh: API rate limit already exceeded for user ID 1.",
      succeeded: false
    )
    #expect(
      signal
        == GithubRateLimitSignal(
          isRefusal: true,
          limit: .primary,
          evidence: GithubRateLimitEvidence(
            status: 200,
            headers: ["x-ratelimit-remaining": "4979"],
            message: "API rate limit already exceeded for user ID 1."
          )
        )
    )
  }

  @Test func rateLimitedErrorTypeIsARefusalEvenWhenGhExitsZero() {
    let stdout = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: true)
    #expect(signal?.isRefusal == true)
  }

  @Test func secondaryLimitCarriesRetryAfter() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      Retry-After: 120

      {"message":"You have exceeded a secondary rate limit.","documentation_url":"https://docs.github.com"}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)
    #expect(
      signal
        == GithubRateLimitSignal(
          isRefusal: true,
          limit: .secondary,
          retryAfter: .seconds(120),
          evidence: GithubRateLimitEvidence(
            status: 403,
            headers: ["retry-after": "120"],
            message: "You have exceeded a secondary rate limit."
          )
        )
    )
  }

  @Test func retryAfterAsHTTPDateIsRead() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      Retry-After: Wed, 21 Oct 2026 07:28:00 GMT

      {"message":"You have exceeded a secondary rate limit."}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)
    #expect(signal?.isRefusal == true)
    #expect(signal?.retryAfterDate == Date(timeIntervalSince1970: 1_792_567_680))
  }

  @Test func tooManyRequestsIsARefusal() {
    let stdout = "HTTP/2.0 429 Too Many Requests\n\n{}"
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)?.isRefusal == true)
  }

  @Test func exhaustedPrimaryBudgetRefusalCarriesTheResetTime() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      X-Ratelimit-Remaining: 0
      X-Ratelimit-Reset: 1790892842

      {"message":"API rate limit exceeded for user ID 1."}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)
    #expect(signal?.isRefusal == true)
    #expect(signal?.limit == .primary)
    #expect(signal?.resetAt == Date(timeIntervalSince1970: 1_790_892_842))
    #expect(signal?.evidence.headers == ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790892842"])
  }

  @Test func spendingTheLastOfTheBudgetBlocksWithoutDiscardingTheAnswer() {
    let stdout = """
      HTTP/2.0 200 OK
      X-Ratelimit-Remaining: 0
      X-Ratelimit-Reset: 1790892842

      {"data":{}}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: true)
    #expect(signal?.isRefusal == false)
    #expect(signal?.limit == .primary)
    #expect(signal?.resetAt == Date(timeIntervalSince1970: 1_790_892_842))
  }

  @Test func refusalThatNamesNoLimitCoversTheHost() {
    let stdout = "HTTP/2.0 429 Too Many Requests\n\n{}"
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)?.limit == .secondary)
  }

  @Test func abuseDetectionIsASecondaryLimit() {
    let signal = GithubRateLimitClassifier.classify(
      stdout: "",
      stderr: "gh: You have triggered an abuse detection mechanism. (HTTP 403)",
      succeeded: false
    )
    #expect(signal?.isRefusal == true)
    #expect(signal?.limit == .secondary)
    #expect(signal?.evidence.message == "gh: You have triggered an abuse detection mechanism. (HTTP 403)")
  }

  @Test func permissionDenialIsNotARateLimit() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      X-Ratelimit-Remaining: 4000

      {"message":"Resource not accessible by integration"}
      """
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "gh: HTTP 403", succeeded: false) == nil)
  }

  @Test func payloadTextMentioningRateLimitsIsNotARateLimit() {
    let stdout = """
      HTTP/2.0 200 OK

      {"data":{"repository":{"b0":{"nodes":[{"title":"Back off on rate limit errors"}]}}}}
      """
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: true) == nil)
  }

  @Test func nonAPICommandsReportThroughStderr() {
    let signal = GithubRateLimitClassifier.classify(
      stdout: "",
      stderr: "GraphQL: API rate limit exceeded for user ID 1. (rateLimit)",
      succeeded: false
    )
    #expect(signal?.isRefusal == true)
    #expect(signal?.limit == .primary)
    #expect(
      signal?.evidence
        == GithubRateLimitEvidence(message: "GraphQL: API rate limit exceeded for user ID 1. (rateLimit)"))
  }
}

struct GithubRateLimitRequestTests {
  @Test func graphQLQueryNamesItsHost() {
    let request = GithubRateLimitRequest(arguments: ["api", "graphql", "--include", "--hostname", "ghe.example"])
    #expect(request.scope == GithubRateLimitScope(host: "ghe.example", resource: .graphQL))
    #expect(request.command == "gh api graphql")
  }

  @Test func pullRequestCommandTakesTheHostFromItsRepository() {
    let request = GithubRateLimitRequest(arguments: ["pr", "merge", "7", "--repo", "github.com/octo/repo", "--squash"])
    #expect(request.scope == GithubRateLimitScope(host: "github.com", resource: .graphQL))
    #expect(request.command == "gh pr merge")
  }

  @Test func runCommandsSpendTheRESTBudget() {
    let request = GithubRateLimitRequest(arguments: ["run", "list", "--branch", "feature", "--json", "status"])
    #expect(request.scope == GithubRateLimitScope(host: nil, resource: .rest))
  }

  @Test func repositoryWithoutHostLeavesTheHostToGh() {
    let request = GithubRateLimitRequest(arguments: ["pr", "close", "7", "--repo", "octo/repo"])
    #expect(request.scope == GithubRateLimitScope(host: nil, resource: .graphQL))
  }

  @Test func authStatusForAHostSpendsTheRESTBudget() {
    let request = GithubRateLimitRequest(arguments: ["auth", "status", "--active", "--hostname", "github.com"])
    #expect(request.scope == GithubRateLimitScope(host: "github.com", resource: .rest))
  }
}

struct GithubRateLimitStatusTests {
  @Test func graphQLBlockOnTheRepositoryHostHoldsBackItsStatus() {
    let graphQL = GithubRateLimitBlockFixture.graphQL(host: "ghe.example", retryAt: Date(timeIntervalSince1970: 60))
    let rest = GithubRateLimitBlockFixture.rest(host: "ghe.example", retryAt: Date(timeIntervalSince1970: 30))
    let status = GithubRateLimitStatus(blocks: [graphQL, rest], hosts: ["ghe.example"])
    #expect(status?.retryAt == Date(timeIntervalSince1970: 60))
    #expect(status?.blocks == [graphQL, rest])
  }

  @Test func blocksOnOtherHostsDoNotConcernTheRepository() {
    let blocks = [
      GithubRateLimitBlockFixture.graphQL(host: "ghe.example"),
      GithubRateLimitBlockFixture.graphQL(host: nil),
    ]
    #expect(GithubRateLimitStatus(blocks: blocks, hosts: ["github.com"]) == nil)
  }

  @Test func restBlockAloneLeavesThePullRequestStatusShowing() {
    #expect(
      GithubRateLimitStatus(blocks: [GithubRateLimitBlockFixture.rest(host: "github.com")], hosts: ["github.com"])
        == nil)
  }
}

nonisolated enum GithubRateLimitBlockFixture {
  static func graphQL(host: String?, retryAt: Date = Date(timeIntervalSince1970: 1_000_060)) -> GithubRateLimitBlock {
    block(host: host, resource: .graphQL, retryAt: retryAt)
  }

  static func rest(host: String?, retryAt: Date = Date(timeIntervalSince1970: 1_000_060)) -> GithubRateLimitBlock {
    block(host: host, resource: .rest, retryAt: retryAt)
  }

  static func block(host: String?, resource: GithubAPIResource, retryAt: Date) -> GithubRateLimitBlock {
    let scope = GithubRateLimitScope(host: host, resource: resource)
    return GithubRateLimitBlock(
      scope: scope,
      retryAt: retryAt,
      cause: GithubRateLimitCause(
        request: GithubRateLimitRequest(scope: scope, command: "gh api graphql"),
        limit: .primary,
        evidence: GithubRateLimitEvidence(status: 403, message: "API rate limit exceeded for user ID 1.")
      )
    )
  }
}

struct GithubRateLimitGateTests {
  @Test func backoffDoublesFromOneMinuteAndStopsAtOneHour() {
    let delays = (1...8).map { GithubRateLimitGate.backoff(afterRefusals: $0, jitter: 0) }
    #expect(Array(delays.prefix(7)) == [60, 120, 240, 480, 960, 1920, 3600].map { Duration.seconds($0) })
    #expect(delays.last == .seconds(3600))
    #expect(GithubRateLimitGate.backoff(afterRefusals: 1, jitter: 1) == .seconds(75))
    #expect(GithubRateLimitGate.backoff(afterRefusals: 7, jitter: 1) == .seconds(3600))
  }

  @Test func refusalBlocksEveryRequestUntilTheBackoffEnds() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })

    let ticket = try await gate.admit()
    let retryAt = await gate.record(ticket, signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    #expect(retryAt == clock.value.addingTimeInterval(60))

    clock.withValue { $0.addTimeInterval(59) }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt!)) {
      _ = try await gate.admit()
    }

    clock.withValue { $0.addTimeInterval(1) }
    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: true))
  }

  @Test func failedProbeDoublesTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let first = try await gate.admit()
    _ = await gate.record(first, signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    clock.withValue { $0.addTimeInterval(60) }

    let probe = try await gate.admit()
    let retryAt = await gate.record(probe, signal: GithubRateLimitSignal(isRefusal: true), answered: true)

    #expect(retryAt == clock.value.addingTimeInterval(120))
  }

  @Test func retryAfterOverridesTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let ticket = try await gate.admit()

    let retryAt = await gate.record(
      ticket, signal: GithubRateLimitSignal(isRefusal: true, retryAfter: .seconds(7)), answered: true)

    #expect(retryAt == clock.value.addingTimeInterval(7))
  }

  @Test func answeredProbeReopensTheGateAndResetsTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    clock.withValue { $0.addTimeInterval(60) }

    let probe = try await gate.admit()
    #expect(await gate.record(probe, signal: nil, answered: true) == nil)

    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: false))
    let retryAt = await gate.record(
      try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    #expect(retryAt == clock.value.addingTimeInterval(60))
  }

  @Test func requestAdmittedBeforeTheRefusalCannotReopenTheGate() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let early = try await gate.admit()
    let refused = try await gate.admit()
    let retryAt = await gate.record(refused, signal: GithubRateLimitSignal(isRefusal: true), answered: true)

    #expect(await gate.record(early, signal: nil, answered: true) == nil)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt!)) {
      _ = try await gate.admit()
    }
  }

  @Test func requestsArrivingDuringTheProbeWaitForItsAnswer() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    clock.withValue { $0.addTimeInterval(60) }
    let probe = try await gate.admit()

    let waiter = Task { try await gate.admit() }
    while await gate.waitingRequestCount == 0 {
      await Task.yield()
    }
    let refusedAgain = await gate.record(probe, signal: GithubRateLimitSignal(isRefusal: true), answered: true)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: refusedAgain!)) {
      _ = try await waiter.value
    }
  }

  @Test func probeThatFailsLocallyKeepsTheGateClosed() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    clock.withValue { $0.addTimeInterval(60) }
    let probe = try await gate.admit()
    let waiters = (0..<3).map { _ in Task { try await gate.admit() } }
    while await gate.waitingRequestCount < 3 {
      await Task.yield()
    }

    #expect(await gate.record(probe, signal: nil, answered: false) == nil)

    // Exactly one waiter becomes the next probe; the others keep waiting.
    #expect(await gate.waitingRequestCount == 2)

    _ = await gate.record(GithubRateLimitGate.Ticket(isProbe: true), signal: nil, answered: true)
    var tickets: [GithubRateLimitGate.Ticket] = []
    for waiter in waiters {
      tickets.append(try await waiter.value)
    }
    #expect(tickets.filter(\.isProbe).count == 1)
    #expect(tickets.count == 3)
  }

  @Test func cancelledWaiterNeverReceivesATicket() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    clock.withValue { $0.addTimeInterval(60) }
    let probe = try await gate.admit()
    let waiter = Task { try await gate.admit() }
    while await gate.waitingRequestCount == 0 {
      await Task.yield()
    }

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await waiter.value
    }
    #expect(await gate.waitingRequestCount == 0)
    await gate.abandon(probe)
    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: true))
  }

  @Test func refusalsWithRetryTimesStillCountTowardTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let timed = GithubRateLimitSignal(isRefusal: true, retryAfter: .seconds(10))
    _ = await gate.record(try await gate.admit(), signal: timed, answered: true)
    clock.withValue { $0.addTimeInterval(10) }
    _ = await gate.record(try await gate.admit(), signal: timed, answered: true)
    clock.withValue { $0.addTimeInterval(10) }

    let retryAt = await gate.record(
      try await gate.admit(),
      signal: GithubRateLimitSignal(isRefusal: true),
      answered: true
    )

    #expect(retryAt == clock.value.addingTimeInterval(240))
  }

  @Test func blocksStreamFollowsTheGateAndNamesTheCause() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    var iterator = await gate.blocks().makeAsyncIterator()
    #expect(await iterator.next() == [])

    let request = GithubRateLimitRequest(arguments: ["api", "graphql", "--hostname", "github.com"])
    let signal = GithubRateLimitSignal(
      isRefusal: true,
      limit: .primary,
      evidence: GithubRateLimitEvidence(status: 403, message: "API rate limit exceeded for user ID 1.")
    )
    let retryAt = try #require(await gate.record(try await gate.admit(request), signal: signal, answered: true))
    #expect(
      await iterator.next() == [
        GithubRateLimitBlock(
          scope: request.scope,
          retryAt: retryAt,
          cause: GithubRateLimitCause(request: request, limit: .primary, evidence: signal.evidence)
        )
      ]
    )

    clock.withValue { $0.addTimeInterval(60) }
    _ = await gate.record(try await gate.admit(request), signal: nil, answered: true)
    #expect(await iterator.next() == [])
  }

  @Test func refusalOnOneHostLeavesOtherHostsOpen() async throws {
    let gate = GithubRateLimitGate(now: { Date(timeIntervalSince1970: 1_000_000) }, jitter: { 0 })
    let enterprise = GithubRateLimitRequest(arguments: ["api", "graphql", "--hostname", "ghe.example"])
    let github = GithubRateLimitRequest(arguments: ["api", "graphql", "--hostname", "github.com"])

    _ = await gate.record(
      try await gate.admit(enterprise), signal: GithubRateLimitSignal(isRefusal: true), answered: true)

    #expect(try await gate.admit(github) == GithubRateLimitGate.Ticket(isProbe: false, request: github))
    await #expect(throws: GithubCLIError.self) {
      _ = try await gate.admit(enterprise)
    }
  }

  @Test func primaryLimitHoldsBackOnlyItsAPI() async throws {
    let gate = GithubRateLimitGate(now: { Date(timeIntervalSince1970: 1_000_000) }, jitter: { 0 })
    let runList = GithubRateLimitRequest(arguments: ["run", "list", "--repo", "github.com/octo/repo"])
    let query = GithubRateLimitRequest(arguments: ["api", "graphql", "--hostname", "github.com"])

    _ = await gate.record(
      try await gate.admit(runList),
      signal: GithubRateLimitSignal(isRefusal: true, limit: .primary),
      answered: true
    )

    #expect(try await gate.admit(query) == GithubRateLimitGate.Ticket(isProbe: false, request: query))
    await #expect(throws: GithubCLIError.self) {
      _ = try await gate.admit(runList)
    }
  }

  @Test func secondaryLimitHoldsBackEveryAPIOfTheHost() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let query = GithubRateLimitRequest(arguments: ["api", "graphql", "--hostname", "github.com"])
    let runList = GithubRateLimitRequest(arguments: ["run", "list", "--repo", "github.com/octo/repo"])
    let otherHost = GithubRateLimitRequest(arguments: ["run", "list", "--repo", "ghe.example/octo/repo"])

    let retryAt = await gate.record(
      try await gate.admit(query),
      signal: GithubRateLimitSignal(isRefusal: true, limit: .secondary, retryAfter: .seconds(30)),
      answered: true
    )

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt!)) {
      _ = try await gate.admit(runList)
    }
    #expect(try await gate.admit(otherHost).isProbe == false)
    clock.withValue { $0.addTimeInterval(30) }
    #expect(try await gate.admit(runList).isProbe)
  }

  @Test func retryNowLetsTheNextRequestProbe() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    var iterator = await gate.blocks().makeAsyncIterator()
    #expect(await iterator.next()?.first?.retryAt == clock.value.addingTimeInterval(60))

    await gate.retryNow()

    #expect(await iterator.next()?.first?.retryAt == clock.value)
    let probe = try await gate.admit()
    #expect(probe.isProbe)
    // A probe that is refused again continues the backoff.
    let retryAt = await gate.record(probe, signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    #expect(retryAt == clock.value.addingTimeInterval(120))
  }

  @Test func abandonedProbePassesToTheNextRequest() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    clock.withValue { $0.addTimeInterval(60) }
    let probe = try await gate.admit()

    await gate.abandon(probe)

    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: true))
  }
}

struct GithubRateLimitedClientTests {
  @Test func refusedGraphQLQueryStartsNoFurtherGhProcessUntilTheRetryTime() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in
        throw ShellClientError(
          command: "gh api graphql",
          stdout: GithubRateLimitClassifierTests.graphQLRefusal,
          stderr: "gh: API rate limit already exceeded for user ID 1.",
          exitCode: 1
        )
      },
      rateLimitGate: gate
    )
    let request = CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"])
    let retryAt = clock.value.addingTimeInterval(60)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    #expect(launches.value == 1)

    clock.withValue { $0.addTimeInterval(59) }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequests("github.com", "octo", "repo", ["feature"], [], nil)
    }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      try await client.mergePullRequest(
        URL(fileURLWithPath: "/tmp/repo"),
        GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"),
        1,
        .squash,
        nil
      )
    }
    #expect(launches.value == 1)

    clock.withValue { $0.addTimeInterval(1) }
    _ = try? await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    #expect(launches.value == 2)
  }

  @Test func retryAfterHeaderSetsTheRetryTime() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in
        throw ShellClientError(
          command: "gh api graphql",
          stdout:
            "HTTP/2.0 403 Forbidden\nRetry-After: 300\n\n{\"message\":\"You have exceeded a secondary rate limit.\"}",
          stderr: "gh: You have exceeded a secondary rate limit. (HTTP 403)",
          exitCode: 1
        )
      },
      rateLimitGate: gate
    )
    let request = CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"])
    let retryAt = clock.value.addingTimeInterval(300)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    clock.withValue { $0.addTimeInterval(299) }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    #expect(launches.value == 1)
  }

  // Issue #908: a refusal for one host or API stopped the pull request queries of every host.
  @Test func refusedRunListLeavesPullRequestQueriesFlowing() async {
    let gate = GithubRateLimitGate(now: { Date(timeIntervalSince1970: 1_000_000) }, jitter: { 0 })
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { arguments in
        if arguments.first == "run" {
          throw ShellClientError(
            command: "gh run list",
            stdout: "",
            stderr:
              "HTTP 403: API rate limit exceeded for user ID 1. (https://api.github.com/repos/octo/repo/actions/runs)",
            exitCode: 1
          )
        }
        return ShellOutput(stdout: "HTTP/2.0 200 OK\n\n{\"data\":{\"r0\":{}}}", stderr: "", exitCode: 0)
      },
      rateLimitGate: gate
    )
    await #expect(throws: GithubCLIError.self) {
      _ = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "feature", nil)
    }

    let request = CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"])
    _ = try? await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)

    #expect(launches.value == 2)
  }

  @Test func refusedEnterpriseHostLeavesGithubComFlowing() async {
    let gate = GithubRateLimitGate(now: { Date(timeIntervalSince1970: 1_000_000) }, jitter: { 0 })
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { arguments in
        if arguments.contains("ghe.example") {
          throw ShellClientError(
            command: "gh api graphql",
            stdout: GithubRateLimitClassifierTests.graphQLRefusal,
            stderr: "gh: API rate limit already exceeded for user ID 1.",
            exitCode: 1
          )
        }
        return ShellOutput(stdout: "HTTP/2.0 200 OK\n\n{\"data\":{\"r0\":{}}}", stderr: "", exitCode: 0)
      },
      rateLimitGate: gate
    )
    let request = CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"])
    await #expect(throws: GithubCLIError.self) {
      _ = try await client.batchPullRequestsAcrossRepositories("ghe.example", [request], nil)
    }

    _ = try? await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    await #expect(throws: GithubCLIError.self) {
      _ = try await client.batchPullRequestsAcrossRepositories("ghe.example", [request], nil)
    }

    #expect(launches.value == 2)
  }

  @Test func versionCheckRunsWhileRateLimited() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true), answered: true)
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in ShellOutput(stdout: "gh version 2.102.0", stderr: "", exitCode: 0) },
      rateLimitGate: gate
    )

    #expect(await client.isAvailable())
    #expect(launches.value == 1)
  }

  @Test func partialAnswerWithRepositoryErrorsKeepsTheGateOpen() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let launches = LockIsolated(0)
    // gh exits 1 whenever the answer lists errors, even when it also carries data for the other
    // aliases; that is an answer from GitHub, not a refusal.
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in
        throw ShellClientError(
          command: "gh api graphql",
          stdout: """
            HTTP/2.0 200 OK
            X-Ratelimit-Remaining: 4900

            {"data":{"r0":null,"r1":{"r1_b0":{"nodes":[]}}},\
            "errors":[{"type":"NOT_FOUND","path":["r0"],\
            "locations":[{"line":1,"column":3}],\
            "message":"Could not resolve to a Repository with the name 'octo/gone'."}]}
            """,
          stderr: "gh: Could not resolve to a Repository with the name 'octo/gone'.",
          exitCode: 1
        )
      },
      rateLimitGate: gate
    )
    let requests = [
      CrossRepoPullRequestRequest(owner: "octo", repo: "gone", branches: ["feature"]),
      CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"]),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    #expect(result.successByRepo[RepoKey(owner: "octo", repo: "repo")] == [:])
    #expect(
      result.failedRepos[RepoKey(owner: "octo", repo: "gone")]
        == .graphQLError(
          type: "NOT_FOUND",
          message: "GraphQL error for octo/gone: Could not resolve to a Repository with the name 'octo/gone'."
        )
    )
    _ = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)
    #expect(launches.value == 2)
  }
}

private func fakeGh(
  launches: LockIsolated<Int>,
  respond: @escaping @Sendable ([String]) async throws -> ShellOutput
) -> ShellClient {
  ShellClient(
    run: { executableURL, _, _ in
      if executableURL.lastPathComponent == "which" {
        return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
      }
      return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    },
    runLoginImpl: { executableURL, arguments, _, _ in
      guard executableURL.lastPathComponent == "gh" else {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      launches.withValue { $0 += 1 }
      return try await respond(arguments)
    }
  )
}

@MainActor
struct GithubSettingsRateLimitTests {
  nonisolated static let snapshot = GithubAuthStatusSnapshot(
    hosts: [
      "github.com": [
        GithubAuthAccountStatus(
          host: "github.com",
          login: "octo",
          active: true,
          state: "success",
          gitProtocol: "ssh",
          scopes: nil,
          tokenSource: nil
        )
      ]
    ]
  )

  @Test func loadRefusedWhileTheGateReopensLoadsAgain() async {
    let calls = LockIsolated(0)
    let viewModel = withDependencies {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.authStatusSnapshot = {
        let call = calls.withValue { count -> Int in
          count += 1
          return count
        }
        if call == 1 {
          throw GithubCLIError.rateLimited(retryAt: Date(timeIntervalSince1970: 1_000_060))
        }
        return Self.snapshot
      }
      // The gate already reopened by the time the refusal arrives.
      $0.githubCLI.rateLimitBlocks = { AsyncStream { $0.yield([]) } }
    } operation: {
      GithubSettingsViewModel()
    }

    await viewModel.load()

    #expect(calls.value == 2)
    #expect(viewModel.state == .authenticated(Self.snapshot))
  }

  @Test func loadRefusedWhileTheGateIsClosedShowsTheRetryTime() async {
    let retryAt = Date(timeIntervalSince1970: 1_000_060)
    let calls = LockIsolated(0)
    let viewModel = withDependencies {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.authStatusSnapshot = {
        calls.withValue { $0 += 1 }
        throw GithubCLIError.rateLimited(retryAt: retryAt)
      }
      $0.githubCLI.rateLimitBlocks = {
        AsyncStream { $0.yield([GithubRateLimitBlockFixture.rest(host: nil, retryAt: retryAt)]) }
      }
    } operation: {
      GithubSettingsViewModel()
    }

    await viewModel.load()

    #expect(calls.value == 1)
    #expect(viewModel.state == .rateLimited(retryAt: retryAt))
  }
}
