import AppKit

/// App-level keyboard/scroll shortcuts that shouldn't depend on SwiftUI focus state:
/// Space toggles playback, and Command/Option + scroll zooms the timeline.
@MainActor
final class InputMonitor: ObservableObject {
    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    var onTogglePlay: (() -> Void)?
    var onSeekBy: ((Double) -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    private enum Key {
        static let space: UInt16 = 49
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }

    func start() {
        guard keyMonitor == nil, scrollMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard [Key.space, Key.leftArrow, Key.rightArrow].contains(event.keyCode) else { return event }
                // Only the real modifier keys matter here: arrow keys always carry
                // .function and .numericPad, so checking the whole flag set never matches.
                let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
                guard event.modifierFlags.intersection(modifiers).isEmpty else { return event }
                // Never swallow these keys while the user is typing in a text field.
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }

                switch event.keyCode {
                case Key.space: self.onTogglePlay?()
                case Key.leftArrow: self.onSeekBy?(-10)
                default: self.onSeekBy?(10)
                }
                return nil
            }
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.command) || flags.contains(.option) else { return event }
                let raw = event.scrollingDeltaY
                guard raw != 0 else { return event }
                let delta = event.hasPreciseScrollingDeltas ? raw / 60 : raw / 4
                self.onZoom?(delta)
                return nil
            }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }
}
