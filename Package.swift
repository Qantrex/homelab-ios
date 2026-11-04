// swift-tools-version: 6.0
// SPIKE (throwaway): proves xtool + SideStore + widget + App Group + tailnet on a real iPhone. See SPIKE.md.

import Foundation
import PackageDescription

// `KIT_ONLY=1 swift test` builds only the Foundation code, so its tests run on Linux (no SwiftUI there).
// Not `#if os(Linux)`: xtool evaluates this manifest on Linux too, and must see the app targets.
let kitOnly = ProcessInfo.processInfo.environment["KIT_ONLY"] == "1"

var products: [Product] = []
var targets: [Target] = [
    // Foundation only, so it also compiles (and is tested) on Linux.
    .target(name: "SpikeShared"),
    .testTarget(name: "SpikeSharedTests", dependencies: ["SpikeShared"]),
]
if !kitOnly {
    // xtool: the app is one library product (named in xtool.yml), each extension another.
    products += [
        .library(name: "Homelab", targets: ["Homelab"]),
        .library(name: "HomelabWidget", targets: ["HomelabWidget"]),
    ]
    targets += [
        .target(name: "Homelab", dependencies: ["SpikeShared"]),
        .target(name: "HomelabWidget", dependencies: ["SpikeShared"]),
    ]
}

let package = Package(
    name: "HomelabSpike",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: products,
    targets: targets
)
