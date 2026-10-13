// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Keyvault",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KeyvaultCore", targets: ["KeyvaultCore"]),
        .executable(name: "Keyvault", targets: ["KeyvaultApp"]),
        .executable(name: "kv", targets: ["KVCLI"]),
        .executable(name: "kv-tests", targets: ["KeyvaultTests"]),
    ],
    targets: [
        .target(name: "KeyvaultCore"),
        .executableTarget(name: "KeyvaultApp", dependencies: ["KeyvaultCore"]),
        .executableTarget(name: "KVCLI", dependencies: ["KeyvaultCore"]),
        .executableTarget(name: "KeyvaultTests", dependencies: ["KeyvaultCore"], path: "Tests/KeyvaultCoreTests"),
    ]
)
