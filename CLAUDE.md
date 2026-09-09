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

`TrimEngine.runPipeline` first turns the marked ranges into the stretches to export, via
`computeExportSegments`. In `.remove` mode that is their complement; in `.keep` mode the marked
ranges *are* the export. From there:

1. Cuts each kept stretch to its own temp file with `-ss`/`-to`, encoding with
   `h264_videotoolbox`. If a smaller resolution was chosen, `scale=-2:<height>` is applied **here**,
   which keeps a downscaled export to a single pass.
2. Concatenates the temp files through the concat demuxer with `-c copy`, so the join is a remux
   rather than a re-encode and takes about a second.

With `splitOutputs` on, step 1 writes straight to the final `<name> (part N).mp4` files next to the
source and step 2 is skipped entirely — so a split export is strictly cheaper than a joined one, not
more expensive. Because those files land outside the temp directory, cleanup is the pipeline's job:
`inFlightOutput` holds only the clip currently being encoded, and `discardInFlightOutput` deletes
that one on cancel or failure. Clips that already finished are deliberately kept and stay listed in
`outputPaths` — throwing away eight good clips because the ninth was cancelled is worse than leaving
them — which is why `wasCancelled` exists: without it the overlay would read a half-done split as a
success.

**Do not replace this with a single `filter_complex` doing `trim` + `concat`.** That was the
original implementation and it silently produced files whose audio track stopped early — video ran
the full length, audio ended at the second segment boundary — while ffmpeg reported success and
logged no warning. Cutting segments as separate processes sidesteps it entirely.

Progress comes from `-progress pipe:1 -nostats`, parsing the `out_time=` lines and scaling them
against the total kept duration.

## Gotchas worth remembering

- **Exports never overwrite.** `availableOutputPaths` claims the destination names before any
  encoding starts, appending `" (1)"`, `" (2)"`, … past anything already on disk. A split export is
  versioned as a *set* — all parts share one suffix — so a second three-clip run lands as
  `(part 1) (1)`, `(part 2) (1)`, `(part 3) (1)` instead of a batch whose numbering depends on which
  of its files happened to survive from an earlier run. `-y` stays on the ffmpeg calls only for the
  temp segment files.

- **Touching ranges merge only when removing.** `normalizeRanges` takes a `mergeTouching` flag.
  Cutting 0–10 and 10–20 is one cut, so those fold together. *Keeping* 0–10 and 10–20 is two
  deliberate clips, and folding them would silently turn a two-file split into one file — so keep
  mode merges on real overlap only.

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
