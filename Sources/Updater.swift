import AppKit
import Foundation

/// Finds newer GitHub releases of the app and installs them the way it is distributed:
/// `brew upgrade` of the ahmadarif-lab/tap/video-trimmer cask.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        /// Tag without its leading "v", e.g. "1.2.0".
        let version: String
        let pageURL: URL
    }

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    @Published private(set) var latest: Release?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var checkFailed = false
    /// Non-nil while an update runs: the step it is on.
    @Published private(set) var progressText: String?
    /// Why the last update attempt failed.
    @Published private(set) var errorMessage: String?
    /// Set once brew has put a newer bundle on disk. This process keeps running the old one until
    /// it is relaunched.
    @Published private(set) var installedVersion: String?

    private static let cask = "ahmadarif-lab/tap/video-trimmer"
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ahmadarif-lab/video-trimmer/releases/latest")!
    /// Where the cask installs the app — its postflight hardcodes the same path.
    private static let caskAppPath = "/Applications/Video Trimmer.app"

    var isUpdating: Bool { progressText != nil }

    var availableUpdate: Release? {
        guard let latest, Self.isVersion(latest.version, newerThan: Self.currentVersion) else { return nil }
        return latest
    }

    /// Whether updating replaces this copy in place, rather than opening the release page.
    var installsWithHomebrew: Bool { Self.caskBrew != nil }

    /// Checks at launch, then every 6 hours; a failed check (no network yet, say) retries after
    /// 15 minutes.
    init() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let succeeded = await self?.check() else { return }
                try? await Task.sleep(for: succeeded ? .seconds(6 * 3600) : .seconds(15 * 60))
            }
        }
    }

    @discardableResult
    func check() async -> Bool {
        guard !isChecking, !isUpdating else { return false }
        isChecking = true
        let started = ContinuousClock.now
        let succeeded: Bool
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latest = Release(
                version: release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName,
                pageURL: release.htmlURL
            )
            lastChecked = Date()
            checkFailed = false
            succeeded = true
        } catch {
            checkFailed = true
            succeeded = false
        }
        // GitHub often answers in under a tenth of a second, which would only flash the spinner.
        try? await Task.sleep(until: started + .milliseconds(800))
        isChecking = false
        return succeeded
    }

    /// A Homebrew install is upgraded in place; any other copy — a DMG dragged over by hand, a
    /// local build — gets the release page instead.
    func update() async {
        guard let release = availableUpdate, !isUpdating, installedVersion == nil else { return }
        guard let brew = Self.caskBrew else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        errorMessage = nil
        defer { progressText = nil }
        do {
            // `brew upgrade` only refreshes the tap itself when its last update is a day old, so
            // it may not know this release yet.
            progressText = "Updating Homebrew..."
            try await Self.runBrew(brew, ["update", "--quiet"])
            progressText = "Installing v\(release.version)..."
            try await Self.runBrew(brew, ["upgrade", "--cask", Self.cask])
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // brew exits 0 when it has nothing to do as well — a release published before the cask
        // was bumped, say — so only the version now on disk counts.
        guard let onDisk = Self.versionOnDisk, Self.isVersion(onDisk, newerThan: Self.currentVersion) else {
            errorMessage = "Homebrew doesn't have v\(release.version) yet — try again later."
            return
        }
        installedVersion = onDisk
    }

    /// The new bundle only takes over from a fresh launch. The reopen waits for this process to
    /// exit, so the old and new copies never run side by side.
    func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
        ]
        do {
            try reopen.run()
        } catch {
            errorMessage = "Quit and reopen Video Trimmer to finish updating."
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Component-wise and numeric, so "1.10.0" is newer than "1.9.2".
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// brew, when this running copy is the one the cask manages. For any other copy — a local
    /// build in ~/Applications, say — brew would replace a different bundle than the one running.
    private static var caskBrew: String? {
        guard Bundle.main.bundlePath == caskAppPath,
              let brew = findExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) else { return nil }
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
        let caskroom = prefix.appendingPathComponent("Caskroom/video-trimmer").path
        return FileManager.default.fileExists(atPath: caskroom) ? brew : nil
    }

    /// The version now on disk at this bundle's path, which differs from `currentVersion` once
    /// brew has replaced the bundle.
    private static var versionOnDisk: String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
    }

    /// Runs brew to completion. Its output is drained on a background thread while it runs —
    /// `brew update` can write more than a pipe buffer holds, and would stall on a pipe nobody
    /// reads — and a failure reports brew's own "Error:" line rather than its whole transcript.
    private static func runBrew(_ brew: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().async {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                guard process.terminationStatus != 0 else {
                    cont.resume()
                    return
                }
                let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                let brief = lines.last(where: { $0.hasPrefix("Error:") }) ?? lines.last(where: { !$0.isEmpty })
                cont.resume(throwing: RunError.failed(brief ?? "brew exited with code \(process.terminationStatus)"))
            }
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
