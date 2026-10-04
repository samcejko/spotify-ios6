# Third-party notices

Spot6 is an independent, unofficial Spotify client. It is not affiliated with, endorsed by or associated with
Spotify AB. Spotify is a trademark of Spotify AB. Spot6 needs a Spotify Premium account; using an unofficial client
may be against Spotify's terms of use, which is the user's call. Spot6 never sees the account's password: the
Spotify app hands over a login meant for this device (Spotify Connect's "zeroconf" login).

## In the app

- **stb_vorbis** (Sean Barrett) - public domain (or MIT, at the user's choice). The Ogg Vorbis decoder.
  https://github.com/nothings/stb
- **Mbed TLS** - Apache License 2.0. The TLS 1.2 client for every HTTPS request (iOS 6's own stack cannot talk to
  modern servers) and the cryptography of the access point protocol (Diffie-Hellman, RSA, AES, HMAC, PBKDF2).
  https://github.com/Mbed-TLS/mbedtls
- **Mozilla CA certificate bundle** (curl.se/ca) - MPL-2.0. The roots TLS connections are checked against.
- **Theos** - the build system; not shipped in the app.

## Reference

- **librespot** - MIT License. How Spotify's access point protocol, the zeroconf login, the audio key exchange and
  the audio file format work was learned from librespot's source; no librespot code is included.
  https://github.com/librespot-org/librespot
- **NTify** - the look of a Spotify client for iOS 6 that inspired Spot6's screens; no code of it is included.
  https://github.com/NTifyApp/NTify

The license texts of the shipped libraries are included in the app bundle.
