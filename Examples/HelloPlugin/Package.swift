// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelloPlugin",
    platforms: [.macOS("15.6")],
    dependencies: [.package(name:"Linvell",path:"../..")],
    targets: [.executableTarget(name:"HelloPlugin",dependencies:[.product(name:"LinvellPluginKit",package:"Linvell")])],
    swiftLanguageModes: [.v5]
)
