import SwiftUI
import AppKit

struct ToolbarButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var disabled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(prominent ? Theme.accent : Theme.control)
            )
            .foregroundColor(disabled ? Theme.textSecondary.opacity(0.5) : (prominent ? .white : Theme.textPrimary))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    var disabled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.control)
            )
            .foregroundColor(disabled ? Theme.textSecondary.opacity(0.5) : Theme.textPrimary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct SegmentCard: View {
    let index: Int
    let range: CutRange
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.danger).frame(width: 18, height: 18)
                Text("\(index)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
            }
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.control)
                }
            }
            .frame(width: 46, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(formatHMS(range.start)) – \(formatHMS(range.end))")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(formatSeconds(range.end - range.start))
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 2)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Theme.danger)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.danger.opacity(0.20) : Theme.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

struct TimelineSegmentOverlay: View {
    let range: CutRange
    let duration: Double
    /// Earliest time this segment may occupy (end of the previous segment, or 0).
    let minBound: Double
    /// Latest time this segment may occupy (start of the next segment, or the full duration).
    let maxBound: Double
    let pixelsPerSecond: CGFloat
    let trackHeight: CGFloat
    let isSelected: Bool
    let coordinateSpace: String
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onUpdate: (Double, Double) -> Void

    // Dragging updates only this local state for a smooth, immediate preview.
    // The parent's `ranges` binding (and the rest of the timeline) is only touched once,
    // in onEnded, so a fast drag never lags behind waiting on a full timeline re-render.
    @State private var liveStart: Double? = nil
    @State private var liveEnd: Double? = nil
    /// Distance (in seconds) between the cursor and the edge being dragged, captured once per
    /// gesture so the edge tracks the cursor exactly instead of jumping to it.
    @State private var grabOffset: Double? = nil

    private var displayStart: Double { liveStart ?? range.start }
    private var displayEnd: Double { liveEnd ?? range.end }

    private var x: CGFloat { CGFloat(displayStart) * pixelsPerSecond }
    private var width: CGFloat { max(20, CGFloat(displayEnd - displayStart) * pixelsPerSecond) }

    private func time(at x: CGFloat) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return max(0, min(Double(x / pixelsPerSecond), duration))
    }

    private func commit() {
        if let s = liveStart, let e = liveEnd, e - s >= 0.3 {
            onUpdate(s, e)
        }
        liveStart = nil
        liveEnd = nil
        grabOffset = nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.danger.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Theme.accent : Theme.danger.opacity(0.7), lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .gesture(moveGesture)

            Button(action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Circle().fill(Theme.danger))
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                handleView.gesture(leftHandleGesture)
                Spacer(minLength: 0)
                handleView.gesture(rightHandleGesture)
            }
        }
        .frame(width: width, height: trackHeight)
        .offset(x: x)
    }

    private var handleView: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.danger)
            .frame(width: 8, height: trackHeight * 0.62)
            .overlay(
                Rectangle().fill(Color.white.opacity(0.8)).frame(width: 2, height: trackHeight * 0.28)
            )
    }

    // All three gestures read the cursor's absolute position in the timeline's coordinate space
    // rather than a relative translation: the dragged view moves as it resizes, so a translation
    // measured in its own (moving) local space drifts away from the cursor.

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard pixelsPerSecond > 0 else { return }
                let len = range.end - range.start
                if grabOffset == nil {
                    grabOffset = time(at: value.startLocation.x) - range.start
                }
                let offset = grabOffset ?? len / 2
                let upperStart = max(minBound, min(maxBound - len, duration - len))
                let newStart = max(minBound, min(time(at: value.location.x) - offset, upperStart))
                liveStart = newStart
                liveEnd = newStart + len
            }
            .onEnded { _ in commit() }
    }

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard pixelsPerSecond > 0 else { return }
                if grabOffset == nil {
                    grabOffset = time(at: value.startLocation.x) - range.start
                }
                let offset = grabOffset ?? 0
                let newStart = max(minBound, min(time(at: value.location.x) - offset, range.end - 0.5))
                liveStart = newStart
                liveEnd = range.end
            }
            .onEnded { _ in commit() }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard pixelsPerSecond > 0 else { return }
                if grabOffset == nil {
                    grabOffset = time(at: value.startLocation.x) - range.end
                }
                let offset = grabOffset ?? 0
                let newEnd = min(maxBound, max(time(at: value.location.x) - offset, range.start + 0.5))
                liveStart = range.start
                liveEnd = newEnd
            }
            .onEnded { _ in commit() }
    }
}

struct TimelineView: View {
    @ObservedObject var playerModel: PlayerModel
    @Binding var ranges: [CutRange]
    @Binding var selectedRangeID: UUID?
    let duration: Double
    let thumbnails: [NSImage]
    @Binding var zoomScale: CGFloat

    @State private var dragSelectStart: Double? = nil
    @State private var dragSelectCurrent: Double? = nil
    @State private var zoomBase: CGFloat? = nil

    private let timelineSpace = "timeline"
    private let rulerHeight: CGFloat = 16
    private let filmstripHeight: CGFloat = 62
    private let topPadding: CGFloat = 3

