// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SectionedListUI",
    platforms: [.iOS("27.0")],
    products: [.library(name: "SectionedListUI", targets: ["SectionedListUI"])],
    targets: [.target(name: "SectionedListUI")]
)
