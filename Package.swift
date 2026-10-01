// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mirador",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiradorApp", targets: ["MiradorApp"]),
        .executable(name: "mirador", targets: ["mirador"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MiradorCore"),
        .executableTarget(
            name: "MiradorApp",
            dependencies: ["MiradorCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Mirador.app/Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "mirador", dependencies: ["MiradorCore"]),
        .testTarget(name: "MiradorCoreTests", dependencies: ["MiradorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
