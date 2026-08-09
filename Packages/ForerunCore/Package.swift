// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForerunCore",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(name: "ForerunCore", targets: ["ForerunCore"])
    ],
    targets: [
        .target(
            name: "ForerunCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "ForerunCoreTests",
            dependencies: ["ForerunCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
