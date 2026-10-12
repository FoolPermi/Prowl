import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

/// A stand-in app: `perform` changes the snapshot the way the reducer and the
/// Canvas view would, optionally only after `waitUntil` polls.
@MainActor
private final class FakeCanvasApp {
  var snapshot = CanvasCLISnapshot(isShowing: false, layoutMode: nil, cardCount: 3, pendingCommandRequestID: nil)
  var canShow = true
  var viewTakesCommands = true
  var operations: [CanvasCLIOperation] = []
  private var nextRequestID = 0

  func perform(_ operation: CanvasCLIOperation) -> Int? {
    operations.append(operation)
    switch operation {
    case .show:
      if canShow { snapshot.isShowing = true }
      return nil
    case .hide:
      snapshot.isShowing = false
      return nil
    case .command(let command):
      nextRequestID += 1
      snapshot.pendingCommandRequestID = nextRequestID
      if viewTakesCommands {
        if case .layout(let kind) = command { snapshot.layoutMode = .automatic(kind) }
        snapshot.pendingCommandRequestID = nil
      }
      return nextRequestID
    }
  }

  func makeHandler() -> CanvasCommandHandler {
    CanvasCommandHandler(
      snapshot: { [unowned self] in snapshot },
      perform: { [unowned self] in perform($0) },
      waitUntil: { condition in condition() }
    )
  }
}

@MainActor
struct CanvasCommandHandlerTests {
  private func run(_ input: CanvasInput, on app: FakeCanvasApp) async -> CommandResponse {
    await app.makeHandler().handle(envelope: CommandEnvelope(output: .json, command: .canvas(input)))
  }

  private func payload(_ response: CommandResponse) throws -> CanvasCommandPayload {
    try #require(response.data).decode(as: CanvasCommandPayload.self)
  }

  @Test func statusReportsTheStateWithoutChangingIt() async throws {
    let app = FakeCanvasApp()
    app.snapshot.layoutMode = .freeform

    let response = await run(CanvasInput(action: .status), on: app)

    #expect(response.ok)
    #expect(response.schemaVersion == "prowl.cli.canvas.v1")
    #expect(
      try payload(response) == CanvasCommandPayload(action: .status, showing: false, layout: "freeform", cardCount: 3))
    #expect(app.operations.isEmpty)
  }

  @Test func showOpensCanvasOnlyWhenHidden() async throws {
    let app = FakeCanvasApp()

    let first = await run(CanvasInput(action: .show), on: app)
    let second = await run(CanvasInput(action: .show), on: app)

    #expect(try payload(first).showing)
    #expect(try payload(second).showing)
    #expect(app.operations == [.show])
  }

  @Test func showFailsWhenCanvasCannotOpen() async {
    let app = FakeCanvasApp()
    app.canShow = false

    let response = await run(CanvasInput(action: .show), on: app)

    #expect(response.error?.code == CLIErrorCode.canvasUnavailable)
  }

  @Test func hideLeavesCanvasOnlyWhenShowing() async throws {
    let app = FakeCanvasApp()
    _ = await run(CanvasInput(action: .hide), on: app)
    #expect(app.operations.isEmpty)

    app.snapshot.isShowing = true
    let response = await run(CanvasInput(action: .hide), on: app)

    #expect(try payload(response).showing == false)
    #expect(app.operations == [.hide])
  }

  @Test func layoutWhileHiddenRequiresShow() async {
    let app = FakeCanvasApp()

    let response = await run(CanvasInput(action: .layout, layout: .tile), on: app)

    #expect(response.error?.code == CLIErrorCode.canvasNotShowing)
    #expect(app.operations.isEmpty)
  }

  @Test func layoutWithShowOpensCanvasThenAppliesTheLayout() async throws {
    let app = FakeCanvasApp()

    let response = await run(CanvasInput(action: .layout, layout: .organize, show: true), on: app)

    #expect(app.operations == [.show, .command(.layout(.organize))])
    #expect(
      try payload(response) == CanvasCommandPayload(action: .layout, showing: true, layout: "organize", cardCount: 3))
  }

  @Test func layoutWithoutANameIsAnInvalidArgument() async {
    let app = FakeCanvasApp()
    app.snapshot.isShowing = true

    let response = await run(CanvasInput(action: .layout), on: app)

    #expect(response.error?.code == CLIErrorCode.invalidArgument)
  }

  @Test func fitRequestsAFitFromTheShowingCanvas() async throws {
    let app = FakeCanvasApp()
    app.snapshot.isShowing = true

    let response = await run(CanvasInput(action: .fit), on: app)

    #expect(response.ok)
    #expect(app.operations == [.command(.fit)])
  }

  @Test func aCommandCanvasNeverTakesFails() async {
    let app = FakeCanvasApp()
    app.snapshot.isShowing = true
    app.viewTakesCommands = false

    let response = await run(CanvasInput(action: .fit), on: app)

    #expect(response.error?.code == CLIErrorCode.canvasFailed)
  }

  @Test func layoutNamesMapToLayoutKinds() {
    #expect(
      CanvasLayoutName.allCases.map { CanvasLayoutKind($0).rawValue } == CanvasLayoutName.allCases.map(\.rawValue))
  }
}
