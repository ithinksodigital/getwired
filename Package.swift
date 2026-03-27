// swift-tools-version: 6.2
// Quick CLI build: `swift build -c release` → `.build/.../Wired` (no .app bundle, no Icon Composer icon).
// For Wired.app (Icon Composer icon, DMG via Organizer, etc.), use Xcode: open Wired.xcodeproj.

import PackageDescription

let package = Package(
    name: "Wired",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Wired"
        ),
    ]
)
