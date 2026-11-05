# Continue here (2026-11-05)

State: the app is complete per [PLAN.md](PLAN.md). `claude/sharp-wright-c54pu4` was merged into `main` on 2026-11-05 (tag
`pre-merge-2026-11-05` = `main` before). CI is green at `a75b619`, and the Approve/Deny button fix (`11c3532`) shows correctly in
`ci-screenshots:claude-sharp-wright-c54pu4/a75b619/02-demo-actions-light.png`. `testing` = `main` (for the phone test).

Open items across all repos (agent deploy, laptop setup, ideas): `Continue here.md` in the homelab vault.

## Needs attention

| # | What | Why | How |
|---|---|---|---|
| 1 | **sim-smoke reports 6 of 23 shots as "app not running"** at `a75b619` (07, 14, 15, 16, 18, 19; 0 crash reports). At `a7a3ab4` all 23 were ok | Probably the harness's "is the app still running" check, not the app: `07-demo-actions-dark-NOT-RUNNING.png` shows a normal, correct screen. CI stays green because only the core shots 01–05 gate it | Look at `scripts/sim-smoke` (the running check near the `NOT-RUNNING` screenshot) and the run log; rerun CI. If it's real, compare with `a7a3ab4` |
| 2 | **README screenshots are missing** | README links `docs/screenshots/01-overview.png … 06-dark.png`, which don't exist yet | Copy `ci-screenshots:claude-sharp-wright-c54pu4/readme/*.png` (sha `a75b619`) into `docs/screenshots/` and commit. Later runs on `main` write to `ci-screenshots:main/readme/` |
| 3 | **Phone tests** | Nothing has run on a real iPhone yet | Spike: `Day Test iOS Spike.md` (homelab vault, S1–S7). App: [DeviceTest.md](DeviceTest.md). Fix every ⚠️/❌. The live tests need the agent's API v1 deployed (homelab repo) |
| 4 | Review round 3 | Round 2 scores: plan 80, code 90, security 93, docs/UX 84 (goal: all ≥ 95). Most round-2 findings are fixed in `3d02b3b`/`11c3532` but not re-judged | Run the four judges again (plan, code, security, docs/UX), fix, repeat |

## Later (not blocking)

- First release by hand when the phone tests pass: [docs/RELEASE.md](docs/RELEASE.md) (CI never builds installable apps, owner's rule).
- Delete the `spike` branch after S1–S7. Keep `ci-screenshots` (CI writes to it).
- Small open review nits: the reference server trusts the login header from any loopback process (documented);
  HA areas on the Home tab need the WebSocket API (see PLAN.md "Deviations").

## Where things are

| Thing | Where |
|---|---|
| Plan and deviations | [PLAN.md](PLAN.md) |
| Build/install on Arch | [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md) |
| Tests | `scripts/test-linux` (Swift in Docker + Python), CI: [docs/CI.md](docs/CI.md) |
| Decisions and progress | homelab vault: `iOS-App.md`, `iOS-App Session Plan.md` |
