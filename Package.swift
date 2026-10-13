// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Backtrace", platforms: [.macOS(.v14)], products: [
    .executable(name: "Backtrace", targets: ["Backtrace"])
], targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "BacktraceCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "Backtrace", dependencies: ["BacktraceCore"]),
    .testTarget(name: "BacktraceCoreTests", dependencies: ["BacktraceCore"]),
    .testTarget(name: "BacktraceAppTests", dependencies: ["Backtrace", "BacktraceCore"])
])
