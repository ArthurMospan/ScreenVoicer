import AppKit

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

/// Command-line modes run inside a real NSApplication (pasteboard, fonts, SwiftUI rendering need it).
func runCommandLine(_ work: @escaping @MainActor () async -> Int32) -> Never {
    Log.echoToConsole = true
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        exit(await work())
    }
    app.run()
    exit(0)
}

if let directory = argument(after: "--render-icons") {
    do {
        try IconRenderer.renderIconset(to: URL(fileURLWithPath: directory, isDirectory: true))
        exit(0)
    } catch {
        print("Failed: \(error)")
        exit(1)
    }
}

if arguments.contains("--selftest") {
    runCommandLine { await SelfTest.run(arguments) }
}

if let directory = argument(after: "--snapshots") {
    runCommandLine { await Snapshots.render(to: URL(fileURLWithPath: directory, isDirectory: true)) }
}

if arguments.contains("--check-update") {
    // prints what the updater sees (for testing releases)
    runCommandLine {
        do {
            if let update = try await UpdateService.check() {
                print("Update \(update.version) available: \(update.assetUrl) (\(update.size) bytes, sha256 \(update.sha256 ?? "n/a"))")
            } else {
                print("Up to date (\(AppInfo.version)).")
            }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}

if arguments.contains("--update") {
    // the same update as the menu button, without the UI (quit the running copy first)
    runCommandLine {
        do {
            guard let update = try await UpdateService.check() else {
                print("Up to date (\(AppInfo.version)).")
                return 0
            }
            let zip = try await UpdateService.download(update) { _ in }
            try UpdateService.installAfterExit(zip: zip)
            print("Installing \(update.version) from \(zip.path).")
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}

let application = NSApplication.shared
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
