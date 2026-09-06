import Foundation

func findExecutable(_ candidates: [String]) -> String? {
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

private func runCapture(_ executable: String, _ args: [String]) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

@MainActor
final class BrewManager: ObservableObject {
    @Published var brewPath: String? = findExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    @Published var ffmpegInstalled = false
    @Published var ffmpegVersion: String? = nil
    @Published var isOutdated: Bool? = nil
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var logText = ""
    @Published var errorMessage: String? = nil

    var brewAvailable: Bool { brewPath != nil }

    func refreshStatus() async {
        ffmpegInstalled = FileManager.default.isExecutableFile(atPath: ffmpegPath)
        if ffmpegInstalled, let output = await runCapture(ffmpegPath, ["-version"]) {
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            ffmpegVersion = parts.count >= 3 ? String(parts[2]) : nil
        } else {
            ffmpegVersion = nil
        }
        isOutdated = nil
    }

    func checkForUpdate() async {
        guard let brewPath else { return }
        isBusy = true
        busyLabel = "Checking for updates..."
        defer { isBusy = false }
        let output = await runCapture(brewPath, ["outdated", "ffmpeg"])
        isOutdated = !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func install() async {
        await runBrew(args: ["install", "ffmpeg"], label: "Installing ffmpeg...")
    }

    func update() async {
        await runBrew(args: ["upgrade", "ffmpeg"], label: "Updating ffmpeg...")
    }

    private func runBrew(args: [String], label: String) async {
        guard let brewPath else { return }
        isBusy = true
        busyLabel = label
        logText = ""
        errorMessage = nil

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = args
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = outPipe

                outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in
                        self?.logText += str
                        if let text = self?.logText, text.count > 6000 {
                            self?.logText = String(text.suffix(6000))
                        }
                    }
                }

                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: ())
                    } else {
                        cont.resume(throwing: RunError.failed("brew exited with code \(proc.terminationStatus)"))
                    }
                }

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isBusy = false
        await refreshStatus()
        isOutdated = false
    }
}
