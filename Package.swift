// swift-tools-version: 5.9
import PackageDescription

// MultitouchSupport (private framework) is loaded at runtime via dlopen,
// so no linker flags are needed anywhere.
let package = Package(
    name: "TabSwipe",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle ships as a binary XCFramework. `swift build` links against it
        // but will not embed it — build.sh copies Sparkle.framework into
        // Contents/Frameworks and signs it before the outer bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        // Core logic (testable library)
        .target(
            name: "TabSwipeCore",
            path: "Sources"
        ),
        // Vendored LetsMove (first-run "move to /Applications"). Objective-C with
        // manual retain/release, so it must be compiled with ARC off. Links
        // Security for the admin-authorized install path.
        .target(
            name: "LetsMove",
            path: "LetsMove",
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Security")]
        ),
        // App entry point
        .executableTarget(
            name: "TabSwipe",
            dependencies: [
                "TabSwipeCore",
                .product(name: "Sparkle", package: "Sparkle"),
                "LetsMove"
            ],
            path: "App"
        ),
        // Tests (standalone executable — no Xcode required)
        .executableTarget(
            name: "TabSwipeTests",
            dependencies: ["TabSwipeCore"],
            path: "Tests"
        )
    ]
)
