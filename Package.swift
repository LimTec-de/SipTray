// swift-tools-version: 5.10
import PackageDescription
import Foundation

let rootPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let pjsipLibrarySearchPaths = [
    "\(rootPath)/Vendor/pjproject/pjsip/lib",
    "\(rootPath)/Vendor/pjproject/pjmedia/lib",
    "\(rootPath)/Vendor/pjproject/pjnath/lib",
    "\(rootPath)/Vendor/pjproject/pjlib-util/lib",
    "\(rootPath)/Vendor/pjproject/pjlib/lib",
    "\(rootPath)/Vendor/pjproject/third_party/lib"
]

let package = Package(
    name: "SipTray",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SipTray", targets: ["SipTray"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.1")
    ],
    targets: [
        .target(
            name: "CPJSIP",
            path: "Bridge/CPJSIP",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I", "Vendor/pjproject/pjsip/include",
                    "-I", "Vendor/pjproject/pjlib/include",
                    "-I", "Vendor/pjproject/pjlib-util/include",
                    "-I", "Vendor/pjproject/pjnath/include",
                    "-I", "Vendor/pjproject/pjmedia/include"
                ])
            ]
        ),
        .executableTarget(
            name: "SipTray",
            dependencies: [
                "CPJSIP",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .unsafeFlags([
                ] + pjsipLibrarySearchPaths.flatMap { ["-L", $0] }),
                .linkedLibrary("pjsua"),
                .linkedLibrary("pjsip-ua"),
                .linkedLibrary("pjsip-simple"),
                .linkedLibrary("pjsip"),
                .linkedLibrary("pjmedia-codec"),
                .linkedLibrary("pjmedia-videodev"),
                .linkedLibrary("pjmedia-audiodev"),
                .linkedLibrary("pjmedia"),
                .linkedLibrary("pjnath"),
                .linkedLibrary("pjlib-util"),
                .linkedLibrary("gsmcodec"),
                .linkedLibrary("speex"),
                .linkedLibrary("ilbccodec"),
                .linkedLibrary("srtp"),
                .linkedLibrary("resample"),
                .linkedLibrary("webrtc"),
                .linkedLibrary("pj"),
                .linkedLibrary("m"),
                .linkedLibrary("pthread"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Sparkle"),
            ]
        )
    ]
)
