// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DynamicTerminal",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Wrapper for the precompiled static library
        .target(
            name: "CVTerm",
            dependencies: [],
            path: "Sources/CVTerm",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedLibrary("vterm", .when(platforms: [.macOS])),
                .unsafeFlags(["-LSources/CVTerm"])
            ]
        ),
        // Swift Executable
        .executableTarget(
            name: "DynamicTerminal",
            dependencies: ["CVTerm"],
            path: "Sources/DynamicTerminal"
        ),
    ]
)
