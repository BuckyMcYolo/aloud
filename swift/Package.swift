// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Aloud",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored at revision 20bf04c5 — xcodebuild cannot resolve a remote
        // package that itself depends on a local one (its Misaki G2P).
        .package(path: "Vendor/kokoro-swift")
    ],
    targets: [
        .executableTarget(
            name: "Aloud",
            dependencies: [
                .product(name: "Kokoro", package: "kokoro-swift")
            ]
        )
    ]
)
