# Continue here (2026-11-04, end of the build session)

State: the app is complete per [PLAN.md](PLAN.md) and green in CI up to `a7a3ab4` (Linux + macOS, simulator
tests, 0 warnings, 23/23 screenshots). Newer commits (`d9bffa7`, `11c3532`) were still running in CI when the session
ended. Branch: `claude/sharp-wright-c54pu4` (not merged into `main` yet). `testing` = `c2292d0` (for the phone test).

## Needs attention

| # | What | Why | How |
|---|---|---|---|
| 1 | **Check CI for `11c3532`** | It fixes the blank Approve button; not yet confirmed green | GitHub → Actions → ci. Then look at `ci-screenshots/claude-sharp-wright-c54pu4/11c3532/02-demo-actions-light.png`: the buttons must say "Approve" and "Deny" |
| 2 | **`testing` has the blank-button bug** | Approve shows as an empty blue box, Deny as only "×" (both still work) | After 1 is green: `git push origin claude/sharp-wright-c54pu4:testing --force-with-lease`, then on the PC `git pull && xtool dev` |
| 3 | **README screenshots are missing** | README links `docs/screenshots/01-overview.png … 06-dark.png`, which don't exist yet | After a green run: copy `ci-screenshots:claude-sharp-wright-c54pu4/readme/*.png` into `docs/screenshots/` and commit |
| 4 | **Deploy the agent's API v1 (homelab repo)** | The app shows your real homelab only after this | From your machine: `deploy/claude-agent/deploy.sh` (homelab repo, branch `claude/sharp-wright-c54pu4`). It also changes the **Home Assistant push buttons** (now signed over the pending line); server and notifier deploy together, so nothing to do in HA. Then update `Homelab.md` (dated) |
| 5 | **Phone tests** | Nothing has run on a real iPhone yet | Spike: `Day Test iOS Spike.md` (homelab vault, S1–S7). App: [DeviceTest.md](DeviceTest.md). Fix every ⚠️/❌ |
| 6 | Review round 3 | Round 2 scores: plan 80, code 90, security 93, docs/UX 84 (goal: all ≥ 95). Most round-2 findings are fixed in `3d02b3b`/`11c3532` but not re-judged | Run the four judges again (plan, code, security, docs/UX), fix, repeat |

## Later (not blocking)

- First release by hand when the phone tests pass: [docs/RELEASE.md](docs/RELEASE.md) (CI never builds installable apps, owner's rule).
- Merge `claude/sharp-wright-c54pu4` into `main`; delete the `spike` branch after S1–S7.
- Small open review nits: the reference server trusts the login header from any loopback process (documented);
  HA areas on the Home tab need the WebSocket API (see PLAN.md "Deviations").

## Where things are

| Thing | Where |
|---|---|
| Plan and deviations | [PLAN.md](PLAN.md) |
| Build/install on Arch | [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md) |
| Tests | `scripts/test-linux` (Swift in Docker + Python), CI: [docs/CI.md](docs/CI.md) |
| Decisions and progress | homelab vault: `iOS-App.md`, `iOS-App Session Plan.md` |
