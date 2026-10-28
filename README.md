# DynamicNotch

A macOS app that turns the MacBook notch into a music player, modelled on the iPhone's
Dynamic Island, with a waveform that follows the music the way the iPhone's does.

## What it does

- **Closed notch:** album art on the left, a live waveform on the right.
- **Live waveform:** follows the music you're playing, measured against the iPhone's Dynamic
  Island: six bars, its frequency bands and loudness curve, 30 fps, 40 ms smoothing. The bars
  show the album art, blurred, the way the iPhone colours them.
- **Open notch:** artwork, title, artist, progress bar and media controls. Play/pause,
  shuffle, repeat, favourite and volume respond the instant you click.
- **Music sources:** Now Playing (any app, including browsers), Apple Music or Spotify.
  Apple Music radio stations show their artwork too.
- **Optional:** lyrics (from LRCLIB), trackpad gestures to open/close the notch and change
  tracks, hiding the notch in full-screen apps.

## Requirements

- macOS 26 or later
- Xcode 26 to build

## Permissions

- **System Audio Recording Only** (Privacy & Security → Screen & System Audio Recording):
  lets the waveform hear what your Mac is playing. It can't see your screen. While it
  listens, macOS shows a purple dot in the menu bar. If you don't allow it, the bars
  show a simple animation instead.
- **Automation** for Music or Spotify, if you pick one of them as the music source.

## Building

1. Open `DynamicNotch.xcodeproj` in Xcode.
2. Under **Signing & Capabilities** for the `DynamicNotch` target, choose your own team.
3. Run the `DynamicNotch` scheme. ⌘U runs the unit tests.

## Finding your way around

Xcode's navigator shows the folders exactly as they are on disk; a new file dropped into a
folder joins the app automatically. Every file starts with a line saying what it does.

| Folder | What's in it |
| --- | --- |
| `App` | Start-up, the menu bar menu, app-wide state, Info.plist and entitlements |
| `Notch` | The notch window, its shape, sizes, open/close animations and view model |
| `Player` | The open notch's music player: cover, titles, progress bar, buttons, volume, output |
| `Music` | What's playing: `MusicManager` and the sources (Now Playing, Apple Music, Spotify) |
| `Waveform` | The live waveform: audio tap, spectrum analysis and the bars |
| `Screen` | Screen-level features: rounded bottom corners, full-screen detection, Spaces |
| `Settings` | The Settings window, one file per pane, and every saved setting (`SettingsKeys`) |
| `Onboarding` | The first-launch screens |
| `Support` | Small extensions and helpers |
| `Resources` | Icons and images, translations, preview assets |

The app does not update itself; install new builds by replacing the app.

## Licence and credits

GPL-3.0, see [LICENSE](LICENSE) and [CREDITS](CREDITS.md). Third-party code and its licences
are listed in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
