// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VukhoAI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VukhoAI", targets: ["VukhoAIApp"])
    ],
    targets: [
        .executableTarget(
            name: "VukhoAIApp",
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
