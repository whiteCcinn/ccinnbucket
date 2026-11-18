// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnBucket",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorageSigning", targets: ["StorageSigning"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "CcinnBucketKit", targets: ["CcinnBucketKit"]),
        .executable(name: "CcinnBucket", targets: ["CcinnBucket"]),
    ],
    targets: [
        // Pure request signing: canonicalisation, AWS SigV4, OSS V4/V1, presigning. No I/O, no clock.
        .target(name: "StorageSigning", swiftSettings: settings),
        // HTTP transport, provider dialects (S3, OSS), XML, listing, multipart and transfer engines.
        .target(name: "StorageKit", dependencies: ["StorageSigning"], swiftSettings: settings),
        // Incremental gzip and Zstandard decoding (bounded memory) and compression of edited previews. No I/O.
        .target(name: "Decompression", swiftSettings: settings),
        // UI-independent app logic: accounts & Keychain, credential import, navigation, transfer queue state.
        .target(name: "CcinnBucketKit", dependencies: ["StorageKit", "Decompression"], swiftSettings: settings),
        // SwiftUI / AppKit application.
        .executableTarget(name: "CcinnBucket", dependencies: ["StorageKit", "CcinnBucketKit", "Decompression"], swiftSettings: settings),

        .testTarget(name: "StorageSigningTests", dependencies: ["StorageSigning"], resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(name: "StorageKitTests", dependencies: ["StorageSigning", "StorageKit"], swiftSettings: settings),
        .testTarget(name: "CcinnBucketKitTests", dependencies: ["StorageKit", "CcinnBucketKit", "Decompression"], swiftSettings: settings),
        .testTarget(name: "DecompressionTests", dependencies: ["Decompression"], resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(name: "IntegrationTests", dependencies: ["StorageSigning", "StorageKit", "CcinnBucketKit"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
