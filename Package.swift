// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "murmur", targets: ["Murmur"]),
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
    ],
    targets: [
        .target(
            name: "MurmurCore",
            path: "Sources/MurmurCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Speech"),
            ]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/Murmur"
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurTests"
        ),
    ],
    // The code talks to C callbacks and audio threads; Swift 6 strict concurrency is a later project.
    swiftLanguageModes: [.v5]
)
