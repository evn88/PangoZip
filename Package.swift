// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "PangoZip",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [.executable(name: "PangoZip", targets: ["PangoZipApp"])],
  targets: [
    .target(name: "PangoZipCore", resources: [.process("Resources")]),
    .executableTarget(name: "PangoZipApp", dependencies: ["PangoZipCore"]),
    .testTarget(name: "PangoZipCoreTests", dependencies: ["PangoZipCore"]),
    .testTarget(name: "PangoZipAppTests", dependencies: ["PangoZipApp", "PangoZipCore"]),
  ]
)
