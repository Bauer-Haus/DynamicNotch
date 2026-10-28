# Boring Notch (media player edition)

A macOS app that turns the MacBook notch into a music player, modelled on the iPhone's
Dynamic Island. It is a stripped-down fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch)
that keeps only the media player and rebuilds the waveform to match the iPhone's.

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

1. Open `boringNotch.xcodeproj` in Xcode.
2. Under **Signing & Capabilities** for the `boringNotch` target, choose your own team.
3. Run the `boringNotch` scheme. ⌘U runs the unit tests.

The app does not update itself; install new builds by replacing the app.

## Licence and credits

GPL-3.0, see [LICENSE](LICENSE). Based on [boring.notch](https://github.com/TheBoredTeam/boring.notch)
by TheBoredTeam and its contributors. Third-party code and its licences are listed in
[THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
