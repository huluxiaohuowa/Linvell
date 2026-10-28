// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"SwiftTerm",platforms:[.macOS("15.6")],products:[.library(name:"SwiftTerm",targets:["SwiftTerm"])],targets:[.target(name:"SwiftTerm",path:"Sources/SwiftTerm",exclude:["Mac/README.md"])],swiftLanguageModes:[.v5])
