# Context for AI assistants

Working notes for this repository: what it is, how it fits together, and the decisions that are not
obvious from reading the code.

## Project

Video Trimmer — a native macOS (SwiftUI, Apple Silicon) app that removes marked stretches from a
video and exports the remainder. `ffmpeg` does the actual work; the app is the editor around it.

- Developer: Ahmad Arif — ahmad.arif019@gmail.com
- Repository: https://github.com/ahmadarif-lab/video-trimmer
- License: MIT

## Layout

```
Sources/
  App.swift            Main view: layout, export sheet, progress overlay, actions
  Theme.swift          Dark palette and panel styling
  Components.swift     Timeline, segment overlays, segment cards, button styles
  Engine.swift         ffmpeg/ffprobe process handling and the export pipeline
  Models.swift         Cut ranges, time parsing/formatting, keep-segment maths
  PlayerModel.swift    AVPlayer wrapper: playback, seeking, current time
  PlayerSurface.swift  AVPlayerLayer bridged into SwiftUI (no built-in chrome)
  Thumbnails.swift     Filmstrip thumbnail generation
  BrewManager.swift    ffmpeg install/update status via Homebrew
  InputMonitor.swift   App-level keyboard and scroll shortcuts
Resources/
  Info.plist           Bundle metadata
  AppIcon.icns         App icon, generated from AppIcon.png
  AppIcon.png          1024px icon source, kept so the icns can be regenerated
build.sh               Compile, bundle, ad-hoc sign
package-dmg.sh         Build into dist/ and wrap in a DMG
```

## Build system

There is no Xcode project and no Package.swift — `build.sh` calls `swiftc` directly and assembles
the bundle by hand. Notes:

- `-parse-as-library` is required because the entry point is `@main struct VideoTrimmerApp` in
  `App.swift` rather than top-level code in a `main.swift`.
- Source file order in the compile command does not matter, but all files must be listed.
- The bundle is ad-hoc signed (`codesign --sign -`). Good enough to run locally; not notarized, so a
  downloaded copy trips Gatekeeper.
- The `.app` filename carries the space (`Video Trimmer.app`). The Dock and Finder label an app by
  its **bundle filename**, not `CFBundleName` or `CFBundleDisplayName`, which is why the earlier
  `VideoTrimmer.app` showed up unspaced.

## How the export pipeline works

`TrimEngine.runPipeline` converts the ranges the user marked for removal into their complement (the
stretches to keep) and then:

1. Cuts each kept stretch to its own temp file with `-ss`/`-to`, encoding with
   `h264_videotoolbox`. If a smaller resolution was chosen, `scale=-2:<height>` is applied **here**,
   which keeps a downscaled export to a single pass.
2. Concatenates the temp files through the concat demuxer with `-c copy`, so the join is a remux
   rather than a re-encode and takes about a second.

**Do not replace this with a single `filter_complex` doing `trim` + `concat`.** That was the
original implementation and it silently produced files whose audio track stopped early — video ran
the full length, audio ended at the second segment boundary — while ffmpeg reported success and
logged no warning. Cutting segments as separate processes sidesteps it entirely.

Progress comes from `-progress pipe:1 -nostats`, parsing the `out_time=` lines and scaling them
against the total kept duration.

## Gotchas worth remembering

- **Drag gestures need an absolute coordinate space.** Timeline segments are dragged and resized
  using `DragGesture(coordinateSpace: .named("timeline"))` and `value.location`, never
  `value.translation`. The dragged view moves as it resizes, so a translation measured in its own
  local space drifts away from the cursor. The offset between cursor and the grabbed edge is
  captured once per gesture so the edge tracks the cursor without jumping.
- **Drag updates stay local until release.** `TimelineSegmentOverlay` writes to its own
  `liveStart`/`liveEnd` state during a drag and only calls `onUpdate` in `onEnded`. Mutating the
  shared `ranges` array on every frame re-rendered the whole timeline (thumbnails, ruler, every
  overlay) and made fast drags visibly lag.
- **Seeking uses a tolerance.** `PlayerModel.seek` passes a ~0.12s tolerance. Zero-tolerance seeks
  are frame-exact but far too slow to fire on every pixel of a scrub.
- **Arrow keys carry modifier flags.** macOS sets `.function` and `.numericPad` on arrow key events,
  so a guard requiring the whole modifier set to be empty never matches. `InputMonitor` checks only
  `.command`, `.shift`, `.option`, `.control`.
- **Shortcuts go through `NSEvent.addLocalMonitorForEvents`,** not SwiftUI focus, so they work no
  matter which control holds focus. The handler passes the event through when an `NSTextView` is
  first responder, so typing in the manual-segment fields is unaffected.
- **The settings panel must refresh its own state.** `refreshStatus()` runs from a `.task` on the
  popover. Without it the ffmpeg status stays at its initial `false` and misreports an installed
  ffmpeg as missing.
- **ffmpeg and ffprobe paths are hardcoded** to `/opt/homebrew/bin`. Intel Macs would need
  `/usr/local/bin` handling; `BrewManager` already probes both locations for `brew` itself.

## Icon

`Resources/AppIcon.png` is the 1024px source; `AppIcon.icns` is generated from it with `sips` and
`iconutil`. The artwork was reframed so the coloured content fills the icon body — in the original
render the coloured part covered only ~72% of the canvas with the rest a near-white plate, which
read as a small icon in the Dock. The body follows the macOS convention: 824px artwork centred in a
1024px canvas, corner radius 185px.
