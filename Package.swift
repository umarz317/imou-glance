// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImouPeek",
    platforms: [.macOS("15.2")],
    products: [.executable(name: "ImouPeek", targets: ["ImouMac"])],
    targets: [
        .executableTarget(name: "ImouMac", resources: [.copy("PlayerAssets")]),
        .testTarget(name: "ImouMacTests", dependencies: ["ImouMac"])
    ]
)
