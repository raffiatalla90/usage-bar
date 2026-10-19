# UsageBar

Menu bar app for macOS that shows what your coding agents are actually costing you.

Three pages, one popover:

- **Kuota** — remaining quota per provider, reset times, model breakdown, daily chart
- **Token** — token spend per day and per model, split by source (Claude Code vs. local gateway)
- **Tool** — which project you are working in right now and how many tokens each context saver has trimmed

No third-party dependencies. No telemetry. No network calls except to the provider APIs you
configure yourself.

## Install

```bash
./scripts/build.sh     # swift build -c release → build/UsageBar.app → ad-hoc codesign
./scripts/install.sh   # copy to /Applications + LaunchAgent + launch
./scripts/uninstall.sh # remove app, LaunchAgent, caches, key, prefs
```

Requires macOS 13+ and a Swift toolchain (`xcode-select --install` is enough).

## What it reads

Everything is read locally unless noted. A source that is missing is skipped — the app runs
with whatever it finds.

| Source | Location | Network |
|---|---|---|
| Claude Code quota | OAuth token from Keychain (`Claude Code-credentials`) | `api.anthropic.com/api/oauth/usage` |
| Claude Code tokens | `~/.claude/projects/**/*.jsonl` | no |
| OpenCode tokens | `~/.local/share/opencode/opencode.db` (read-only) | no |
| Kenari usage | `GET /v1/usage`, `/v1/usage/daily`, `/v1/account/quota`, `/v1/account/balance` | yes |
| 9router gateway | `~/.9router/db/data.sqlite` (read-only) | no |
| headroom | `~/.headroom/proxy_savings.json`, `127.0.0.1:8787/stats` | loopback only |
| rtk | `~/Library/Application Support/rtk/history.db` (read-only) | no |
| caveman | `~/.claude/.caveman-active`, `~/.config/opencode/.caveman-active` | no |

Databases owned by other tools are opened read-only, never written.

## API keys

Kenari is optional. If you do not use it, nothing needs configuring.

Three sources, checked in order:

1. env `KENARI_API_KEY`
2. Keychain (`com.usagebar.app` / `kenari-api-key`):
   ```bash
   /Applications/UsageBar.app/Contents/MacOS/UsageBar --set-key 'kn-...'
   ```
3. `~/.kenari/credentials.json` — `{"api_key": "kn-..."}`

Two key types exist: a restricted tool key (reads `/v1/usage` only) and an account key
(reads quota and balance). A restricted key makes quota/balance show as unavailable instead
of erroring — the app keeps working.

Nothing is written to the repo. Keys are never logged.

## Verify without clicking

```bash
.build/release/UsageBar --render /tmp/usagebar.png --page tokens   # offscreen render
.build/release/UsageBar --dump last30                              # raw numbers
.build/release/UsageBar --verify                                   # status item on screen
```

`--render` uses `ImageRenderer`. Two things do not work offscreen: `ScrollView` (does not lay
out its content) and `Menu` (label is not rasterised), so `PopoverView` has `scrolling` and
`interactive` flags that the renderer turns off.

## Tests

```bash
swift test
```

Parsers are tested against fixtures and throwaway SQLite copies of the real schemas; tests
that read live local databases skip themselves when the file is absent.

## Notes and known limits

- OpenCode stores `cost` in USD and writes 0 for most routed models, so local cost shows `—`
  rather than a made-up number. No exchange-rate guessing.
- `/usage/daily` returns no token counts; when every day costs 0 the chart falls back to
  request counts. Daily tokens come from local data only.
- No alerts yet when spend crosses a threshold.
- The notch activity feed keeps a rolling 14-day window and groups rows by calendar day, so
  yesterday's changes stay listed under their own header instead of disappearing at midnight.
- Notch panel geometry is tuned for a 185 pt notch; other Macs fall back to the popover.

## License

MIT — see [LICENSE](LICENSE).
