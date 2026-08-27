// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TranscribatorMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "TranscribatorMac", targets: ["TranscribatorMac"])
    ],
    targets: [
        .target(
            name: "CAudioCapture",
            path: "Sources/CAudioCapture",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "TranscribatorCore",
            dependencies: ["CAudioCapture"],
            path: "Sources/TranscribatorCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "TranscribatorMac",
            dependencies: ["TranscribatorCore"],
            path: "Sources/TranscribatorMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "TranscribatorCoreChecks",
            dependencies: ["TranscribatorCore"],
            path: "Sources/TranscribatorCoreChecks"
        )
    ],
    swiftLanguageModes: [.v5]
)
