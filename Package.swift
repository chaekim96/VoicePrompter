// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoicePrompter",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: tokenization, fuzzy matching, script alignment, recognizer interface. No UI, fully unit-tested.
        .target(name: "PrompterCore"),
        .executableTarget(
            name: "VoicePrompter",
            dependencies: ["PrompterCore"],
            exclude: ["Info.plist", "VoicePrompter.entitlements"]
        ),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore"]),
    ]
)
