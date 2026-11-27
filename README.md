# Lyrion Cast Now Playing

Shows the now-playing screen of a Lyrion Music Server player (cover, title, artist, album, progress)
on Chromecast / Google Cast TVs and boxes on your network. No control buttons, just the screen.

Pure Perl, no helper programs: works with LMS 8.0+ on any platform.

## Install

1. In LMS open **Settings > Plugins**.
2. At the bottom, under **Additional repositories**, add
   `https://nas963.github.io/lyrion-cast-nowplaying/repo.xml` and click **Apply**.
3. Tick **Cast Now Playing** in the list, click **Apply** and restart LMS when asked.
4. Open the plugin's settings, tick **Show** for the screens you want and pick the player each one follows.
   Two boxes with the same name can get names of your own (e.g. "Living room") in the same table.

With Material Skin, the player menu shows **Cast screen: on** or **Cast screen: off** (the current
state; a click switches it) for every player that a Cast
screen follows, so the screen can be switched without opening the settings. The same works from the
CLI: `<player> castnowplaying toggle`.

When the player plays an audio CD from the AudioCD plugin (`audiocd://` tracks), a CD-player style display
takes the place of the progress bar: track number and elapsed time in segment digits, a progress bar,
the disc's track list and the time on the disc. Cover and text stay as on the normal screen.
With AudioCD 1.6 or newer, the track's waveform is shown under the display (like Roon's), once the
track has been read into the AudioCD cache; the played part lights up.

For local files, with the [Waveform](https://github.com/nas963/lyrion-waveform) plugin installed, the
track's waveform takes the place of the progress bar; the played part is in the bar's color. Tracks
without a waveform yet keep the plain bar. Streamed tracks (Qobuz, TIDAL...) get one too once the
[VU Meter](https://github.com/nas963/lyrion-vumeter) plugin has recorded it.

With the VU Meter plugin, a player running on the LMS machine (squeezelite with `-v`) also gets VU meters
between the track details and the progress bar (or the CD display): analog needles or LED bars, as set
in the VU Meter settings. The plugin polls the local VU service every 100 ms and sends the levels to the
receiver over the Cast channel; the receiver draws them with `receiver/vu-draw.js` (a copy of the VU
Meter plugin's drawing code).

The screen is only taken when it is free: if someone casts another app to the TV, or the TV is off or
on another input, nothing is shown until playback is started again. Android TV apps that only hold a
media session in the background (reported as "AndroidNativeApp", e.g. a paused VLC) do not count.
If the screen is closed on the TV while music plays, it comes back when playback is started again.

## Layout

- `src/CastNowPlaying/` - the LMS plugin
- `receiver/` - the Cast Web Receiver page (served via GitHub Pages)
- `repo.xml` - LMS repository file, written by `tools/build-release.py <version>`
- `tools/` - tests, dev deploy, release build
