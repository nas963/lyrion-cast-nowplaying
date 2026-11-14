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

With Material Skin, the player menu gets a **Cast screen on/off** item for every player that a Cast
screen follows, so the screen can be switched without opening the settings. The same works from the
CLI: `<player> castnowplaying toggle`.

The screen is only taken when it is free: if another app is running on the TV, or the TV is off or
on another input, nothing is shown until playback is started again.

## Layout

- `src/CastNowPlaying/` - the LMS plugin
- `receiver/` - the Cast Web Receiver page (served via GitHub Pages)
- `repo.xml` - LMS repository file, written by `tools/build-release.py <version>`
- `tools/` - tests, dev deploy, release build
