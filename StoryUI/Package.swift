// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StoryUI",
    // ⛔ RAISED FROM v15 TO v26 (2026-08-21). The app has always been iOS 26 and this floor bought
    // nothing: it only meant every modern API compiled in `Kulan/` and FAILED inside this package,
    // which is a trap that has cost a CI round trip before. The reply pill needs `TextField(axis:)`
    // and a `lineLimit` RANGE — iOS 16 — and there is no version of this app that runs below 26.
    platforms: [.iOS(.v26)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "StoryUI",
            targets: ["StoryUI"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "StoryUI",
            dependencies: []),
    ]
)
