import Foundation

let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
let ffprobePath = "/opt/homebrew/bin/ffprobe"

enum RunError: Error, LocalizedError {
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .failed(let msg): return msg
        case .cancelled: return "Cancelled"
        }
    }
}

final class ProgressRunner {
    private var process: Process?
    private var cancelled = false

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func run(arguments: [String], onProgress: @escaping (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            self.process = process
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            final class Box { var tail = "" }
            let box = Box()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                for line in str.split(separator: "\n") {
                    if line.hasPrefix("out_time=") {
                        let value = line.replacingOccurrences(of: "out_time=", with: "")
                        if let seconds = try? parseTimeToSeconds(value) {
                            onProgress(seconds)
                        }
                    }
                }
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                box.tail += str
                if box.tail.count > 4000 { box.tail = String(box.tail.suffix(4000)) }
            }

            process.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if self?.cancelled == true {
                    cont.resume(throwing: RunError.cancelled)
                } else if proc.terminationStatus == 0 {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: RunError.failed("ffmpeg exited with code \(proc.terminationStatus): \(box.tail.suffix(400))"))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

func probeDuration(path: String) async -> Double? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffprobePath)
    process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let secs = Double(str) else { return nil }
    return secs
}

func probeVideoBitrateKbps(path: String) async -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffprobePath)
    process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=bit_rate", "-of", "default=noprint_wrappers=1:nokey=1", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let bps = Double(str), bps > 0 else { return nil }
    return Int(bps / 1000.0)
}

func probeResolution(path: String) async -> (Int, Int)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffprobePath)
    process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    let parts = str.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
    return (w, h)
}

/// Picks names that don't exist yet, appending " (1)", " (2)", … so an export never overwrites an
/// earlier one. A split export is versioned as a *set*: every part takes the same suffix, so
/// re-running a three-clip split gives "(part 1) (1)", "(part 2) (1)", "(part 3) (1)" rather than a
/// batch whose numbering depends on which of its files happened to exist already.
func availableOutputPaths(in dir: URL, baseNames: [String]) -> [String] {
    let fm = FileManager.default
    func paths(_ tag: String) -> [String] {
        baseNames.map { dir.appendingPathComponent("\($0)\(tag).mp4").path }
    }
    for version in 0...999 {
        let candidates = paths(version == 0 ? "" : " (\(version))")
        if !candidates.contains(where: { fm.fileExists(atPath: $0) }) { return candidates }
    }
    // A thousand versions deep, stop counting and take something certainly free.
    return paths(" (\(UUID().uuidString.prefix(8)))")
}

