// swift-tools-version:5.9
import PackageDescription

// The macOS twin of the Windows app (repo root). Built by mac/scripts/build.sh, which first fetches
// whisper.cpp's prebuilt xcframework (Metal) into Vendor/ and checks its SHA-256.
let package = Package(
    name: "ScreenVoicer",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .executableTarget(
            name: "ScreenVoicer",
            dependencies: ["whisper"],
            path: "Sources/ScreenVoicer",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
