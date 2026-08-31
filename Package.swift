// swift-tools-version: 5.9
import PackageDescription

// MultitouchSupport (private framework) is loaded at runtime via dlopen,
// so no linker flags are needed anywhere.
let package = Package(
    name: "TabSwipe",
    platforms: [.macOS(.v13)],
    targets: [
        // Core logic (testable library)
        .target(
            name: "TabSwipeCore",
            path: "Sources"
        ),
        // App entry point
        .executableTarget(
            name: "TabSwipe",
            dependencies: ["TabSwipeCore"],
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
