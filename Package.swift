// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriveBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DriveBar", targets: ["DriveBar"])
    ],
    targets: [
        .executableTarget(
            name: "DriveBar",
            path: "Sources/DriveBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
