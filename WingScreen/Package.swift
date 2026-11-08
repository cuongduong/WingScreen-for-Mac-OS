// swift-tools-version:5.9
import PackageDescription

// Một app duy nhất "WingScreen" gồm cả 2 chế độ:
//   - Máy chính (phát hình): tạo màn hình ảo, quay + nén, nhận chuột/phím
//   - Màn hình phụ (nhận hình): hiển thị toàn màn hình, gửi chuột/phím
// Chạy trên macOS 12.3+ (Intel và Apple Silicon — build.sh tạo bản universal).

let package = Package(
    name: "WingScreen",
    platforms: [.macOS("12.3")],
    products: [
        .executable(name: "WingScreen", targets: ["WingScreen"]),
    ],
    targets: [
        // Cầu nối Objective-C tới API riêng CGVirtualDisplay (tạo màn hình ảo)
        .target(
            name: "CGVirtualDisplayKit",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        // Giao thức mạng + gói tin dùng chung
        .target(
            name: "WingScreenShared",
            linkerSettings: [.linkedFramework("Network"), .linkedFramework("CoreMedia")]
        ),
        .executableTarget(
            name: "WingScreen",
            dependencies: ["CGVirtualDisplayKit", "WingScreenShared"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
