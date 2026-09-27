// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "spia",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OBDCore", targets: ["OBDCore"]),
        .library(name: "OBDSerial", targets: ["OBDSerial"]),
        .library(name: "SpiaKit", targets: ["SpiaKit"]),
        .executable(name: "spia", targets: ["spia"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "OBDCore"),
        .target(name: "OBDSerial", dependencies: ["OBDCore"]),
        .executableTarget(
            name: "spia",
            dependencies: [
                "OBDCore",
                "OBDSerial",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .target(
            name: "SpiaKit", dependencies: ["OBDCore"], resources: [.copy("Recordings")]),
        .testTarget(name: "OBDCoreTests", dependencies: ["OBDCore"]),
        .testTarget(name: "SpiaKitTests", dependencies: ["SpiaKit", "OBDCore"]),
    ]
)
