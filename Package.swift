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
                "VimText.entitlements"
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
        // The MCP stdio server clients are pointed at. Deliberately has no
        // VimTextCore dependency: it relays to the running app, and an MCP
        // client spawns it fresh on every session, so it stays tiny and fast.
        .executableTarget(
            name: "vimtext-mcp",
            path: "MCP"
        ),
        .executableTarget(
            name: "VimTextSmokeTests",
            dependencies: ["VimTextCore"],
            path: "Tests/VimTextSmokeTests"
        ),
        .executableTarget(
            name: "VimTextBench",
            dependencies: ["VimTextCore"],
            path: "Tests/VimTextBench"
        )
    ]
)