    var body: some View {
        GeometryReader { outerGeo in
            ScrollView(.horizontal, showsIndicators: true) {
                let width = max(outerGeo.size.width, outerGeo.size.width * zoomScale)
                let pxPerSec: CGFloat = duration > 0 ? width / CGFloat(duration) : 0

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: width, height: rulerHeight + topPadding + filmstripHeight)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard pxPerSec > 0 else { return }
                                    if dragSelectStart == nil {
                                        dragSelectStart = max(0, min(Double(value.startLocation.x / pxPerSec), duration))
                                    }
                                    let t = max(0, min(Double(value.location.x / pxPerSec), duration))
                                    dragSelectCurrent = t
                                    playerModel.seek(to: t)
                                }
                                .onEnded { value in
                                    defer {
                                        dragSelectStart = nil
                                        dragSelectCurrent = nil
                                    }
                                    guard abs(value.translation.width) >= 4,
                                          let start = dragSelectStart, let current = dragSelectCurrent else { return }
                                    let gap = freeGap(around: start)
                                    let s = max(min(start, current), gap.0)
                                    let e = min(max(start, current), gap.1)
                                    guard e - s >= 0.3 else { return }
                                    let new = CutRange(start: s, end: e)
                                    ranges.append(new)
                                    selectedRangeID = new.id
                                }
                        )

                    VStack(alignment: .leading, spacing: topPadding) {
                        rulerView(width: width, pxPerSec: pxPerSec)
                        filmstripView(width: width)
                    }

                    if let start = dragSelectStart, let current = dragSelectCurrent, pxPerSec > 0 {
                        let gap = freeGap(around: start)
                        let s = max(min(start, current), gap.0)
                        let e = min(max(start, current), gap.1)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.accent.opacity(0.28))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1.5))
                            .frame(width: max(2, CGFloat(max(e - s, 0)) * pxPerSec), height: filmstripHeight)
                            .offset(x: CGFloat(s) * pxPerSec, y: rulerHeight + topPadding)
                            .allowsHitTesting(false)
                    }

                    ForEach(ranges) { range in
                        let bounds = neighborBounds(for: range)
                        TimelineSegmentOverlay(
                            range: range,
                            duration: duration,
                            minBound: bounds.0,
                            maxBound: bounds.1,
                            pixelsPerSecond: pxPerSec,
                            trackHeight: filmstripHeight,
                            isSelected: selectedRangeID == range.id,
                            coordinateSpace: timelineSpace,
                            onSelect: { selectedRangeID = range.id },
                            onDelete: { deleteRange(range.id) },
                            onUpdate: { newStart, newEnd in updateRange(range.id, newStart, newEnd) }
                        )
                        .offset(y: rulerHeight + topPadding)
                    }

                    if pxPerSec > 0 {
                        let playheadX = CGFloat(playerModel.currentTime) * pxPerSec
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 1.5, height: rulerHeight + topPadding + filmstripHeight)
                            .offset(x: playheadX)
                            .allowsHitTesting(false)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                            .offset(x: playheadX - 3.75, y: -3)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: rulerHeight + topPadding + filmstripHeight, alignment: .topLeading)
                .coordinateSpace(name: timelineSpace)
            }
        }
        .gesture(magnifyGesture)
    }

    /// Trackpad pinch zooms the timeline. `magnification` is cumulative for the whole gesture,
    /// so the zoom level at the start is captured once and scaled from there.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomBase == nil { zoomBase = zoomScale }
                let base = zoomBase ?? zoomScale
                zoomScale = min(max(base * value.magnification, 1), 8)
            }
            .onEnded { _ in zoomBase = nil }
    }

    /// The stretch of empty timeline (between neighbouring segments) that contains `time`.
    private func freeGap(around time: Double) -> (Double, Double) {
        let lower = ranges.filter { $0.end <= time }.map(\.end).max() ?? 0
        let upper = ranges.filter { $0.start >= time }.map(\.start).min() ?? duration
        return (lower, upper)
    }

    /// How far a segment may be moved or resized before it would touch its neighbours.
    private func neighborBounds(for range: CutRange) -> (Double, Double) {
        let others = ranges.filter { $0.id != range.id }
        let lower = others.filter { $0.end <= range.start }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= range.end }.map(\.start).min() ?? duration
        return (lower, upper)
    }

    private func rulerView(width: CGFloat, pxPerSec: CGFloat) -> some View {
        let stepSeconds = niceStep(duration: duration)
        let count = stepSeconds > 0 ? Int(duration / stepSeconds) + 1 : 0
        return ZStack(alignment: .topLeading) {
            ForEach(0..<max(count, 0), id: \.self) { i in
                let t = Double(i) * stepSeconds
                HStack(spacing: 3) {
                    Rectangle().fill(Theme.textSecondary.opacity(0.5)).frame(width: 1, height: 6)
                    Text(formatClock(t))
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textSecondary)
                }
                .offset(x: CGFloat(t) * pxPerSec)
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
    }

    private func filmstripView(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle().fill(Theme.panelRaised)
            } else {
                ForEach(0..<thumbnails.count, id: \.self) { i in
                    Image(nsImage: thumbnails[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbnails.count), height: filmstripHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: filmstripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func niceStep(duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let target = duration / 8
        let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return steps.first(where: { $0 >= target }) ?? 3600
    }

    private func deleteRange(_ id: UUID) {
        ranges.removeAll { $0.id == id }
        if selectedRangeID == id { selectedRangeID = nil }
    }

    private func updateRange(_ id: UUID, _ start: Double, _ end: Double) {
        guard let idx = ranges.firstIndex(where: { $0.id == id }) else { return }
        ranges[idx].start = start
        ranges[idx].end = end
    }
}
