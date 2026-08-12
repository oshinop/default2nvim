import AppKit
import Foundation

private struct LaunchFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct TerminalConfiguration: Decodable {
    let id: String
    let displayName: String
    let bundleIdentifier: String
    let fallbackPaths: [String]
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var launchWorkItem: DispatchWorkItem?
    private var didFinishLaunching = false
    private var hasLaunched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true

        let commandLinePaths = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-psn_") && $0 != "--"
        }
        enqueue(commandLinePaths.map { URL(fileURLWithPath: $0) })
        scheduleLaunch()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    private func enqueue(_ urls: [URL]) {
        for url in urls {
            let normalized = url.standardizedFileURL
            guard !pendingURLs.contains(where: { $0.path == normalized.path }) else {
                continue
            }
            pendingURLs.append(normalized)
        }
        scheduleLaunch()
    }

    private func scheduleLaunch() {
        guard didFinishLaunching, !hasLaunched else { return }

        launchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.launch()
        }
        launchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func launch() {
        guard !hasLaunched else { return }
        hasLaunched = true

        do {
            try launchTerminal(paths: pendingURLs.map(\.path))
        } catch {
            present(error: error)
        }

        NSApplication.shared.terminate(nil)
    }

    private func launchTerminal(paths: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try loadTerminalConfiguration(environment: environment)
        let terminalPath = try findTerminal(configuration)
        let workingDirectory = workingDirectory(for: paths)

        guard let launcherURL = Bundle.main.url(forResource: "launch-nvim", withExtension: "zsh") else {
            throw LaunchFailure(message: "The app bundle is missing launch-nvim.zsh. Reinstall NvimBridge.")
        }

        var command: [String] = []
        if let configuredNvim = environment["NVIMBRIDGE_NVIM"], !configuredNvim.isEmpty {
            command = ["/usr/bin/env", "NVIMBRIDGE_NVIM=\(configuredNvim)"]
        }
        command += ["/bin/zsh", "-l", launcherURL.path] + paths
        switch configuration.id {
        case "ghostty":
            try launchWithOpen(
                terminalPath,
                arguments: ["--working-directory=\(workingDirectory)", "-e"] + command,
                terminalName: configuration.displayName
            )
        case "kitty":
            try launchWithOpen(
                terminalPath,
                arguments: ["--directory", workingDirectory] + command,
                terminalName: configuration.displayName
            )
        case "alacritty":
            try launchWithOpen(
                terminalPath,
                arguments: ["--working-directory", workingDirectory, "-e"] + command,
                terminalName: configuration.displayName
            )
        case "wezterm":
            try launchWezTerm(
                terminalPath,
                workingDirectory: workingDirectory,
                command: command
            )
        case "iterm2":
            try launchWithAppleScript(
                application: "iTerm2",
                scriptLines: [
                    "on run argv",
                    "tell application \"iTerm2\"",
                    "create window with default profile command (item 1 of argv)",
                    "activate",
                    "end tell",
                    "end run",
                ],
                command: shellCommand(workingDirectory: workingDirectory, arguments: command)
            )
        case "terminal":
            try launchWithAppleScript(
                application: "Terminal",
                scriptLines: [
                    "on run argv",
                    "tell application \"Terminal\"",
                    "do script (item 1 of argv)",
                    "activate",
                    "end tell",
                    "end run",
                ],
                command: shellCommand(workingDirectory: workingDirectory, arguments: command)
            )
        default:
            throw LaunchFailure(message: "Unsupported terminal backend: \(configuration.id). Run default2nvim wrapper set-term.")
        }
    }

    private func loadTerminalConfiguration(
        environment: [String: String]
    ) throws -> TerminalConfiguration {
        guard let configurationURL = Bundle.main.url(
            forResource: "TerminalBackends",
            withExtension: "plist"
        ) else {
            throw LaunchFailure(message: "The app bundle has no terminal backend catalog. Reinstall the Neovim wrapper.")
        }

        let configurations: [TerminalConfiguration]
        do {
            let data = try Data(contentsOf: configurationURL)
            configurations = try PropertyListDecoder().decode(
                [TerminalConfiguration].self,
                from: data
            )
        } catch {
            throw LaunchFailure(message: "The terminal backend catalog is invalid: \(error.localizedDescription)")
        }

        let selectedID = environment["NVIMBRIDGE_TERMINAL"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? UserDefaults.standard.string(forKey: "terminalBackend") ?? "ghostty"
        guard let configuration = configurations.first(where: { $0.id == selectedID }) else {
            throw LaunchFailure(
                message: "Unsupported terminal backend preference: \(selectedID). Run default2nvim wrapper set-term."
            )
        }
        return configuration
    }

    private func findTerminal(_ configuration: TerminalConfiguration) throws -> String {

        if let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: configuration.bundleIdentifier
        ) {
            return registeredURL.path
        }

        for fallbackPath in configuration.fallbackPaths {
            let expandedPath = NSString(string: fallbackPath).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                return expandedPath
            }
        }

        throw LaunchFailure(
            message: "\(configuration.displayName) is not installed. Run default2nvim wrapper set-term and choose an installed terminal."
        )
    }

    private func launchWithOpen(
        _ terminalPath: String,
        arguments: [String],
        terminalName: String
    ) throws {
        try runProcess(
            executable: "/usr/bin/open",
            arguments: ["-na", terminalPath, "--args"] + arguments,
            failureDescription: "macOS could not launch \(terminalName)"
        )
    }

    private func launchWezTerm(
        _ terminalPath: String,
        workingDirectory: String,
        command: [String]
    ) throws {
        let candidates = [
            URL(fileURLWithPath: terminalPath)
                .appendingPathComponent("Contents/MacOS/wezterm").path(percentEncoded: false),
            URL(fileURLWithPath: terminalPath)
                .appendingPathComponent("Contents/MacOS/wezterm-gui").path(percentEncoded: false),
        ]

        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw LaunchFailure(message: "The WezTerm command-line executable is missing from \(terminalPath).")
        }

        try runProcess(
            executable: executable,
            arguments: ["start", "--always-new-process", "--cwd", workingDirectory, "--"] + command,
            failureDescription: "WezTerm could not start",
            waitForExit: false
        )
    }

    private func launchWithAppleScript(
        application: String,
        scriptLines: [String],
        command: String
    ) throws {
        var arguments: [String] = []
        for line in scriptLines {
            arguments += ["-e", line]
        }
        arguments += ["--", command]

        try runProcess(
            executable: "/usr/bin/osascript",
            arguments: arguments,
            failureDescription: "AppleScript could not launch \(application)"
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        failureDescription: String,
        waitForExit: Bool = true
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()

        guard waitForExit else { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LaunchFailure(
                message: "\(failureDescription) (status \(process.terminationStatus))."
            )
        }
    }

    private func shellCommand(workingDirectory: String, arguments: [String]) -> String {
        let quotedCommand = arguments.map(shellQuote).joined(separator: " ")
        return "cd \(shellQuote(workingDirectory)) && exec \(quotedCommand)"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func workingDirectory(for paths: [String]) -> String {
        guard let firstPath = paths.first else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: firstPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return firstPath
        }

        return URL(fileURLWithPath: firstPath).deletingLastPathComponent().path
    }

    private func present(error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NSLog("NvimBridge: %@", message)

        NSApplication.shared.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "NvimBridge could not open the file"
        alert.informativeText = message
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
