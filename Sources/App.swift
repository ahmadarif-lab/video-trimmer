import SwiftUI
import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// Shared so both the Help menu command and the header button open the same sheet.
@MainActor
final class ShortcutsPresenter: ObservableObject {
    static let shared = ShortcutsPresenter()
    @Published var isPresented = false
}

struct ResolutionOption: Identifiable {
    var id: Int { height ?? -1 }
    let height: Int?
    let title: String
    let detail: String
}

@MainActor
struct ContentView: View {
    @StateObject private var engine = TrimEngine()
    @StateObject private var playerModel = PlayerModel()
    @StateObject private var brew = BrewManager()
    @StateObject private var updater = Updater()
    @StateObject private var input = InputMonitor()
    @ObservedObject private var shortcuts = ShortcutsPresenter.shared

    @State private var inputPath: String = ""
    @State private var duration: Double = 0
    @State private var ranges: [CutRange] = []
    @State private var selectedRangeID: UUID? = nil
    @State private var thumbnails: [NSImage] = []
    @State private var zoomScale: CGFloat = 1.0
    @State private var sourceBitrateKbps: Int? = nil
    @State private var resolution: (Int, Int)? = nil
    @State private var fileSize: Int64 = 0
    @State private var showAddPopover = false
    @State private var showSettings = false
    @State private var showExportSheet = false
    @State private var showProgressOverlay = false
    @State private var selectedHeight: Int? = nil
    @State private var markMode: MarkMode = .remove
    @State private var splitOutputs = false
    @State private var addStartText = ""
    @State private var addEndText = ""
    @State private var addError: String?
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 8) {
                header
                HStack(alignment: .top, spacing: 8) {
                    playerPanel
                    rightSidebar
                }
                .frame(maxHeight: .infinity)
                timelinePanel
            }
            .padding(10)

            if isDropTargeted { dropOverlay }
            if showProgressOverlay { progressOverlay }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 780)
        .sheet(isPresented: $showExportSheet) { exportSheet }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            input.onTogglePlay = { playerModel.togglePlay() }
            input.onSeekBy = { delta in
                guard duration > 0 else { return }
                playerModel.seek(to: min(max(playerModel.currentTime + delta, 0), duration))
            }
            input.onZoom = { delta in
                zoomScale = min(max(zoomScale * (1 + delta * 0.06), 1), 8)
            }
            input.start()
        }
        .onDisappear { input.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            Text("Video Trimmer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Button(action: { shortcuts.isPresented.toggle() }) {
                Image(systemName: "questionmark")
            }
            .buttonStyle(IconButtonStyle())
            .popover(isPresented: $shortcuts.isPresented) { shortcutsPopover }
            .help("Keyboard shortcuts (⌘/)")

            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .overlay(alignment: .topTrailing) {
                // A newer release is out; the dot stays until the app relaunches into it.
                if updater.availableUpdate != nil {
                    Circle()
                        .fill(Theme.accent)
                        .overlay(Circle().stroke(Theme.panel, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: $showSettings) { settingsPopover }
            .help(updater.availableUpdate.map { "Video Trimmer v\($0.version) is available" } ?? "Updates and ffmpeg")

            Button(action: pickFile) {
                Label("Open Video", systemImage: "folder")
            }
            .buttonStyle(ToolbarButtonStyle())

            Button(action: openExportSheet) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ToolbarButtonStyle(prominent: canExport))
            .disabled(!canExport)
            .opacity(canExport ? 1 : 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.panelRadius)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).stroke(Theme.border, lineWidth: 1))
        )
    }

    // MARK: - Player

    private var playerPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if playerModel.player != nil {
                    PlayerSurface(player: playerModel.player)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.system(size: 34)).foregroundColor(Theme.textSecondary)
                        Text("Open a video, or drop one here")
                            .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            playerControls
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).stroke(Theme.border, lineWidth: 1))
    }

    private var playerControls: some View {
        HStack(spacing: 12) {
            Button(action: { playerModel.togglePlay() }) {
                Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Play/Pause (Space)")

            Text("\(formatClock(playerModel.currentTime)) / \(formatClock(duration))")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundColor(Theme.textSecondary)

            Slider(value: Binding(
                get: { playerModel.currentTime },
                set: { playerModel.seek(to: $0) }
            ), in: 0...(max(duration, 0.01)))
            .controlSize(.mini)

            Button(action: { playerModel.toggleMute() }) {
                Image(systemName: playerModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }.buttonStyle(.plain)

            Button(action: { NSApp.keyWindow?.toggleFullScreen(nil) }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    // MARK: - Right sidebar

    private var rightSidebar: some View {
        VStack(spacing: 8) {
            videoInfoPanel
            segmentsPanel
        }
        .frame(width: 290)
    }

    private var videoInfoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video Info")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)

            if inputPath.isEmpty {
                Text("No video selected")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            } else {
                Text((inputPath as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    infoChip(text: resolution.map { "\($0.0)×\($0.1)" } ?? "—")
                    infoChip(text: formatClock(duration))
                    infoChip(text: fileSize > 0 ? formatFileSize(fileSize) : "—")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func infoChip(text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panelRaised))
    }

    private var segmentsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(markMode.panelTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text("\(ranges.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.panelRaised))
            }

            // The marks stay put when the mode flips — only what they mean changes.
            Picker("", selection: $markMode) {
                Text("Remove Marked").tag(MarkMode.remove)
                Text("Keep Marked").tag(MarkMode.keep)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if ranges.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 20)).foregroundColor(Theme.textSecondary.opacity(0.6))
                    Text(markMode.emptyHint)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sortedRanges) { range in
                            SegmentCard(
                                index: (sortedRanges.firstIndex(where: { $0.id == range.id }) ?? 0) + 1,
                                range: range,
                                thumbnail: thumbnailNear(range.start),
                                isSelected: selectedRangeID == range.id,
                                tint: markTint,
                                onSelect: {
                                    selectedRangeID = range.id
                                    playerModel.seek(to: range.start)
                                },
                                onDelete: { deleteRange(range.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Button(action: openAddPopover) {
                Label("Add Manually", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ToolbarButtonStyle())
            .popover(isPresented: $showAddPopover) { addSegmentPopover }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .panel()
    }

    // MARK: - Timeline

    private var timelinePanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Timeline")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle(disabled: selectedRangeID == nil))
                .disabled(selectedRangeID == nil)
                .help("Delete selected segment")

                Button(action: { zoomScale = max(zoomScale / 1.5, 1) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .help("Zoom out — pinch or ⌘-scroll on the timeline")

                Text("\(Int(zoomScale * 100))%")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 38)

                Button(action: { zoomScale = min(zoomScale * 1.5, 8) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .help("Zoom in — pinch or ⌘-scroll on the timeline")

                Button(action: { zoomScale = 1 }) {
                    Image(systemName: "arrow.left.and.right")
                }
                .buttonStyle(IconButtonStyle())
                .help("Fit to screen")
            }

            TimelineView(playerModel: playerModel, ranges: $ranges, selectedRangeID: $selectedRangeID,
                         duration: duration, thumbnails: thumbnails, tint: markTint, zoomScale: $zoomScale)
                .frame(height: 81)
        }
        .panel()
    }

    // MARK: - Popovers & sheets

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            appUpdateSection

            Divider().padding(.vertical, 2)

            Text("FFmpeg").font(.system(size: 12, weight: .semibold))

            if !brew.brewAvailable {
                Text("Homebrew wasn't found, so ffmpeg can't be managed from here. Install Homebrew first, then reopen this panel.")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if brew.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(brew.busyLabel).font(.system(size: 11))
                }
                ScrollView {
                    Text(brew.logText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
            } else if !brew.ffmpegInstalled {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("ffmpeg is not installed").font(.system(size: 11))
                }
                Button("Install ffmpeg") { Task { await brew.install() } }
                    .buttonStyle(ToolbarButtonStyle(prominent: true))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
                    Text("Installed — \(brew.ffmpegVersion ?? "unknown")").font(.system(size: 11))
                }
                if brew.isOutdated == true {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.orange)
                        Text("An update is available").font(.system(size: 11))
                    }
                    Button("Update ffmpeg") { Task { await brew.update() } }
                        .buttonStyle(ToolbarButtonStyle(prominent: true))
                } else {
                    Button("Check for Updates") { Task { await brew.checkForUpdate() } }
                        .buttonStyle(ToolbarButtonStyle())
                }
            }

            if let err = brew.errorMessage {
                Text(err).font(.system(size: 10)).foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ahmad Arif · ahmad.arif019@gmail.com")
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                Link("github.com/ahmadarif-lab/video-trimmer",
                     destination: URL(string: "https://github.com/ahmadarif-lab/video-trimmer")!)
                    .font(.system(size: 10))
                Text("Free to use — if it helps you, please pray that Allah grants me and my family Paradise.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 290)
        .task { await brew.refreshStatus() }
    }

    /// The app's own version and updates: status at the trailing edge of the title row, the action
    /// below it.
    @ViewBuilder
    private var appUpdateSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Video Trimmer").font(.system(size: 12, weight: .semibold))
            Text("v\(Updater.currentVersion)")
                .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            Spacer()
            if let status = updateStatus {
                Text(status.text).font(.system(size: 10)).foregroundColor(status.tint)
            }
        }

        if updater.installedVersion != nil {
            Button("Relaunch to Finish") { updater.relaunch() }
                .buttonStyle(ToolbarButtonStyle(prominent: true))
        } else if let release = updater.availableUpdate {
            HStack(spacing: 10) {
                Button(updater.installsWithHomebrew ? "Install Update" : "Download Update") {
                    Task { await updater.update() }
                }
                .buttonStyle(ToolbarButtonStyle(prominent: true))
                .disabled(updater.isUpdating)
                .opacity(updater.isUpdating ? 0.5 : 1)

                if updater.isUpdating {
                    ProgressView().controlSize(.small)
                } else {
                    Link("What's new", destination: release.pageURL).font(.system(size: 11))
                }
            }
        } else {
            Button("Check for Updates") { Task { await updater.check() } }
                .buttonStyle(ToolbarButtonStyle(disabled: updater.isChecking))
                .disabled(updater.isChecking)
        }

        if let err = updater.errorMessage {
            Text(err).font(.system(size: 10)).foregroundColor(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updateStatus: (text: String, tint: Color)? {
        if let step = updater.progressText { return (step, Theme.textSecondary) }
        if let installed = updater.installedVersion { return ("v\(installed) installed", Theme.success) }
        if let release = updater.availableUpdate { return ("v\(release.version) available", Theme.accent) }
        if updater.isChecking { return ("Checking...", Theme.textSecondary) }
        if updater.checkFailed { return ("Couldn't check", Theme.textSecondary) }
        return updater.lastChecked == nil ? nil : ("Up to date", Theme.textSecondary)
    }

    private var addSegmentPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Segment").font(.system(size: 12, weight: .semibold))
            HStack {
                Text("Start").font(.system(size: 11)).frame(width: 36, alignment: .leading)
                TextField("mm:ss", text: $addStartText).frame(width: 84)
                    .onChange(of: addStartText) { _, newValue in
                        let sanitized = sanitizeTimeInput(newValue)
                        if sanitized != newValue { addStartText = sanitized }
                    }
            }
            HStack {
                Text("End").font(.system(size: 11)).frame(width: 36, alignment: .leading)
                TextField("mm:ss", text: $addEndText).frame(width: 84)
                    .onChange(of: addEndText) { _, newValue in
                        let sanitized = sanitizeTimeInput(newValue)
                        if sanitized != newValue { addEndText = sanitized }
                    }
            }
            if let addError {
                Text(addError).foregroundColor(Theme.danger).font(.system(size: 10))
            }
            HStack {
                Spacer()
                Button("Cancel") { showAddPopover = false }
                Button("Add") { confirmAddSegment() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 210)
    }

    private var shortcutsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts").font(.system(size: 12, weight: .semibold))

            shortcutSection("Playback", [
                ("Space", "Play / pause"),
                ("←  →", "Seek 10 seconds")
            ])

            Divider().padding(.vertical, 2)

            shortcutSection("Timeline", [
                ("Drag", markMode.dragHint),
                ("Drag edges", "Resize a segment"),
                ("Pinch", "Zoom in / out"),
                ("⌘ scroll", "Zoom in / out"),
                ("Scroll", "Pan when zoomed in")
            ])
        }
        .padding(12)
        .frame(width: 290)
    }

    private func shortcutSection(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ForEach(rows, id: \.0) { keys, action in
                HStack(spacing: 10) {
                    Text(keys)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.control))
                        .frame(width: 82, alignment: .center)
                    Text(action)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                }
            }
        }
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Export Video").font(.system(size: 15, weight: .semibold))
                Text(exportSummary)
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }

            VStack(spacing: 6) {
                ForEach(resolutionOptions) { option in
                    Button {
                        selectedHeight = option.height
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedHeight == option.height ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(selectedHeight == option.height ? Theme.accent : Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.title).font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(option.detail).font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            Text(estimatedSize(forHeight: option.height))
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedHeight == option.height ? Theme.accent.opacity(0.14) : Theme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(selectedHeight == option.height ? Theme.accent : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle(isOn: $splitOutputs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Split into separate files")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary)
                    Text(splitDetail)
                        .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panelRaised))

            HStack {
                Spacer()
                Button("Cancel") { showExportSheet = false }
                Button("Start Export") { startExport() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    // MARK: - Overlays

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 32)).foregroundColor(Theme.accent)
                Text("Drop video to open").font(.system(size: 14, weight: .semibold))
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
            )
        }
        .allowsHitTesting(false)
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.control, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: engine.progress)
                        .stroke(progressTint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if exportSucceeded {
                        Image(systemName: "checkmark")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(Theme.success)
                    } else {
                        Text("\(Int(engine.progress * 100))%")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                    }
                }
                .frame(width: 86, height: 86)

                VStack(spacing: 4) {
                    Text(engine.titleText).font(.system(size: 14, weight: .semibold))
                    Text(engine.stageText).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    if engine.isRunning {
                        Text("ETA \(engine.etaText)").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    } else if !engine.elapsedText.isEmpty {
                        Text("Took \(engine.elapsedText)").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    }
                }

                if let err = engine.errorMessage {
                    Text(err)
                        .font(.system(size: 10)).foregroundColor(Theme.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                }

                if engine.isRunning {
                    Button("Cancel") { engine.cancel() }
                        .buttonStyle(ToolbarButtonStyle())
                } else {
                    HStack(spacing: 8) {
                        if !engine.outputPaths.isEmpty {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    engine.outputPaths.map { URL(fileURLWithPath: $0) }
                                )
                            }
                            .buttonStyle(ToolbarButtonStyle())
                        }
                        Button("Done") { showProgressOverlay = false }
                            .buttonStyle(ToolbarButtonStyle(prominent: true))
                    }
                }
            }
            .padding(28)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        }
    }

    // MARK: - Computed helpers

    private var sortedRanges: [CutRange] {
        ranges.sorted { $0.start < $1.start }
    }

    private var exportSucceeded: Bool {
        !engine.isRunning && engine.errorMessage == nil && !engine.wasCancelled && !engine.outputPaths.isEmpty
    }

    private var progressTint: Color {
        if exportSucceeded { return Theme.success }
        return engine.errorMessage == nil ? Theme.accent : Theme.danger
    }

    private var canExport: Bool {
        !inputPath.isEmpty && !engine.isRunning && !ranges.isEmpty && duration > 0
    }

    private var markTint: Color {
        markMode == .remove ? Theme.danger : Theme.success
    }

    /// The stretches the current marks would export — one file each when split is on.
    private var exportSegments: [(Double, Double)] {
        guard duration > 0 else { return [] }
        return computeExportSegments(duration: duration, ranges: ranges.map { ($0.start, $0.end) }, mode: markMode)
    }

    private var exportTotalEstimate: Double {
        exportSegments.reduce(0) { $0 + ($1.1 - $1.0) }
    }

    private var exportSummary: String {
        let time = formatClock(exportTotalEstimate)
        let marks = "\(ranges.count) segment\(ranges.count == 1 ? "" : "s")"
        let base = markMode == .remove
            ? "\(time) after removing \(marks)"
            : "\(time) from \(marks) marked"
        guard splitOutputs else { return base }
        let n = exportSegments.count
        return "\(base) · \(n) file\(n == 1 ? "" : "s")"
    }

    private var resolutionOptions: [ResolutionOption] {
        let sourceHeight = resolution?.1 ?? 1080
        let sourceWidth = resolution?.0 ?? 1920
        var options: [ResolutionOption] = [
            ResolutionOption(height: nil, title: "Original", detail: "\(sourceWidth)×\(sourceHeight)")
        ]
        for h in [1080, 720, 480] where h < sourceHeight {
            let w = Int((Double(sourceWidth) / Double(sourceHeight) * Double(h) / 2).rounded()) * 2
            options.append(ResolutionOption(height: h, title: "\(h)p", detail: "\(w)×\(h)"))
        }
        return options
    }

    private func estimatedBitrateKbps(forHeight height: Int?) -> Double {
        guard let source = sourceBitrateKbps else { return 0 }
        guard let height, let sourceHeight = resolution?.1, height < sourceHeight else {
            return Double(source)
        }
        let ratio = Double(height) / Double(sourceHeight)
        return max(Double(source) * ratio * ratio, 600)
    }

    private func estimatedSize(forHeight height: Int?) -> String {
        let video = estimatedBitrateKbps(forHeight: height)
        guard video > 0 else { return "—" }
        let mb = exportTotalEstimate * (video + 128) * 1000 / 8 / 1_048_576
        return "~\(Int(mb)) MB"
    }

    private var splitDetail: String {
        let n = exportSegments.count
        let source = markMode == .remove ? "unmarked" : "marked"
        return splitOutputs
            ? "\(n) file\(n == 1 ? "" : "s") — one per \(source) segment"
            : "Everything is joined into one file"
    }

    private func thumbnailNear(_ time: Double) -> NSImage? {
        guard duration > 0, !thumbnails.isEmpty else { return nil }
        let idx = min(thumbnails.count - 1, max(0, Int((time / duration) * Double(thumbnails.count))))
        return thumbnails[idx]
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard let id = selectedRangeID else { return }
        ranges.removeAll { $0.id == id }
        selectedRangeID = nil
    }

    private func deleteRange(_ id: UUID) {
        ranges.removeAll { $0.id == id }
        if selectedRangeID == id { selectedRangeID = nil }
    }

    private func openAddPopover() {
        let start = playerModel.currentTime
        let end = min(start + 10, duration)
        addStartText = formatClock(start)
        addEndText = formatClock(end)
        addError = nil
        showAddPopover = true
    }

    private func confirmAddSegment() {
        guard let s = try? parseTimeToSeconds(addStartText),
              let e = try? parseTimeToSeconds(addEndText) else {
            addError = "Enter both start and end."
            return
        }
        let clampedEnd = min(e, duration)
        guard clampedEnd > s, s >= 0 else {
            addError = "End must be after start."
            return
        }
        addError = nil
        let new = CutRange(start: s, end: clampedEnd)
        ranges.append(new)
        selectedRangeID = new.id
        showAddPopover = false
    }

    private func openExportSheet() {
        guard canExport else { return }
        if selectedHeight != nil, !resolutionOptions.contains(where: { $0.height == selectedHeight }) {
            selectedHeight = nil
        }
        showExportSheet = true
    }

    private func startExport() {
        showExportSheet = false
        guard canExport else { return }
        showProgressOverlay = true
        engine.start(inputPath: inputPath, duration: duration,
                     ranges: ranges.map { ($0.start, $0.end) },
                     mode: markMode, splitOutputs: splitOutputs, targetHeight: selectedHeight)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url: url)
    }

    private func loadVideo(url: URL) {
        inputPath = url.path
        duration = 0
        ranges = []
        selectedRangeID = nil
        thumbnails = []
        sourceBitrateKbps = nil
        resolution = nil
        selectedHeight = nil
        engine.outputPaths = []
        engine.errorMessage = nil

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        playerModel.load(url: url)

        Task {
            if let d = await probeDuration(path: url.path) {
                duration = d
                let thumbs = await generateThumbnails(url: url, duration: d, count: 32)
                thumbnails = thumbs
            }
        }
        Task { sourceBitrateKbps = await probeVideoBitrateKbps(path: url.path) }
        Task { resolution = await probeResolution(path: url.path) }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { return }
            Task { @MainActor in
                loadVideo(url: url)
            }
        }
        return true
    }
}

@main
struct VideoTrimmerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Video Trimmer Shortcuts") {
                    ShortcutsPresenter.shared.isPresented = true
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}
