// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Backtrack", platforms: [.macOS(.v14)], products: [
    .executable(name: "Backtrack", targets: ["Backtrack"])
], targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "BacktrackCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "Backtrack", dependencies: ["BacktrackCore"]),
    .testTarget(name: "BacktrackCoreTests", dependencies: ["BacktrackCore"]),
    .testTarget(name: "BacktrackAppTests", dependencies: ["Backtrack", "BacktrackCore"])
])
