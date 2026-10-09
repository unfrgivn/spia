// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "spia",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OBDCore", targets: ["OBDCore"]),
        .library(name: "OBDSerial", targets: ["OBDSerial"]),
        .library(name: "OBDBluetooth", targets: ["OBDBluetooth"]),
        .library(name: "SpiaKit", targets: ["SpiaKit"]),
        .library(name: "SpiaStore", targets: ["SpiaStore"]),
        .library(name: "SpiaAssist", targets: ["SpiaAssist"]),
        .library(name: "SpiaReference", targets: ["SpiaReference"]),
        .executable(name: "spia", targets: ["spia"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "OBDCore"),
        .target(name: "OBDSerial", dependencies: ["OBDCore"]),
        .target(name: "OBDBluetooth", dependencies: ["OBDCore"]),
        .executableTarget(
            name: "spia",
            dependencies: [
                "OBDCore",
                "OBDSerial",
                "OBDBluetooth",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/spia/Info.plist",
                ])
            ]),
        .target(
            name: "SpiaKit", dependencies: ["OBDCore"],
            resources: [.copy("Recordings"), .copy("Catalog")]),
        .target(name: "SpiaAssist", dependencies: ["SpiaKit"]),
        .target(name: "SpiaReference"),
        .target(
            name: "SpiaStore", dependencies: ["SpiaKit", "SpiaAssist", "SpiaReference", "OBDCore"]),
        .target(name: "SpiaTestSupport", dependencies: ["OBDCore"], path: "Tests/Support"),
        .testTarget(name: "OBDCoreTests", dependencies: ["OBDCore"]),
        .testTarget(name: "OBDBluetoothTests", dependencies: ["OBDBluetooth"]),
        .testTarget(
            name: "SpiaKitTests", dependencies: ["SpiaKit", "OBDCore", "SpiaTestSupport"]),
        .testTarget(
            name: "SpiaStoreTests",
            dependencies: [
                "SpiaStore", "SpiaKit", "SpiaAssist", "SpiaReference", "OBDCore",
                "SpiaTestSupport",
            ]),
        .testTarget(name: "SpiaAssistTests", dependencies: ["SpiaAssist", "SpiaKit"]),
        .testTarget(name: "SpiaReferenceTests", dependencies: ["SpiaReference"]),
    ]
)
