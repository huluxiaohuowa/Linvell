// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Linvell",
    platforms: [.macOS("15.6")],
    products: [.executable(name: "Linvell", targets: ["Linvell"]),.executable(name:"LinvellUpdater",targets:["LinvellUpdater"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "5c83a9d214e7354697624c11deb4e488bdcfabad")
    ],
    targets: [
        .target(name: "LinvellCore"),
        .executableTarget(name: "Linvell", dependencies: ["LinvellCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name:"LinvellUpdater",dependencies:["LinvellCore"]),
        .testTarget(name: "LinvellCoreTests", dependencies: ["LinvellCore"]),
        .testTarget(name:"LinvellUITests",dependencies:["Linvell","LinvellCore"])
    ],
    swiftLanguageModes: [.v5]
)
