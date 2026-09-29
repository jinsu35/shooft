// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shooft",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Shooft",
            path: "Sources/Shooft",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ])
    ]
)
