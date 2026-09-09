import Foundation

struct CutRange: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
}

enum TimeParseError: Error {
    case invalid(String)
}

/// Keeps only digits and up to two colons, enforcing number:number or number:number:number as the user types.
func sanitizeTimeInput(_ text: String) -> String {
    var result = ""
    var colonCount = 0
    for ch in text {
        if ch.isNumber {
            result.append(ch)
        } else if ch == ":" && colonCount < 2 {
            result.append(ch)
            colonCount += 1
        }
    }
    return result
}

func parseTimeToSeconds(_ text: String) throws -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw TimeParseError.invalid(text) }
    let parts = trimmed.split(separator: ":").map(String.init)
    guard parts.count >= 1 && parts.count <= 3 else { throw TimeParseError.invalid(text) }
    var seconds: Double = 0
    for (i, part) in parts.reversed().enumerated() {
        guard let value = Double(part) else { throw TimeParseError.invalid(text) }
        switch i {
        case 0: seconds += value
        case 1: seconds += value * 60
        case 2: seconds += value * 3600
        default: throw TimeParseError.invalid(text)
        }
    }
    return seconds
}

/// e.g. "4:21" or "1:03:46" (no leading zero on the leading unit)
func formatSeconds(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}

/// e.g. "00:00" or "1:23:45" — zero-padded, used for ruler labels & player time
func formatClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%02d:%02d", m, s)
    }
}

/// e.g. "00:05:12" — always zero-padded HH:MM:SS, used on segment cards
func formatHMS(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}

func formatFileSize(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB", mb)
}

/// What the marked ranges mean: the stretches to drop, or the only stretches to keep.
enum MarkMode: String, CaseIterable, Identifiable {
    case remove
    case keep

    var id: String { rawValue }
    var title: String { self == .remove ? "Remove" : "Keep" }
    var panelTitle: String { self == .remove ? "Segments to Remove" : "Segments to Keep" }
    var emptyHint: String {
        self == .remove
            ? "Drag across the timeline to mark a part to remove."
            : "Drag across the timeline to mark a part to keep."
    }
    var dragHint: String {
        self == .remove ? "Mark a stretch to remove" : "Mark a stretch to keep"
    }
}

/// Clamps ranges to the video, drops empty ones, sorts them, and merges the ones that collide.
/// `mergeTouching` also folds ranges that only meet at a point — right when cutting (removing
/// 0–10 and 10–20 is a single cut), wrong when keeping, where those are two deliberate clips.
func normalizeRanges(duration: Double, ranges: [(Double, Double)], mergeTouching: Bool) -> [(Double, Double)] {
    let clamped = ranges
        .map { (max(0, min($0.0, duration)), max(0, min($0.1, duration))) }
        .filter { $0.1 > $0.0 }
        .sorted { $0.0 < $1.0 }

    var merged: [(Double, Double)] = []
    for r in clamped {
        if let last = merged.last, mergeTouching ? r.0 <= last.1 : r.0 < last.1 {
            merged[merged.count - 1] = (last.0, max(last.1, r.1))
        } else {
            merged.append(r)
        }
    }
    return merged
}

/// The complement of the marked ranges — everything the user did *not* mark for removal.
func computeKeepSegments(duration: Double, cutRanges: [(Double, Double)]) -> [(Double, Double)] {
    let merged = normalizeRanges(duration: duration, ranges: cutRanges, mergeTouching: true)
    var keep: [(Double, Double)] = []
    var cursor: Double = 0
    for r in merged {
        if r.0 > cursor { keep.append((cursor, r.0)) }
        cursor = max(cursor, r.1)
    }
    if cursor < duration { keep.append((cursor, duration)) }
    return keep
}

/// The stretches that actually end up in the export, in play order: one file each when the
/// export is split, otherwise concatenated into a single file.
func computeExportSegments(duration: Double, ranges: [(Double, Double)], mode: MarkMode) -> [(Double, Double)] {
    switch mode {
    case .remove: return computeKeepSegments(duration: duration, cutRanges: ranges)
    case .keep: return normalizeRanges(duration: duration, ranges: ranges, mergeTouching: false)
    }
}
