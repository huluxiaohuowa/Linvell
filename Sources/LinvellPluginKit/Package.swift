// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"LinvellPluginKit",products:[.library(name:"LinvellPluginKit",targets:["LinvellPluginKit"])],targets:[.target(name:"LinvellPluginKit",path:".",exclude:["Package.swift"])],swiftLanguageModes:[.v5])
