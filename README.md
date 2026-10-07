# HoyoFetch

A macOS app for downloading and updating HoYoverse games (Genshin Impact, Honkai: Star Rail, Zenless Zone Zero, Honkai Impact 3rd) through the "Sophon" chunk protocol that HoYoPlay uses.

Unofficial; not affiliated with HoYoverse.

## Features

- Install a game, its voice packs and optional content packs.
- Update an installation from a patch build (HDiffPatch), falling back to chunk reuse when there's no patch for the installed version.
- Pre-download the next version during a preload window.
- Verify and repair an installation, re-downloading only damaged chunks.
- Resume any of these after an interruption.

## Layout

| Path | What |
|---|---|
| `HoyoFetch/` | The SwiftUI app |
| `Packages/SophonKit/` | The protocol library: API client, manifest parsing, install / update engine |
| `HoyoFetch/sophon-protocol.md` | The protocol notes the library implements |

SophonKit depends on [swift-protobuf](https://github.com/apple/swift-protobuf), [zstd](https://github.com/facebook/zstd) and [hdiffswift](https://github.com/ohaiibuzzle/hdiffswift).

## Building

The app and SophonKit run on macOS 15 or later. Open `HoyoFetch.xcodeproj` in Xcode 27 and run the `HoyoFetch` scheme. The first time, Xcode asks you to trust the SwiftLint build plugin.

From the command line:

```sh
xcodebuild -project HoyoFetch.xcodeproj -scheme HoyoFetch -skipPackagePluginValidation build
```

## Using SophonKit

```swift
import SophonKit

let installer = SophonInstaller()
let game = try await installer.client.gameBranches().first { $0.game.biz == "hkrpg_global" }!

try await installer.install(game, matchingFields: ["game", "en-us"], into: folder) { event in
    print(event)
}
// Later:
try await installer.update(game, in: folder)
```

The installed version and packages are recorded in `<folder>/.sophon/state.json`.

## Testing

```sh
cd Packages/SophonKit
swift test                  # unit tests
SOPHON_LIVE=1 swift test    # also runs tests against the live API and CDN (downloads real game files)
```

## Development

- SwiftLint runs on every build. The config is `.swiftlint.yml` at the repository root.
- The `.pb.swift` files are generated. After editing `Packages/SophonKit/Protos/`, run `Packages/SophonKit/Scripts/generate-protos.sh`.
