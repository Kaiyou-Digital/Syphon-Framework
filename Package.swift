// swift-tools-version: 5.9
import PackageDescription

// Syphon's Metal server and client (https://github.com/Syphon/Syphon-Framework, BSD 2-Clause, LICENSE.Syphon), built by SwiftPM alone.
let package = Package(
    name: "Syphon",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Syphon", targets: ["Syphon"])],
    targets: [
        .target(
            name: "Syphon",
            exclude: [],
            cSettings: [.headerSearchPath("."), .headerSearchPath("include/Syphon"), .define("SYPHONLOG(...)", to: "")],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("IOSurface"), .linkedFramework("Metal")]
        ),
        .testTarget(name: "SyphonTests", dependencies: ["Syphon"]),
    ]
)
