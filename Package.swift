// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Breadcrumbs",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Breadcrumbs",
            path: "Sources/Breadcrumbs",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
