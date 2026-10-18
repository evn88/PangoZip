// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "PangoZip",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [.executable(name: "PangoZip", targets: ["PangoZipApp"])],
  targets: [
    .systemLibrary(name: "CLibArchive"),
    .target(
      name: "PangoZipCore", dependencies: ["CLibArchive"], resources: [.process("Resources")]),
    .executableTarget(name: "PangoZipApp", dependencies: ["PangoZipCore"]),
    .target(
      name: "PangoZipPreview", dependencies: ["PangoZipCore"], path: "QuickLookExtension",
      exclude: ["Info.plist", "Entitlements.plist"]),
    .testTarget(name: "PangoZipPreviewTests", dependencies: ["PangoZipPreview", "PangoZipCore"]),
    .testTarget(name: "PangoZipCoreTests", dependencies: ["PangoZipCore"]),
    .testTarget(name: "PangoZipAppTests", dependencies: ["PangoZipApp", "PangoZipCore"]),
  ]
)
