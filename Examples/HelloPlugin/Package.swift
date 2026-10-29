// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelloPlugin",
    platforms: [.macOS("15.6")],
    dependencies: [.package(name:"LinvellPluginKit",path:"../../Sources/LinvellPluginKit")],
    targets: [.executableTarget(name:"HelloPlugin",dependencies:[.product(name:"LinvellPluginKit",package:"LinvellPluginKit")])],
    swiftLanguageModes: [.v5]
)