@MainActor
final class TrimEngine: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var titleText: String = ""
    @Published var stageText: String = ""
    @Published var etaText: String = "-"
    /// How long the finished export took, filled in once the pipeline completes.
    @Published var elapsedText: String = ""
    @Published var errorMessage: String? = nil
    @Published var outputPaths: [String] = []
    /// Set when the run was stopped by the user, so a partly finished split isn't shown as success.
    @Published var wasCancelled = false

    private var startDate: Date?
    private var currentRunner: ProgressRunner?
    /// The file currently being written, deleted if the run stops before it is complete.
    /// Clips that already finished are kept — a cancel should not throw away good work.
    private var inFlightOutput: String?

    func setProgress(_ value: Double) {
        progress = value
        guard let startDate, value > 0.02 else {
            etaText = "calculating..."
            return
        }
        let elapsed = Date().timeIntervalSince(startDate)
        let totalEstimated = elapsed / value
        let remaining = max(0, totalEstimated - elapsed)
        etaText = formatSeconds(remaining)
    }

    func cancel() {
        currentRunner?.cancel()
    }

    /// `mode` decides whether the marked ranges are the parts to drop or the only parts to keep;
    /// `splitOutputs` writes one file per resulting segment instead of joining them.
    /// `targetHeight` is nil to keep the source resolution, otherwise the output is scaled to that height.
    func start(inputPath: String, duration: Double, ranges: [(Double, Double)], mode: MarkMode, splitOutputs: Bool, targetHeight: Int?) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        errorMessage = nil
        outputPaths = []
        wasCancelled = false
        titleText = splitOutputs ? "Splitting Video..." : "Trimming Video..."
        stageText = "Preparing..."
        etaText = "calculating..."
        elapsedText = ""
        startDate = Date()

        Task { [weak self] in
            do {
                try await self?.runPipeline(inputPath: inputPath, duration: duration, ranges: ranges,
                                            mode: mode, splitOutputs: splitOutputs, targetHeight: targetHeight)
            } catch {
                // A split export writes straight to its destination, so the clip that was still
                // encoding is truncated and has to go — the finished ones stay.
                self?.discardInFlightOutput()
                if case RunError.cancelled = error {
                    self?.wasCancelled = true
                    self?.titleText = "Cancelled"
                    self?.stageText = self?.finishedClipsNote() ?? "Export cancelled"
                } else {
                    self?.errorMessage = error.localizedDescription
                    self?.titleText = "Export Failed"
                }
                self?.isRunning = false
            }
        }
    }

    private func discardInFlightOutput() {
        if let path = inFlightOutput { try? FileManager.default.removeItem(atPath: path) }
        inFlightOutput = nil
    }

    private func finishedClipsNote() -> String {
        let done = outputPaths.count
        guard done > 0 else { return "Export cancelled" }
        return "Cancelled — kept \(done) finished clip\(done == 1 ? "" : "s")"
    }

    private func run(_ arguments: [String], onProgress: @escaping (Double) -> Void) async throws {
        let runner = ProgressRunner()
        currentRunner = runner
        try await runner.run(arguments: arguments, onProgress: onProgress)
    }

    private func runPipeline(inputPath: String, duration: Double, ranges: [(Double, Double)],
                            mode: MarkMode, splitOutputs: Bool, targetHeight: Int?) async throws {
        let segments = computeExportSegments(duration: duration, ranges: ranges, mode: mode)
        guard !segments.isEmpty else {
            throw RunError.failed(mode == .keep
                ? "Nothing is marked to keep — mark at least one stretch to export."
                : "The whole video would be removed — nothing left to export.")
        }
        let exportTotal = segments.reduce(0.0) { $0 + ($1.1 - $1.0) }

        let sourceBitrate = await probeVideoBitrateKbps(path: inputPath) ?? 3000
        let sourceHeight = (await probeResolution(path: inputPath))?.1 ?? 1080

        // Scaling happens while the segments are cut, so downscaled exports stay a single pass.
        var scaleArgs: [String] = []
        var outBitrate = sourceBitrate
        var resTag = ""
        if let targetHeight, targetHeight < sourceHeight {
            let ratio = Double(targetHeight) / Double(sourceHeight)
            outBitrate = max(Int(Double(sourceBitrate) * ratio * ratio), 600)
            scaleArgs = ["-vf", "scale=-2:\(targetHeight)"]
            resTag = " [\(targetHeight)p]"
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let dir = inputURL.deletingLastPathComponent()
        let base = inputURL.deletingPathExtension().lastPathComponent

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Claimed up front so a split batch shares one version suffix, and so the joined export
        // knows its final name before any encoding starts.
        let destinations = availableOutputPaths(in: dir, baseNames: splitOutputs
            ? (1...segments.count).map { "\(base) (part \($0))\(resTag)" }
            : ["\(base) (trimmed)\(resTag)"])

        var cumulative: Double = 0
        var segPaths: [String] = []

        for (i, seg) in segments.enumerated() {
            // A split export encodes straight to its final file; a joined one cuts to temp first
            // so the concat demuxer has something to stitch.
            let segPath: String
            if splitOutputs {
                segPath = destinations[i]
                inFlightOutput = segPath
                stageText = "Exporting clip \(i + 1) of \(segments.count)..."
            } else {
                segPath = tempDir.appendingPathComponent("seg\(i).mp4").path
                stageText = "Cutting segment \(i + 1) of \(segments.count)..."
            }
            segPaths.append(segPath)
            let segStart = cumulative
            let segLen = seg.1 - seg.0

            var args = ["-y", "-ss", "\(seg.0)", "-to", "\(seg.1)", "-i", inputPath]
            args += scaleArgs
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(outBitrate)k",
                     "-c:a", "aac", "-b:a", "128k",
                     "-progress", "pipe:1", "-nostats", segPath]

            try await run(args) { [weak self] elapsed in
                guard let self else { return }
                let overall = (segStart + min(elapsed, segLen)) / exportTotal
                Task { @MainActor in self.setProgress(overall) }
            }
            inFlightOutput = nil
            // Published as each clip lands, so a cancelled split still points at what it produced.
            if splitOutputs { outputPaths.append(segPath) }
            cumulative += segLen
        }

        if !splitOutputs {
            stageText = "Merging selected parts..."
            let outputPath = destinations[0]
            inFlightOutput = outputPath

            let listPath = tempDir.appendingPathComponent("list.txt").path
            let listContent = segPaths.map { "file '\($0)'" }.joined(separator: "\n")
            try listContent.write(toFile: listPath, atomically: true, encoding: .utf8)

            try await run(
                ["-y", "-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", outputPath]
            ) { _ in }
            inFlightOutput = nil
            outputPaths = [outputPath]
        }

        setProgress(1.0)
        etaText = "0:00"
        if let startDate {
            elapsedText = formatSeconds(Date().timeIntervalSince(startDate))
        }
        titleText = "Done!"
        stageText = outputPaths.count == 1
            ? "Export complete"
            : "Exported \(outputPaths.count) clips"
        isRunning = false
    }
}
