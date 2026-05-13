// swift-tools-version:5.10
//
// figma-audit — SwiftSyntax-based extractor that emits c2-audit.json
// from a *Screen.swift / *View.swift file. Built locally by install.sh
// (mirror of MCPFigma's build_from_source) and cached at
// ~/.local/share/figma-audit/bin/figma-audit.
//
// SwiftSyntax version pin: 601.x matches Swift 6.x toolchain (Xcode 26
// baseline). Update when bumping toolchain.

import PackageDescription

let package = Package(
    name: "figma-audit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "figma-audit", targets: ["FigmaAudit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "601.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FigmaAudit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/FigmaAudit"
        ),
    ]
)
