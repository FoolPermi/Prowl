import ProjectDescription

// The macOS app. `make generate` turns this manifest into `App/Prowl.xcodeproj`; the generated
// project is not in Git. Build settings are in `Config/*.xcconfig`.

func configurations(
  _ name: String,
  debug: SettingsDictionary = [:],
  release: SettingsDictionary = [:]
) -> [Configuration] {
  [
    .debug(name: .debug, settings: debug, xcconfig: "Config/\(name)-Debug.xcconfig"),
    .release(name: .release, settings: release, xcconfig: "Config/\(name)-Release.xcconfig"),
  ]
}

// Folders that Xcode copies into the app bundle, each as one folder. The Makefile stages the
// ignored ones; `git-wt` is a submodule. They must exist before generation (`make generate`
// checks this).
let bundledFolders: [Path] = [
  "Resources/docs",
  "Resources/workflows",
  "Resources/skills",
  "Resources/ghostty",
  "Resources/terminfo",
  "Resources/prowl-cli",
  "Resources/agent-hooks",
  "../ThirdParty/git-wt",
]

let verifyGitWtScript = """
  WT_SCRIPT="${PROJECT_DIR}/../ThirdParty/git-wt/wt"
  if [ ! -f "$WT_SCRIPT" ]; then
    echo "error: Missing $WT_SCRIPT. Run: git submodule update --init ThirdParty/git-wt" >&2
    exit 1
  fi
  if [ ! -x "$WT_SCRIPT" ]; then
    echo "error: $WT_SCRIPT is not executable." >&2
    exit 1
  fi
  """

let verifyEmbeddedToolsScript = """
  for TOOL in prowl-cli/prowl prowl-mirror-relay/prowl-mirror-relay; do
    BIN="${PROJECT_DIR}/Resources/$TOOL"
    if [ ! -x "$BIN" ]; then
      echo "error: Missing executable $BIN. Run: make embed-cli-debug" >&2
      exit 1
    fi
  done
  """

