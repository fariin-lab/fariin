// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// ⚠️ RAISED FROM 5.6 WITH THE PLATFORM BELOW, AND IT HAD TO BE. `.v26` is not merely a newer case,
// it does not EXIST in 5.6 — "error: 'v26' is unavailable" — because the enum a package can name is
// fixed by its tools version. 5.9 is the conservative one that certainly has what is needed.

import PackageDescription

let package = Package(
    name: "StoryUI",
    // ⛔ RAISED FROM v15 (2026-08-21). The app has always been iOS 26 and this floor bought nothing:
    // it only meant every modern API compiled in `Kulan/` and FAILED inside this package, a trap
    // that has cost a CI round trip before. The reply pill needs `TextField(axis:)` and a
    // `lineLimit` RANGE, both iOS 16.
    //
    // ⚠️ 17 RATHER THAN THE APP'S 26 ON PURPOSE. The floor only has to clear what this package
    // actually uses, and every step up is another thing that can be unavailable in whatever tools
    // version the runner brings. 26 was tried first and is what broke the build.
    platforms: [.iOS(.v17)],
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
