// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DshForMac",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "DshForMac", targets: ["DshForMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3"),
    ],
    targets: [
        .executableTarget(
            name: "DshForMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "DshForMacTests", dependencies: ["DshForMac"]),
    ]
)
