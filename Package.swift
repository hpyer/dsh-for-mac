// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DshForMac",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "DshForMac", targets: ["DshForMac"]),
    ],
    targets: [
        .executableTarget(
            name: "DshForMac",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "DshForMacTests", dependencies: ["DshForMac"]),
    ]
)
