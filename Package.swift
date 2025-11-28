// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetSpeed",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "NetSpeed",
            targets: ["NetSpeed"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "NetSpeed",
            path: "Sources",
            exclude: ["Assets"]
        )
    ]
)
