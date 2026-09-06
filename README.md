# Video Trimmer

A native macOS app for cutting unwanted stretches out of a video — ad breaks, pauses,
prayer breaks in a recorded lecture — and exporting what's left as a single file.

Built with SwiftUI and driven by `ffmpeg` under the hood. Apple Silicon only.

## Features

- **Mark by dragging.** Drag across the timeline to mark a stretch for removal. Segments can be
  moved and resized by their handles, and they clamp against their neighbours so they never overlap.
- **Filmstrip timeline** with thumbnails from the actual video, a time ruler, and a playhead.
  Zoom with a trackpad pinch, ⌘-scroll, or the toolbar buttons.
- **Resolution choice on export.** Pick the original resolution or downscale to 1080p / 720p / 480p,
  each showing an estimated output size. Downscaling happens while segments are cut, so it stays a
  single encode pass.
- **Live progress** with percentage, current stage, ETA, and a working cancel button.
- **Hardware encoding** via VideoToolbox (`h264_videotoolbox`), typically ~7× realtime on Apple Silicon.
- **ffmpeg management** built in: the settings panel reports whether ffmpeg is installed, which
  version, and can install or update it through Homebrew.
- Drag and drop a video from Finder onto the window to open it.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `←` / `→` | Seek back / forward 10 seconds |
| Pinch or `⌘`-scroll | Zoom the timeline |

## Requirements

- macOS on Apple Silicon
- Xcode command line tools (for `swiftc`)
- `ffmpeg` and `ffprobe` at `/opt/homebrew/bin` — install with `brew install ffmpeg`,
  or let the app install it for you from its settings panel

## Build

```sh
./build.sh
open ~/Applications/VideoTrimmer.app
```

The script compiles the sources, assembles the `.app` bundle, and ad-hoc signs it — no developer
certificate or Xcode project needed. Pass a path to install somewhere else:

```sh
./build.sh /Applications/VideoTrimmer.app
```

## How the export works

Rather than filtering the whole file in one pass, the app cuts each kept segment into its own
temporary file and then concatenates them with the concat demuxer:

1. For each stretch to keep, run `ffmpeg -ss <start> -to <end>` and encode it (scaling here if a
   smaller resolution was chosen).
2. Concatenate all segments with `-c copy` — no re-encode, so this step is nearly instant.

The more obvious approach — a single `filter_complex` with `trim` + `concat` — was tried first and
produced output whose audio track stopped early while the video ran to full length. Cutting the
segments separately avoids that failure entirely, and keeps audio and video in sync.

## Project layout

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
  AppIcon.icns         App icon
build.sh               Compile, bundle, and sign
```
