# Roadmap

A Jellyfin client for **Windows** (primary), **Android TV**, and **Android phone**, built around an anime-focused library.

## Tech stack

| Concern | Choice | Why |
|---|---|---|
| UI / app framework | Flutter (Dart) | One codebase for Windows, Android TV, and phone |
| Playback | `media_kit` (libmpv) | Broad codec support, full ASS subtitles with embedded fonts, HW decoding, same behavior on every platform |
| Jellyfin API | REST + WebSocket | Server-side sessions, playback reporting, remote control |
| Local storage | SQLite / Drift | Cache for metadata, MAL scores, ID mappings, downloads |

Design rules from day one:
- Windows is the reference platform: keyboard shortcuts, mouse, resizable windows, fullscreen.
- Every screen must be fully navigable with arrow keys + Enter + Back (this is what makes Android TV work).
- Separate layouts for desktop, TV (10-foot UI), and phone on top of shared logic.

## Server environment

- Anime metadata provider order: **AniDB → TheTVDB → TheMovieDb → AniList**
- Request management: **Seerr**

---

## Phase 1 — Foundation
- [x] Project scaffold (Flutter, Windows + Android targets)
- [x] Server connection: address entry, validation, server info
- [x] Login: username/password; persisted session token
- [x] Quick Connect login (essential for TV)
- [x] Multiple servers and users; profile picker

## Phase 2 — Library & browsing
- [x] Home: Continue Watching, Next Up, Recently Added per library
- [x] Library grid with sort/filter (genre, year, rating, watched state)
- [x] Series → season → episode navigation
- [x] Movie / series detail pages: cast & crew, similar items
- [x] Search
- [x] Collections, playlists, favorites
- [x] Image caching and fast grid scrolling for large libraries

## Phase 3 — Playback
- [x] Direct play first; transcode only when needed, with a visible reason
- [x] Audio and subtitle track selection
- [x] Full ASS/SSA rendering with embedded fonts; PGS subtitles
- [x] Resume position + watched state reported back to server
- [x] Next-episode autoplay with countdown
- [x] Intro / credits / recap skip via Jellyfin media segments
- [ ] Trickplay thumbnails on seek bar
- [x] Playback speed, audio delay, subtitle delay
- [ ] HDR / Dolby Vision, audio passthrough (Atmos, DTS) on Windows and TV
- [ ] Windows: media keys, taskbar thumbnail controls, picture-in-picture

> Phase 3 status (2026-10-26): player logic is unit-tested against a fake
> engine and fake server, but the media_kit player itself has **not been run**
> yet � it needs Visual Studio Build Tools (Windows) / Android SDK. First
> manual checks once it builds: ASS styling + embedded fonts, track switching,
> fullscreen, resume position on your server, and Caddy HTTPS with libmpv.

## Phase 4 — Android TV & phone
- [ ] 10-foot TV layout with focus handling and D-pad navigation
- [ ] Android TV launcher integration (Leanback, home screen rows)
- [ ] Phone layout (portrait browsing, landscape player)
- [ ] Remote control: use the phone to control playback on PC/TV

## Phase 5 — Anime & MyAnimeList
- [ ] MAL data via official MAL API v2 (client ID), Jikan as fallback; cached locally
- [ ] Item → MAL ID matching, in order:
  1. AniDB ID → MAL ID (via [Fribb/anime-lists](https://github.com/Fribb/anime-lists) mapping)
  2. AniList ID → MAL ID (AniList API returns `idMal`)
  3. TVDB / TMDB ID + season number → MAL ID (same mapping list)
  4. Title search fallback, with a manual "fix match" option
- [ ] MAL score, rank, and popularity on posters and detail pages
- [ ] Sort / filter library by MAL score
- [ ] MAL list sync while watching:
  - [ ] Link MAL account via OAuth 2.0 (PKCE); tokens stored securely, auto-refresh
  - [ ] When an episode is marked played in Jellyfin, update `num_watched_episodes` on MAL
  - [ ] Status: first episode → Watching (sets start date); final episode → Completed (sets finish date)
  - [ ] Never lower the MAL episode count (e.g. rewatching an earlier episode); handle rewatch flag
  - [ ] Offline queue: retry pending updates when back online
  - [ ] Per-series opt-out, and a "sync now" / sync log for troubleshooting
  - [ ] Unmatched items prompt for "fix match" instead of guessing
- [ ] Optional AniList sync
- [ ] AniSkip integration for opening/ending skip by MAL ID when server has no segments
- [ ] Per-series audio/subtitle preference (default: Japanese audio + English subs; remember per show if changed)
- [ ] Title language preference: Romaji / English / Japanese

## Phase 6 — Seerr integration
- [ ] Sign in to Seerr with Jellyfin credentials (or API key)
- [ ] Unified search: library results plus "Request" for items not on the server
- [ ] Discover rows on Home: Trending, Popular, Upcoming, Seasonal anime
- [ ] Request flow: season selection, 4K / quality profile / server / root folder (where permitted)
- [ ] My Requests: status (pending → approved → downloading → available)
- [ ] Notification when a request becomes available
- [ ] Admin: approve / decline requests

## Phase 7 — Extras
- [ ] Offline downloads (phone and PC), with progress sync when back online
- [ ] SyncPlay (watch together)
- [ ] Music library with background playback
- [ ] Live TV & DVR
- [ ] Trakt scrobbling
- [ ] Discord Rich Presence (Windows)
- [ ] Launch at startup (Windows)

---

## Open questions
- Which current-client problems must Phase 3 fix first?
