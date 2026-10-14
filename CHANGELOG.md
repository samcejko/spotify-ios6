# Changelog

## 0.2.1 (2026-10-14)

- Links in playlist and podcast descriptions: tap the description to open them. On iOS 6 a link opens in Safari or
  Surfari (your choice), on newer iOS in Safari; a link to YouTube, Twitch, Kick or TikTok offers the sister app when
  it is installed. The Ko-fi link in Settings behaves the same.
- The iOS 6 package declares iOS 6.0 to 10.x (64-bit devices use the arm64 package).

## 0.2.0 (2026-10-14)

- A second build for 64-bit devices with iOS 14–17 (iPhone X and newer), from the same source tree: the `.deb` with
  `iphoneos-arm64` in its name for rootless jailbreaks (palera1n, Dopamine; it installs into `/var/jb`) and
  `Spot6-<version>-arm64.ipa` for TrollStore. Tried on an iPhone X with iOS 16.
- On iOS 7 and newer the app keeps its own 2012 look (the charcoal panels and the black glass bars are drawn through
  the appearance objects newer iOS insist on), opens Now Playing full screen and keeps the tab bar, the player bar and
  the full player clear of the notch and the home indicator. iOS 14 and newer ask once before the Spotify Connect
  announcement on the local network (the phone's login); the question is in English and Czech.
- The 32-bit build behaves the same on devices with iOS 7–10.

## 0.1.1 (2026-10-14)

- Settings → About has a "Support the development" row that opens the author's Ko-fi page. The app stays free.
- Spot6 is in the repository `http://repo.samcejko.eu/` now (Cydia, Sileo, Zebra, Installer): add it as a source to get updates.

## 0.1.0 (2026-10-04)

- First version: login from the phone (zeroconf), the access point session, login5 and client tokens
- Browsing through Spotify's GraphQL API (the public Web API is rate limited for librespot's client id): the real,
  personal Home (made for you, daily mixes, recently played...), search with a top result, browse categories as
  coloured tiles, album / playlist / artist / podcast pages, the library (Liked Songs, playlists, albums, artists,
  podcasts), saving and following, adding to and removing from playlists, new playlists
- Playback of Ogg Vorbis up to 320 kbit/s: decryption, decoding, gapless, normalization, queue, shuffle, repeat,
  song radio, autoplay, lock screen and remote controls
- Now playing with synced lyrics and the queue; iPad sidebar with your playlists and a player bar, iPhone tabs
- Spotify Connect: the device in the account's device list; playback handed over from the phone or computer and
  controlled from there (play, pause, skip, seek, shuffle, repeat, queue, volume); music started here shows there
- English and Czech
