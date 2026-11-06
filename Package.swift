// swift-tools-version: 6.0
// Homelab iOS: a SwiftPM package built into an iOS app by xtool (see xtool.yml and docs/SETUP.md).

import Foundation
import PackageDescription

// `KIT_ONLY=1 swift test` builds only HomelabKit (Foundation only), so its tests run on Linux, where SwiftUI and
// WidgetKit don't exist. Not `#if os(Linux)`: xtool evaluates this manifest on Linux too and needs the app targets.
let kitOnly = ProcessInfo.processInfo.environment["KIT_ONLY"] == "1"

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

var products: [Product] = [
    .library(name: "HomelabKit", targets: ["HomelabKit"]),
]
var targets: [Target] = [
    .target(
        name: "HomelabKit",
        resources: [.copy("Fixtures")],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "HomelabKitTests",
        dependencies: ["HomelabKit"],
        swiftSettings: swiftSettings
    ),
]

if !kitOnly {
    products += [
        // xtool: the app is the library product named in xtool.yml; the widget extension is another one.
        .library(name: "Homelab", targets: ["Homelab"]),
        .library(name: "HomelabWidget", targets: ["HomelabWidget"]),
        .library(name: "HomelabShare", targets: ["HomelabShare"]),
    ]
    targets += [
        .target(name: "HomelabDesign", dependencies: ["HomelabKit"], swiftSettings: swiftSettings),
        .target(name: "HomelabUI", dependencies: ["HomelabKit", "HomelabDesign"], swiftSettings: swiftSettings),
        .target(name: "Homelab", dependencies: ["HomelabKit", "HomelabUI"], swiftSettings: swiftSettings),
        .target(
            name: "HomelabWidget",
            dependencies: ["HomelabKit", "HomelabDesign"],
            swiftSettings: swiftSettings,
            // The extension's entry point is Foundation's _NSExtensionMain, so nothing references the WidgetBundle's
            // `main` and -dead_strip drops the whole widget. The empty binary then fails xtool's signing ("Can't find
            // free space of LoadCommands for CodeSignature"). Keep `main` and everything it uses.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_main"])]
        ),
        .target(
            name: "HomelabShare",
            dependencies: ["HomelabKit", "HomelabDesign"],
            swiftSettings: swiftSettings,
            // Same dead-strip problem as the widget: only the runtime looks the principal class up (by name,
            // NSExtensionPrincipalClass), so -dead_strip drops it and signing fails ("Can't find free space of
            // LoadCommands for CodeSignature"). Keep the class (and with it everything it uses).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_OBJC_CLASS_$_ShareViewController"])]
        ),
    ]
}

let package = Package(
    name: "Homelab",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: products,
    targets: targets
)
