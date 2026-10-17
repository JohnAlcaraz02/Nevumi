import AppKit
import Foundation

// Xcode's Run pre-action invokes this after building and signing the app.
// Optional arguments let the installer be verified without changing Applications.
enum InstallError: LocalizedError {
    case invalidSource, invalidDestination, refusedToQuit

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "The finished Nevumi build could not be found. Build the Nevumi target first."
        case .invalidDestination: return "The destination contains a different app. Nevumi was not replaced."
        case .refusedToQuit: return "The installed Nevumi is still running. Quit it and press Run again."
        }
    }
}

func install() throws {
    let environment = ProcessInfo.processInfo.environment
    let arguments = Array(CommandLine.arguments.dropFirst())
    let source: URL
    if let argument = arguments.first {
        source = URL(fileURLWithPath: argument).standardizedFileURL
    } else if let buildDirectory = environment["TARGET_BUILD_DIR"],
              let product = environment["FULL_PRODUCT_NAME"] {
        source = URL(fileURLWithPath: buildDirectory).appendingPathComponent(product).standardizedFileURL
    } else {
        throw InstallError.invalidSource
    }
    let destination = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "/Applications/Nevumi.app")
        .standardizedFileURL
    let bundleID = "com.johnalcaraz.SleepMusic"
    let manager = FileManager.default
    guard source.pathExtension == "app", let bundle = Bundle(url: source),
          bundle.bundleIdentifier == bundleID, let executable = bundle.executableURL,
          manager.isExecutableFile(atPath: executable.path) else { throw InstallError.invalidSource }
    guard destination.lastPathComponent == "Nevumi.app",
          !source.path.hasPrefix(destination.path + "/"),
          !destination.path.hasPrefix(source.path + "/") else { throw InstallError.invalidDestination }
    if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
        print("Nevumi is already built in Applications.")
        return
    }
    if manager.fileExists(atPath: destination.path) {
        let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true, Bundle(url: destination)?.bundleIdentifier == bundleID else {
            throw InstallError.invalidDestination
        }
    }

    let parent = destination.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(".nevumi-development-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    var removeStaging = true
    defer { if removeStaging { try? manager.removeItem(at: staging) } }
    let stagedApp = staging.appendingPathComponent("Nevumi.app")
    let backup = staging.appendingPathComponent("previous.app")
    // Copy the whole signed bundle, including frameworks and resources.
    try manager.copyItem(at: source, to: stagedApp)

    // Only stop the destination copy; Xcode manages its own debug process.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
        $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
    }
    for app in running {
        guard app.terminate() else { throw InstallError.refusedToQuit }
    }
    let deadline = Date().addingTimeInterval(5)
    while running.contains(where: { !$0.isTerminated }), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard running.allSatisfy(\.isTerminated) else { throw InstallError.refusedToQuit }

    let hadPreviousApp = manager.fileExists(atPath: destination.path)
    if hadPreviousApp { try manager.moveItem(at: destination, to: backup) }
    do {
        try manager.moveItem(at: stagedApp, to: destination)
    } catch {
        // Restore the previous installation if the final move fails.
        if hadPreviousApp {
            do { try manager.moveItem(at: backup, to: destination) }
            catch {
                // Keep the backup available for manual recovery.
                removeStaging = false
                fputs("Nevumi recovery copy: \(backup.path)\n", stderr)
            }
        }
        throw error
    }
    print("Updated \(destination.path) from \(source.path).")
}

do {
    try install()
} catch {
    fputs("error: Couldn’t update the installed Nevumi: \(error.localizedDescription)\n", stderr)
    exit(1)
}
