# Spot6 - Spotify on iOS 6

An unofficial Spotify client for jailbroken iOS 6.x (iPad 2 / iPhone 4S era), in English and Czech, in the look of
Spotify's own iPad app of 2012: charcoal panels, glossy black bars, the green of the time. It plays music by itself
on the device - no phone needed once you are logged in.

- **Home**: a greeting, recently played, your top artists and songs, your playlists, new releases, featured playlists
- **Search** as you type: songs, artists, albums, playlists, podcasts; recent searches; browse categories
- **Your library**: Liked Songs, playlists (create one, add and remove songs), saved albums, followed artists, podcasts
- **Album, playlist, artist and podcast pages**: play, shuffle, save / follow; an artist's popular songs, albums,
  singles, appearances and related artists
- **Playback**: queue ("play next", "add to queue"), shuffle, repeat (all / one), song radio, autoplay of similar
  songs when the music runs out, gapless, normalized volume, quality up to 320 kbit/s (Ogg Vorbis)
- **Now playing** full screen with big artwork, **synced lyrics**, the queue; the lock screen and the headphone
  remote work, music goes on in the background
- **Spotify Connect**: Spot6 is in the device list of your Spotify apps (phone, computer) - hand the music over to
  the iPad from the phone and control it from there (play, pause, skip, seek, shuffle, repeat, queue, volume); music
  started on the iPad shows on the phone too
- iPad: a sidebar with your playlists and a player bar along the bottom; iPhone: tabs and a compact player bar

Spot6 is not affiliated with, endorsed by or associated with Spotify. It needs **Spotify Premium**.

## Logging in (from your phone, no password)

1. Put the iPad and your phone on the same Wi-Fi and open Spot6.
2. Open Spotify on the phone, start playing anything, tap the devices button and pick **Spot6 (iPad)**.
3. Spot6 logs in by itself and keeps the login; from then on everything is controlled in Spot6.

This is Spotify Connect's zeroconf login: the phone's Spotify app sends a login meant for this device, encrypted
for it. Spot6 never sees or stores the password; it keeps only the reusable credentials Spotify hands out (in the
keychain). Settings - Log out forgets them.

Once logged in, "Spot6 (iPad)" stays in the device list of all your Spotify apps while Spot6 is open (or playing in
the background): pick it to move the music to the iPad, then use the phone as a remote.

## How it works

Spot6 talks to Spotify the way librespot does, all on the device:

- the **access point** connection (Diffie-Hellman, the server's RSA signature, the Shannon stream cipher) for the
  login, the account's country and product, the audio file keys and Mercury requests
- **login5** and the **client token** (with Spotify's hash-cash puzzles) for the access token
- Spotify's own **GraphQL API** (api-partner.spotify.com/pathfinder, the one the desktop and web clients use) for
  Home, search, browsing, album / artist / playlist / podcast pages, the library, saving and playlist edits; the
  **spclient** for track metadata, the audio file locations, lyrics, radio and creating playlists. (The public Web API
  is not used: it answers librespot's client id with "API rate limit exceeded", as every librespot-based app shares
  its quota.)
- the audio file from Spotify's CDN, decrypted with AES-128-CTR, decoded by stb_vorbis and played through an
  AudioQueue; the next song is prepared while the current one plays
- **Spotify Connect** as librespot does it: the "dealer" websocket brings the cluster updates and the commands (gzip
  JSON), the device and its player state go to the connect-state service (as JSON), a transfer's state is read from
  its protobuf, contexts are resolved through the spclient

Every HTTPS connection goes through Spot6's own TLS layer (Mbed TLS), since iOS 6 cannot talk to modern servers.

## Installing on the device

The IPA installs with `ipainstaller -f Spot6-<version>.ipa` (AppSync Unified), or the DEB with `dpkg -i` then
`su mobile -c uicache`.

## Building

GitHub Actions builds the IPA (Theos, iOS 9.3 SDK, deployment target iOS 6.0, armv7); see
`.github/workflows/build.yml`. Mbed TLS and the CA bundle are fetched during the build; the icon and launch images
are generated from `tools/icon.svg`.

## Project layout

```
src/Spotify/  the protocol: access point, session, tokens, Web API, spclient, zeroconf login, models
src/Audio/    downloading and decrypting audio files, the Vorbis decoder, the audio output, the engine, the player
src/UI/       the screens and the theme (all artwork is drawn in code)
src/Net/      the TLS socket, HTTP, images
src/Util/     settings, keychain, helpers
vendor/       stb_vorbis, the Mbed TLS configuration
tools/        build, push and iPad helper scripts, the icon
Resources/    Info.plist, the English and Czech texts
```

## License

MIT (see LICENSE). Third-party parts: see THIRD-PARTY-NOTICES.md.
