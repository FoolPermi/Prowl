import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Apple's on-device Foundation Model, which only macOS 26 provides.
///
/// The framework is absent from the macOS 15 SDK, so the import and every call stay
/// behind `canImport`; there the service reports itself unavailable and branch names
/// fall back to the random adjective-animal names.
struct FoundationModelLLMService: LLMService {
  private static let timeout: Duration = .seconds(3)

  var isAvailable: Bool {
    #if canImport(FoundationModels)
      guard #available(macOS 26.0, *) else { return false }
      return SystemLanguageModel.default.isAvailable
    #else
      return false
    #endif
  }

  func generate(prompt: String) async throws -> String {
    #if canImport(FoundationModels)
      guard #available(macOS 26.0, *) else { throw LLMServiceError.unavailable }
      let session = LanguageModelSession()
      let response = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          let result = try await session.respond(to: prompt)
          return result.content
        }
        group.addTask {
          try await Task.sleep(for: Self.timeout)
          throw CancellationError()
        }
        guard let first = try await group.next() else {
          throw CancellationError()
        }
        group.cancelAll()
        return first
      }
      return response
    #else
      throw LLMServiceError.unavailable
    #endif
  }
}
