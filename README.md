# Video Trimmer

A native macOS app for cutting unwanted stretches out of a video — ad breaks, dead air, pauses in a
recorded lecture — and exporting what's left as a single file.

Built with SwiftUI, powered by `ffmpeg`. Apple Silicon only.

## Features

- Drag across the filmstrip timeline to mark a stretch for removal; drag the handles to fine-tune.
  Segments clamp against their neighbours, so they never overlap.
- Timeline built from real thumbnails, with a ruler, playhead, and zoom.
- Export at the original resolution or downscale to 1080p / 720p / 480p, each showing an estimated
  output size.
- Live progress with stage, ETA, and cancel.
- Hardware encoding through VideoToolbox — typically around 7× realtime on Apple Silicon.
- Manages its own `ffmpeg` dependency: check the version, install it, or update it from the
  settings panel.
- Drop a video from Finder anywhere on the window to open it.

## Shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `←` / `→` | Seek 10 seconds back / forward |
| Pinch or `⌘`-scroll | Zoom the timeline |

## Requirements

- macOS on Apple Silicon
- Xcode command line tools, for `swiftc`
- `ffmpeg` and `ffprobe` in `/opt/homebrew/bin` — `brew install ffmpeg`, or let the app install it
  from its settings panel

## Build and run

```sh
./build.sh
open ~/Applications/"Video Trimmer.app"
```

`build.sh` compiles the sources, assembles the `.app` bundle, and ad-hoc signs it — no Xcode project
or developer certificate involved. Pass a path to install elsewhere:

```sh
./build.sh /Applications/"Video Trimmer.app"
```

## Package a DMG

```sh
./package-dmg.sh
```

Builds a fresh copy into `dist/` and writes `dist/VideoTrimmer.dmg`, containing the app beside an
`/Applications` shortcut to drag it onto.

The app is ad-hoc signed rather than signed with a Developer ID and notarized. Copied across
directly that is fine, but macOS flags anything downloaded through a browser as quarantined and
Gatekeeper will refuse to open it. On the receiving Mac, right-click the app and choose **Open**
once, or clear the flag:

```sh
xattr -dr com.apple.quarantine /Applications/"Video Trimmer.app"
```

## Support

This app is free, and there is no donation link. If it saved you some time, please pray that Allah
grants me and my family Paradise. That is all I ask for it.

## License

MIT — see [LICENSE](LICENSE).
