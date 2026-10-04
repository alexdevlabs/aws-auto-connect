// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AWSAutoConnect",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AWSAutoConnect",
            path: "Sources/AWSAutoConnect",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Installed root-owned by the helper; the DNS server while the tunnel is up.
        .executableTarget(
            name: "dns-relay",
            path: "Sources/DNSRelay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
