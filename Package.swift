// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VimText",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "VimTextCore",
            path: "VimText",
            exclude: [
                "Info.plist",
                "VimText.entitlements",
                "VimTextApp.swift"
            ],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .executableTarget(
            name: "VimText",
            dependencies: ["VimTextCore"],
            path: "App"
        ),
        .executableTarget(
            name: "VimTextSmokeTests",
            dependencies: ["VimTextCore"],
            path: "Tests/VimTextSmokeTests"
        )
    ]
)
