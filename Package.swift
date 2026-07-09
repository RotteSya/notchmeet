// swift-tools-version:6.0
import PackageDescription

// NotchMeet — 日本就活向 実時面接プロンプター（macOS, native Swift, zero external deps）
// 见 PLAN.md。仅用 Apple 系统框架，保证离线可编译。
let package = Package(
    name: "NotchMeet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "notchmeet",
            path: "Sources/NotchMeet",
            swiftSettings: [
                .swiftLanguageMode(.v5) // 渐进迁移，先不强制 Swift6 严格并发
            ]
        ),
        .testTarget(
            name: "notchmeetTests",
            dependencies: ["notchmeet"],
            path: "Tests/NotchMeetTests"
        ),
    ]
)
