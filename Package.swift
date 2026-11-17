// swift-tools-version: 5.9
import PackageDescription

// Syphon (https://github.com/Syphon/Syphon-Framework, BSD 2-Clause, LICENSE.Syphon), built by SwiftPM alone.
//   Syphon   the Metal server and client, with the base classes, messaging and server directory they share.
//   SyphonGL the OpenGL server, client and image (and the older SyphonServer, SyphonClient and SyphonImage names for them), on top of Syphon.
let package = Package(
    name: "Syphon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Syphon", targets: ["Syphon"]),
        .library(name: "SyphonGL", targets: ["SyphonGL"]),
    ],
    targets: [
        .target(
            name: "Syphon",
            exclude: [],
            cSettings: [.headerSearchPath("."), .headerSearchPath("include/Syphon"), .define("SYPHONLOG(...)", to: "")],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("IOSurface"), .linkedFramework("Metal")]
        ),
        .target(
            name: "SyphonGL",
            dependencies: ["Syphon"],
            cSettings: [.headerSearchPath("."), .headerSearchPath("include/Syphon"), .headerSearchPath("../Syphon"), .headerSearchPath("../Syphon/include/Syphon"), .define("SYPHONLOG(...)", to: "")],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("IOSurface"), .linkedFramework("OpenGL")]
        ),
        .testTarget(name: "SyphonTests", dependencies: ["Syphon"]),
        .testTarget(name: "SyphonGLTests", dependencies: ["Syphon", "SyphonGL"]),
    ]
)
