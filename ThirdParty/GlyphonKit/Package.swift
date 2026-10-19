// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "GlyphonKit",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "GlyphonKit", targets: ["GlyphonKit"]),
  ],
  targets: [
    .target(
      name: "GlyphonKit",
      resources: [.process("Resources")],
      swiftSettings: [
        // Prowl deploys to macOS 15 and weak-links FoundationModels: keep this module
        // from adding a strong autolink for the framework. See PATCHES.md.
        .unsafeFlags(["-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "FoundationModels"]),
      ]
    ),
    .executableTarget(
      name: "glyphon-extract",
      path: "Sources/GlyphonExtract"
    ),
    .testTarget(
      name: "GlyphonKitTests",
      dependencies: ["GlyphonKit"]
    ),
  ]
)
