// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GhostMic",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GhostMic", targets: ["GhostMicApp"])
    ],
    targets: [
        .executableTarget(
            name: "GhostMicApp",
            exclude: [
                "Resources/__pycache__"
            ],
            resources: [
                .copy("Resources/transcribe.py")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
