# Kurage

Kurage (Japanese for jellyfish) is a [Jellyfin](https://jellyfin.org) client for **Windows**, **Android phones**
and **Android TV**, built with Flutter and libmpv (through [media_kit]). It
favours anime-heavy libraries: direct play first, full ASS subtitle rendering
with embedded fonts, MyAnimeList scores and list sync, and requests through
Seerr.

## Features

- **Playback:** direct play first, with a quality choice (and Auto) when the
  connection can't keep up; skip intro, recap and credits from Jellyfin's
  media segments or AniSkip; chapters, trickplay thumbnails, Up next.
- **Library:** Home rows you arrange, item pages, search, favourites, a
  watchlist, playlists you can reorder, downloads for offline viewing.
- **Anime:** MyAnimeList scores and sorting, list sync while you watch.
- **Seerr:** search, discover rows and requests in the app.
- **Watch together** (Jellyfin SyncPlay), Windows media keys and a mini
  player.
- **Themes:** a classic look and Depth, with theme files to export and
  import.

## Download

Windows and Android builds are on the [Releases](../../releases) page. The app
checks there for updates.

> **Android TV:** the same Android app installs and runs on Android TV, but its
> TV layout **hasn't been tested yet**. Expect rough edges with a remote; phones
> and Windows are the tested platforms.

## Requirements

- A Jellyfin server, 10.9 or newer (developed against 10.11).
- To build: Flutter (stable), see `tool/versions.env` for the versions CI
  uses.
  - **Windows:** Visual Studio 2022 (or Build Tools) with the "Desktop
    development with C++" workload.
  - **Android:** the Android SDK and JDK 17.

Check your setup with `flutter doctor`.

## Run

```sh
flutter pub get
flutter run -d windows      # or: flutter run -d <android-device-id>
```

The MyAnimeList features need a MAL client ID, passed at build time:
`--dart-define=MAL_CLIENT_ID=...` (or `--dart-define-from-file` with a file
holding it).

## Test

```sh
flutter analyze
flutter test
```

Tests run without a server: `test/support/fake_server.dart` answers API
calls, and the player logic is tested against a fake engine. `./build.sh
check` runs both in the same Docker image CI uses.

## CI and releases

GitHub Actions (`.github/workflows/ci.yml`) runs for a version tag (and when
started by hand). It runs `flutter analyze` and `flutter test`, then builds
Windows (zip) and Android (one APK per ABI) and attaches them to a **draft**
GitHub Release. The tag sets the app's version; a `-` (as in
`v0.4.0-beta.1`) marks a pre-release. The build number is the run number
plus 100.

Release APKs are signed on the maintainer's PC with
`tool/release-android.ps1`, which re-signs them with the release key and
publishes the release. No signing secrets live in GitHub.

## Layout

```
lib/
  app/            app shell: router, theme, providers, layout sizes
  core/           API clients and models (Jellyfin, Seerr, MAL), storage, logging
  features/       screens by area: auth, home, library, player, settings, …
  theme/          the theme engine and its themes
test/             mirrors lib/
```

## Self-hosted HTTPS

**Windows** trusts a private CA (such as Caddy's local CA) once its root
certificate is in the Windows certificate store; Caddy installs it there.

**Android** (TV, phone) only trusts public CAs for the app's connections;
user-installed CAs are not used. Instead the app trusts your CA itself:
when connecting fails with "certificate isn't trusted", choose
**Trust this server's certificate authority**, load the root certificate,
compare the fingerprint and confirm. It's listed (and removable) under
Settings > Trusted certificates. Trusting the root keeps working when the
server certificate renews (Caddy's local CA renews every 12 hours).

The app looks for the root certificate at `https://<server>/caddy-root.crt`.
Publish it from Caddy (it's a public certificate; the private key stays in
Caddy) by adding a `handle` to the site, and moving the existing
`reverse_proxy` into a fallback `handle`:

```caddyfile
jellyfin.home.arpa {
    tls internal

    handle /caddy-root.crt {
        # Caddy's data dir: /data/caddy in the official Docker image;
        # ~/.local/share/caddy (Linux), %AppData%\Caddy (Windows).
        root * /data/caddy/pki/authorities/local
        rewrite * /root.crt
        file_server
    }

    handle {
        reverse_proxy jellyfin:8096   # your existing upstream
    }
}
```

To get the fingerprint to compare with, on a PC that already trusts the CA:

```powershell
Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -like '*Caddy*' |
  ForEach-Object { $_.Subject; $_.GetCertHashString('SHA256') -replace '(..)(?!$)','$1:' }
```

or on the server: `openssl x509 -in root.crt -noout -fingerprint -sha256`.

## Licence

GNU General Public License v3.0: see [LICENSE](LICENSE). Kurage is an independent client, not made by or affiliated with the
Jellyfin project; Jellyfin is a trademark of its project.

[media_kit]: https://github.com/media-kit/media-kit
