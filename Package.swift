// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampOn",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LampOn", targets: ["LampOn"]),
    ],
    targets: [
        .target(name: "LampOnCore"),
        .executableTarget(name: "LampOn", dependencies: ["LampOnCore"]),
        .testTarget(name: "LampOnCoreTests", dependencies: ["LampOnCore"]),
    ]
)
