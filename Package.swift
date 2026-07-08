// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Roundabout",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Roundabout",
            path: "Sources/Roundabout",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
