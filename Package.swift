// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "midway",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "midway", targets: ["Midway"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
        .package(url: "https://github.com/apple/swift-nio-imap", exact: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "MidwayCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "IMAPCommands", package: "swift-nio-imap"),
            ]
        ),
        .executableTarget(name: "Midway", dependencies: ["MidwayCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "MidwayCoreTests", dependencies: ["MidwayCore"]),
    ]
)
package.targets.append(.executableTarget(name: "Seed", dependencies: ["MidwayCore"]))
