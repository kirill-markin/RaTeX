// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RaTeX",
    platforms: [.iOS(.v14), .macOS(.v14), .macCatalyst(.v14)],
    products: [
        .library(name: "RaTeX", targets: ["RaTeX"]),
    ],
    targets: [
        .binaryTarget(
            name: "RaTeXFFI",
            url: "https://github.com/kirill-markin/RaTeX/releases/download/catalyst-binary-0.1.15-1/RaTeX.xcframework.zip",
            checksum: "cf7eb8f7623a2baedc6710e7829184571698bbebb1f5878d3522c7b6c7b457f5"
        ),

        .target(
            name: "RaTeX",
            dependencies: ["RaTeXFFI"],
            path: "platforms/ios/Sources/Ratex",
            resources: [
                .copy("Fonts"),
            ]
        ),
    ]
)
