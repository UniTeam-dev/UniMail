// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UniMail",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "UniMail",
            path: "Sources/UniMail"
        )
    ]
)