let project = Project(
  name: "Prowl",
  options: .options(
    automaticSchemesOptions: .disabled,
    defaultKnownRegions: ["en", "Base", "zh-Hans"],
    developmentRegion: "en",
    disableBundleAccessors: true,
    disableSynthesizedResourceAccessors: true
  ),
  // Prowl deploys to macOS 15 and builds with Xcode 26 (Swift 6.2), so every package is held
  // at the newest release whose manifest still works there. The newest pointfree releases
  // declare `swift-tools-version: 6.4` and therefore need Xcode 27, which does not run on
  // macOS 15. Transitive packages are pinned by exact version too: a `from:` requirement
  // would resolve them to those Swift 6.4 releases again. Bump a pin only together with the
  // Xcode floor in AGENTS.md.
  packages: [
    .package(path: "../Shared"),
    // Upstream GlyphonKit declares macOS 26 and imports FoundationModels unconditionally;
    // SwiftPM refuses that for a macOS 15 app. See ThirdParty/GlyphonKit/PATCHES.md.
    .package(path: "../ThirdParty/GlyphonKit"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", .exact("1.9.2")),
    .package(url: "https://github.com/sparkle-project/Sparkle", .exact("2.9.2")),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", .exact("1.17.0")),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", .exact("1.26.1")),
    .package(url: "https://github.com/getsentry/sentry-cocoa/", .exact("9.3.0")),
    .package(url: "https://github.com/PostHog/posthog-ios.git", .exact("3.38.0")),
    .package(url: "https://github.com/onevcat/YiTong.git", .exact("0.2.0")),
    .package(url: "https://github.com/pointfreeco/swift-sharing", .exact("2.9.1")),
    .package(url: "https://github.com/pointfreeco/swift-perception", .exact("2.0.11")),
    .package(url: "https://github.com/pointfreeco/swift-navigation", .exact("2.8.0")),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", .exact("1.7.0")),
    .package(url: "https://github.com/pointfreeco/swift-clocks", .exact("1.1.0")),
    .package(url: "https://github.com/pointfreeco/combine-schedulers", .exact("1.2.0")),
    .package(url: "https://github.com/apple/swift-collections", .exact("1.2.1")),
    .package(url: "https://github.com/swiftlang/swift-syntax", .exact("601.0.0")),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", .exact("1.4.3")),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", .exact("1.1.1")),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", .exact("1.11.0")),
  ],
  settings: .settings(configurations: configurations("Project"), defaultSettings: .none),
  targets: [
    .target(
      name: "Prowl",
      destinations: .macOS,
      product: .app,
      productName: "Prowl",
      bundleId: "com.onevcat.prowl",
      infoPlist: .file(path: "Config/Info.plist"),
      // Sources that the app shares with the mirror clients and the relay process. The app
      // compiles them into its own module.
      sources: [
        "../Mirror/Shared/*.swift",
        "../Mirror/Relay/Sources/MirrorRelayProtocol/*.swift",
      ],
      resources: .resources(bundledFolders.map { .folderReference(path: $0) }),
      buildableFolders: ["Sources"],
      copyFiles: [
        .resources(
          name: "Embed mirror relay",
          subpath: "prowl-mirror-relay",
          files: [.glob(pattern: "Resources/prowl-mirror-relay/prowl-mirror-relay", codeSignOnCopy: true)]
        )
      ],
      scripts: [
        .pre(script: verifyGitWtScript, name: "Verify git-wt script", basedOnDependencyAnalysis: false),
        .pre(
          script: verifyEmbeddedToolsScript,
          name: "Verify prowl-cli binary",
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: [
        .package(product: "ProwlCLIShared"),
        .package(product: "ComposableArchitecture"),
        .package(product: "Dependencies"),
        .package(product: "CasePaths"),
        .package(product: "Sentry"),
        .package(product: "PostHog"),
        .package(product: "Sparkle"),
        .package(product: "YiTong"),
        .package(product: "GlyphonKit"),
        .xcframework(path: "Frameworks/GhosttyKit.xcframework"),
        .sdk(name: "Carbon", type: .framework),
      ],
      settings: .settings(
        // Tuist derives the product name and the bundle identifier from the target, and its
        // values override the xcconfig files. The Debug app has its own name and identifier
        // so that it can be installed next to the release app.
        configurations: configurations(
          "App",
          debug: ["PRODUCT_NAME": "Prowl Debug", "PRODUCT_BUNDLE_IDENTIFIER": "com.onevcat.prowl.debug"]
        ),
        defaultSettings: .none
      )
    ),
    .target(
      name: "ProwlTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.onevcat.prowlTests",
      infoPlist: nil,
      // `Fixtures` goes into the test bundle as one folder, not as separate files.
      resources: [.folderReference(path: "Tests/Fixtures")],
      buildableFolders: [
        .folder("Tests", exceptions: .exceptions([.exception(excluded: ["Fixtures"])]))
      ],
      dependencies: [
        .target(name: "Prowl"),
        .package(product: "DependenciesTestSupport"),
        .package(product: "OrderedCollections"),
        .package(product: "ProwlCLIShared"),
      ],
      settings: .settings(configurations: configurations("Tests"), defaultSettings: .none)
    ),
  ],
  schemes: [
    .scheme(
      name: "Prowl",
      buildAction: .buildAction(targets: ["Prowl"]),
      testAction: .targets(
        [.testableTarget(target: "ProwlTests", parallelization: .enabled)],
        // Most suites run on the main actor, so wider parallelism only queues tests behind it:
        // the total time stays the same, but each test's reported duration then holds a minute
        // of queue time. Eight keeps the total within a few percent and the durations real.
        arguments: .arguments(environmentVariables: ["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH": "8"]),
        configuration: .debug,
        // Tests assert on English copy.
        options: .options(language: "en", region: "US")
      ),
      runAction: .runAction(configuration: .debug, executable: "Prowl"),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(configuration: .debug, executable: "Prowl"),
      analyzeAction: .analyzeAction(configuration: .debug)
    )
  ]
)
