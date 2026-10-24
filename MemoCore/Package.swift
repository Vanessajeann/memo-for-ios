// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MemoCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [.library(name: "MemoCore", targets: ["MemoCore"])],
    targets: [.target(name: "MemoCore"), .testTarget(name: "MemoCoreTests", dependencies: ["MemoCore"])]
)
