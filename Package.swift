// swift-tools-version: 6.0
import Foundation
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// Swift Testing лежит не в стандартных путях, и где именно — зависит от активного тулчейна:
// - только Command Line Tools: подключаем фреймворк явно (и компиляция, и rpath);
// - Xcode (даже если CLT тоже стоят): компилятор находит Testing сам, нужен только rpath на фреймворк Xcode.
// Брать фреймворк CLT под компилятором Xcode нельзя: версии макросов не совпадут, тесты не соберутся.
let fm = FileManager.default
let developerDir: String = {
    if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !d.isEmpty { return d }
    if let d = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") { return d }
    return ""
}()
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let xcodeFrameworks = developerDir + "/Platforms/MacOSX.platform/Developer/Library/Frameworks"
let usesXcode = developerDir.contains(".app/Contents/Developer") && fm.fileExists(atPath: xcodeFrameworks + "/Testing.framework")
let usesCLTTesting = !usesXcode && fm.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwift: [SwiftSetting] = v5 + (usesCLTTesting ? [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])] : [])
let testLink: [LinkerSetting] = usesCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]
    : usesXcode ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", xcodeFrameworks])] : []

let package = Package(
    name: "AgentHUD",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AgentHUD", targets: ["AgentHUD"]),
        .executable(name: "agenthud-hook", targets: ["agenthud-hook"]),
    ],
    targets: [
        .target(name: "AgentHUDCore", swiftSettings: v5),
        .executableTarget(name: "agenthud-hook", dependencies: ["AgentHUDCore"], swiftSettings: v5),
        .executableTarget(name: "AgentHUD", dependencies: ["AgentHUDCore"], swiftSettings: v5),
        // Тесты — исполняемый таргет: без Xcode `swift test` не запускает Swift Testing,
        // поэтому раннер вызываем сами: `swift run agenthud-tests`.
        .executableTarget(
            name: "agenthud-tests",
            dependencies: ["AgentHUDCore"],
            path: "Tests/AgentHUDCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: testSwift,
            linkerSettings: testLink + [.linkedFramework("Testing")]
        ),
    ]
)
