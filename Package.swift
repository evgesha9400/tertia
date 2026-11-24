// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tertia",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "TertiaCore", targets: ["TertiaCore"]),
        .library(name: "TertiaCLI", targets: ["TertiaCLI"]),
        .library(name: "TertiaUI", targets: ["TertiaUI"]),
        .executable(name: "TertiaApp", targets: ["TertiaApp"]),
        .executable(name: "TertiaWidget", targets: ["TertiaWidget"]),
    ],
    targets: [
        .target(
            name: "TertiaCore",
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "TertiaCLI",
            dependencies: ["TertiaCore"]
        ),
        .target(
            name: "TertiaUI",
            dependencies: ["TertiaCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "TertiaApp",
            dependencies: ["TertiaCore", "TertiaCLI", "TertiaUI"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "TertiaWidget",
            dependencies: ["TertiaCore", "TertiaUI"],
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
