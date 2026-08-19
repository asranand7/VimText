// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VimText",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // The handshake, tool definitions and socket path, shared by the app
        // and the relay so the two can't describe the server differently.
        // Foundation-only: it is linked into `vimtext-mcp`, which is spawned
        // on every agent session.
        .target(
            name: "MCPContract",
            path: "MCPContract"
        ),
        .target(
            name: "VimTextCore",
            dependencies: ["MCPContract"],
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
            dependencies: ["MCPContract"],
            path: "MCP"
        ),
        .executableTarget(
            name: "VimTextSmokeTests",
            dependencies: ["VimTextCore", "MCPContract"],
            path: "Tests/VimTextSmokeTests"
        ),
        .executableTarget(
            name: "VimTextBench",
            dependencies: ["VimTextCore"],
            path: "Tests/VimTextBench"
        )
    ]
)
