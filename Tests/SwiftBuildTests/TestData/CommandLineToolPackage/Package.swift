// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "CommandLineToolPackage",
    products: [
        .executable(
            name: "CommandLineToolPackage",
            targets: ["CommandLineToolPackage"]),
    ],
    targets: [
        .target(
            name: "CommandLineToolPackage",
            dependencies: []),
    ]
)
