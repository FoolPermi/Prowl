# Local patches

Prowl vendors this copy of [GlyphonKit](https://github.com/onevcat/GlyphonKit) 0.1.0 instead of
depending on the upstream package, because Prowl deploys to macOS 15 while upstream declares
`platforms: [.macOS(.v26)]` and imports FoundationModels unconditionally. SwiftPM refuses to
link a package whose platform minimum is newer than the app's, so the package has to live here.

Keep the diff to upstream as small as possible; everything below is marked in the source.

| File | Change |
| --- | --- |
| `Package.swift` | Swift tools 6.2 → 6.1, macOS/iOS platform minimums 26 → 15/18, and this module no longer autolinks FoundationModels strongly, so Prowl's weak link keeps the binary launchable on macOS 15. |
| `Sources/GlyphonKit/AIAvailability.swift` | The FoundationModels import and the availability switch sit behind `canImport` and `@available`; older SDKs and macOS 15 report `.deviceNotSupported`. |
| `Sources/GlyphonKit/SymbolRecommender.swift` | `KeywordExtraction` and the model pipeline moved into `aiRecommendation(for:candidateLimit:)`, all behind `canImport` plus `@available(macOS 26.0, iOS 26.0, *)`. Without the model the recommender returns the same retrieval-only result it already produced when the model was unavailable. |

`Tests/` and `eval/` are upstream and are not built by the app. To re-sync, copy the new upstream
release over this directory and re-apply the three changes above.
