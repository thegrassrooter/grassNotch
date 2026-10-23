
 // swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "grassIsland",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "grassIsland",
            targets: ["grassIsland"]
        )
    ],
    targets: [
        .executableTarget(
            name: "grassIsland",
            resources: [.copy("Assets")]
        )
    ]
)
