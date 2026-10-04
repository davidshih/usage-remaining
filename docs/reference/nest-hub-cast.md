# Nest Hub Max via Google Cast (spike results)

Spike date: 2026-10-03. Device: "鼠爸地下室房間 Display" (Google Nest Hub Max, 192.168.86.55), Mac at 192.168.86.65, same Wi-Fi.
Code: `nest-hub/spike/` (`server.py` serves `index.html` and logs `/ping`, `/touch`, `/audio` hits from the device).

## How to run

```bash
cd nest-hub/spike && python3 server.py 8765
uvx catt scan
uvx catt -d 192.168.86.55 cast_site http://192.168.86.65:8765/
uvx catt -d 192.168.86.55 stop
```

## Findings

| Question | Result |
|---|---|
| Can it display a plain `http://` page on the LAN? | Yes. `catt cast_site` (DashCast) navigates the top window: `window.top === window`, no iframe, no mixed-content block. |
| Viewport | `innerWidth/innerHeight` 1280x800, `screen` 1280x720, `devicePixelRatio` 1. UA: Fuchsia, Chrome 150, `CrKey/1.56`. |
| Does the cast time out? | No drop in 2025 s (~34 min) of 15 s heartbeats; stopped manually. |
| Touch input | Delivered to the page: `pointerdown`, `touchstart`, `click` with coordinates. Tapping does not bring up a stop-casting overlay. |
| Sound before any tap | Blocked: `AudioContext` stays `suspended`, `Audio.play()` rejects with `NotAllowedError`. |
| Sound after one tap | Allowed for the rest of the page's life: auto beeps 20 s and 60 s after a single tap played via Web Audio and `<audio>`. |

## Gotchas

- Re-casting the same URL, or a new URL without stopping first, keeps the old page. Run `catt stop`, then `cast_site` with a changed URL (for example `?v=N`).
- An alarm that must sound unattended needs one tap after each page load; refresh data with `fetch`, never reload the page.
- Only one receiver app runs at a time: casting an audio file with `catt cast` replaces the dashboard.

## Not verified

- Behavior after the Mac sleeps or the server restarts for a long time (page keeps polling; no auto re-cast exists yet).
- Whether Google ambient mode or a voice query ends the DashCast session.
- Casts longer than ~34 min.
