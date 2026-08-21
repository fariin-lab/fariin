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
    // ⚠️ 16 AND NOT A POINT HIGHER, AND THAT IS A COMPILE-TIME DECISION RATHER THAN A TASTE ONE.
    // 26 was tried first and does not exist at this tools version. 17 does, and it broke the build a
    // different way: at 17 the OLD `onChange(of:perform:)` is deprecated and a NEW two-parameter
    // overload appears, so every one of this package's `onChange` call sites suddenly has two
    // candidates to choose between — and `StoryDetailView.body`, which has several, went straight
    // past the type-checker's budget ("unable to type-check this expression in reasonable time").
    // 16 clears everything the package actually uses and introduces no new overloads.
    platforms: [.iOS(.v16)],
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
