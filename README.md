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

The screen is only taken when it is free: if another app is running on the TV, or the TV is off or
on another input, nothing is shown until playback is started again.

## Layout

- `src/CastNowPlaying/` - the LMS plugin
- `receiver/` - the Cast Web Receiver page (served via GitHub Pages)
- `repo.xml` - LMS repository file, written by `tools/build-release.py <version>`
- `tools/` - tests, dev deploy, release build
