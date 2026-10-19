// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "ProwlCLI",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(
      name: "prowl",
      targets: ["prowl"]
    )
  ],
  dependencies: [
    .package(name: "ProwlShared", path: "../Shared"),
    // Pinned exactly for the same reason as App/Project.swift: the newest releases need a
    // Swift tools version newer than the Swift 6.2 toolchain that macOS 15 can run.
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.1"),
    .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.13.1"),
    .package(url: "https://github.com/onevcat/Rainbow", exact: "4.2.1"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    .package(url: "https://github.com/swiftlang/swift-syntax", exact: "601.0.0"),
    .package(url: "https://github.com/apple/swift-collections", exact: "1.2.1"),
  ],
  targets: [
    .executableTarget(
      name: "prowl",
      dependencies: [
        .product(name: "ProwlCLIShared", package: "ProwlShared"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Rainbow", package: "Rainbow"),
      ]
    ),
    .target(
      name: "ProwlCLIContracts",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "ProwlCLITests",
      dependencies: [
        "ProwlCLIContracts",
        "prowl",
        .product(name: "ProwlCLIShared", package: "ProwlShared"),
        .product(name: "JSONSchema", package: "swift-json-schema"),
        .product(name: "Yams", package: "Yams"),
      ]
    ),
  ]
)
