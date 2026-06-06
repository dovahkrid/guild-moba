# Guild — apps

Two apps make up the playable vertical slice:

- **`apps/server`** — a Dart WebSocket server running the authoritative simulation (pure `Match`/`IntentBuffer`/`RoomManager` core + real `shelf` adapters). One hardcoded 2-player room.
- **`apps/client`** — a Flutter + Flame web client (render + input only). All gameplay truth lives in the shared pure-Dart `packages/netcode` `MatchController`; Flame just renders `MatchView` (placeholder shapes) and turns clicks into move intents.

## Run a local 1v1 (two browser tabs)

Prerequisites: Dart 3.11.5+, Flutter 3.41.x, a Chrome browser.

```bash
# Terminal A — start the authoritative server
dart run apps/server/bin/server.dart 8080
#   prints: Guild server listening on ws://localhost:8080/ws

# Terminal B — run the Flutter web client
cd apps/client
flutter run -d chrome
#   note the served URL it prints
```

Then **open that same URL in a second browser tab**. The server assigns slot 0 to the first connection and slot 1 to the second — no client config differs.

In each tab, click on the dark lane:
- your hero (**blue**) moves toward the click (predicted instantly, client-side);
- the opponent (**red**) moves in the other tab (rendered ~100 ms interpolated);
- the **grey** wanderer drifts identically in both (RNG-driven, deterministic).

Use the **dev panel** (sliders, bottom of the screen) to inject latency (0–300 ms) and packet loss (0–50%) and confirm your hero stays responsive (prediction) while the opponent stays smooth (interpolation) — the same conditions proven headlessly in `packages/netcode`'s `FakeTransport` tests.

> Art is placeholder geometry. Hand-drawn pixel/SVG heroes, combat, and the elemental system come in later plans (3 and 4).

## Build for the web

```bash
cd apps/client
flutter build web --release          # canvaskit (default)
# or, for skwasm / dart2wasm (better Flame perf, falls back to canvaskit):
flutter build web --release --wasm
```

> Do **not** pass `--web-renderer` — it was removed in Flutter 3.41. For production, serve the client and the server's `/ws` on the **same origin** so the client can use `wss://` without mixed-content issues. Override the server URL at build time with `--dart-define=WS_URL=wss://your-host/ws`.

## Tests

```bash
dart test apps/server                 # pure loop + real-socket integration smoke
cd apps/client && flutter test        # net transport + match binding + widget smoke
```

The deep "smooth under 150 ms + loss" proof is headless in `packages/netcode` (run `dart test packages/netcode`). These app tests cover the wiring; the end-to-end feel is the manual two-tab run above.
