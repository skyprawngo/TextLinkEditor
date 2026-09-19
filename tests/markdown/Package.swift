// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MarkdownRuntime", platforms: [.macOS(.v15)],
    products: [.library(name: "MarkdownRuntime", type: .dynamic, targets: ["MarkdownRuntime"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")],
    targets: [.target(name: "MarkdownRuntime", dependencies: [.product(name: "Markdown", package: "swift-markdown")])])
