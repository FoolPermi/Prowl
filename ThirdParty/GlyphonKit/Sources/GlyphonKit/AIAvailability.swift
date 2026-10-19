#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability of the on-device language model behind AI picks.
///
/// The recommender itself silently degrades to keyword retrieval when the
/// model is unavailable (see ``SymbolRecommender``); UI uses this to explain
/// why instead of presenting a retrieval result as an AI pick.
public enum AIAvailability: Sendable, Equatable {
  case available
  case appleIntelligenceNotEnabled
  case modelNotReady
  case deviceNotSupported

  /// Current availability of the system language model.
  public static var current: AIAvailability {
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, iOS 26.0, *) else { return .deviceNotSupported }
    switch SystemLanguageModel.default.availability {
    case .available:
      .available
    case .unavailable(.appleIntelligenceNotEnabled):
      .appleIntelligenceNotEnabled
    case .unavailable(.modelNotReady):
      .modelNotReady
    case .unavailable(.deviceNotEligible):
      .deviceNotSupported
    case .unavailable:
      .deviceNotSupported
    }
    #else
    .deviceNotSupported
    #endif
  }

  public var isAvailable: Bool { self == .available }
}
