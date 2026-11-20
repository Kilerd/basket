// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Basket",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Basket", targets: ["Basket"]),
        .executable(name: "basket-ax", targets: ["basket-ax"]),
        .executable(name: "basket-docker", targets: ["basket-docker"]),
        .library(name: "BasketCore", targets: ["BasketCore"]),
        .library(name: "BasketAXKit", targets: ["BasketAXKit"]),
    ],
    targets: [
        // Domain model + apple/container backend (CLI JSON), fixtures backend, host resource accounting.
        .target(name: "BasketCore"),
        // SwiftUI macOS app.
        .executableTarget(name: "Basket", dependencies: ["BasketCore", "BasketAXKit"]),
        // Accessibility (AX) tree capture, UI lint rules and reports for E2E testing.
        .target(name: "BasketAXKit"),
        // E2E runner: drives Basket.app through the Accessibility API and audits layout/consistency.
        .executableTarget(name: "basket-ax", dependencies: ["BasketAXKit"]),
        // `docker` shim: translates docker commands to apple/container (installed as ~/.basket/bin/docker).
        .executableTarget(name: "basket-docker", dependencies: ["BasketCore"]),
        .testTarget(
            name: "BasketCoreTests",
            dependencies: ["BasketCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BasketAXKitTests", dependencies: ["BasketAXKit"]),
    ],
    swiftLanguageModes: [.v6]
)
