import Foundation

protocol LLMService: Sendable {
  var isAvailable: Bool { get }
  func generate(prompt: String) async throws -> String
}

/// A generation request that this build or this system cannot serve.
enum LLMServiceError: Error {
  case unavailable
}
