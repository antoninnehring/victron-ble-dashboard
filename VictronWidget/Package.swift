// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VictronWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VictronWidget",
            path: "Sources",
            resources: [
                .copy("Victron_Energy_Logo.svg"),
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
    ]
)
