// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VelaMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vela-macd", targets: ["vela-macd"])
    ],
    targets: [
        .executableTarget(name: "vela-macd")
    ]
)
