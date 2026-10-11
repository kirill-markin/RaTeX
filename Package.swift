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
            url: "https://github.com/kirill-markin/RaTeX/releases/download/catalyst-binary-0.1.14-1/RaTeX.xcframework.zip",
            checksum: "37deca19f15dff2c330dea5c7b06c4a337462902f510fbea141f5dc30e5ed80a"
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
