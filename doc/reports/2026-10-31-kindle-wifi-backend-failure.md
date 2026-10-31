# Kindle Wi-Fi request failures: contained errors and retryable UI

## Candidate and evidence

- Upstream report: <https://github.com/koreader/koreader/issues/15466> (open when checked on 2026-10-31). It describes an intermittent Paperwhite 3 / firmware 5.16.2.1.1 Wi-Fi toggle crash with `lipcErrNoSuchSource`.
- The attached text log does **not** establish a complete exception stack or the daemon's root cause; the upstream maintainer requested a reproduction without third-party plugins and a complete log. This change does not claim to diagnose firmware sleep/airplane-mode behavior or every crash in that report.
- The current fork nevertheless has an independently reproducible defect: `kindleEnableWifi` calls LIPC init, setters, and close without error containment. A synthetic setter exception escapes the real network menu callback and leaves the obtained handle unclosed.
- Initial reproduction baseline: fork main `445116315ef9e737b7ca375a5af11dd85268dfb2`, with base `d1b27196eac53e8c810c63762ed6bfb40f226382`. Historical published candidate `8333f986be5517b4130bc5f945e8fa397a8f654d` incorporates main `5d12c2aeb697abfd7713cd7396ac160fce08893e` (gesture/Calibre fixes).
- Latest validated code/test snapshot: PR head `8322cc0eed45d5c3b5b2c10bb1d4c3e54b0a21c2`, tree `ab2eed2bfbdf4c5e661fb657fa12512d3c35af96`, incorporates main `8bae649789c23f57fa86fbc52c2311dc3a28aa28` (cover-menu fix). The dated measurements below distinguish this snapshot from historical runs; a subsequent documentation-only correction does not change its production or test files. All README rows are preserved. No upstream PR is copied and no upstream state is modified.

## Change and compatibility

1. Protect LIPC initialization and both writes; independently attempt close exactly once after obtaining a handle. Successful setters/close are allowed to return nil. Preserve enable/disable command ordering. If the Lua binding exists but initialization fails, do not silently switch to shell commands.
2. Failed enable requests do not scan, associate, or run their completion callback; failed disable requests do not queue the two-second success callback. Restore returns explicit false on failure. The existing no-binding legacy path remains, but a failed `wifid` command now reports failure. The optional WAN shutdown exit status remains best effort for Wi-Fi-only devices.
3. Treat only explicit false as failure at shared manager/listener call sites; existing nil-as-accepted device backends remain compatible. Do not clear the known lease or the user's restore preference after a rejected shutdown, emit a disconnected event, or claim “Wi-Fi off.” Keep `NetworkDisconnecting` before the request because consumers use it for last-chance work while connectivity remains available.
4. A failed inactivity shutdown keeps the existing backoff/retry loop. Failed startup/resume restore does not enqueue a futile connectivity poll and retains restore intent for a later attempt.
5. Interactive failures show the existing translated backend-error message and remain dismissible/retryable. A failed multi-step request may have partially changed firmware state; false means the request did not complete, **not** proof that the radio remains on or off. Subsequent queries/retries retain their existing role.

This is not a radio-state transaction, a firmware-service restart, or an automatic shell fallback. The existing connection-abort path is unchanged and may make its normal best-effort shutdown attempt after a failed enable.

## Reproduction and validation

The authorized fork Linux emulator/LuaJIT and SDL dummy driver were used with isolated profiles. LIPC, model detection, scanning/association and host Wi-Fi command boundaries are synthetic; no physical Kindle or host network settings were changed. Scenario 47 forbids shell execution while its synthetic backend is installed.

| Check | Result |
| --- | --- |
| New backend unit suite | 17/17 on head `8322cc0e` / main `8bae6497`: both write positions for enable/disable/restore, init nil/throw, close failure, write+close failure, fresh-handle retry, nil-return success, interactive error, legacy WAN/wifid statuses |
| Historical related unit suites | Head `8333f986` / main `5d12c2ae`: 241/241 across eleven separate processes (the original eight Wi-Fi suites plus 66 gesture and 23 Calibre tests). Its Wi-Fi subset is 152/152: new backend, existing LIPC, Kindle device, manager flows, network manager, network settings, autosuspend-network, async DNS |
| Latest focused unit rerun | Head `8322cc0e` / main `8bae6497`: 95/95 across backend (17), manager/listener flows (72) and cover-menu lifecycle (6). This is a focused rerun, not a claim that all 241 historical cases were rerun on this head. |
| Existing host limitation | The initial candidate over main `4451163` ran all 73 manager-flow cases: 72 passed; the unchanged loopback `ifHasAnAddress finds` case fails because this host cannot enumerate interfaces. Subsequent local runs explicitly exclude that one case, not a product failure introduced here. |
| Changed executable unit coverage | 44/44 (100%) locally for head `8333f986` / main `5d12c2ae`, and independently in required CI for head `8322cc0e` / main `8bae6497`, via the fork coverage tool; partial changed-line measurement, not a full-repository coverage claim |
| Latest real emulator integration | Head `8322cc0e` / main `8bae6497`: 211/211 across scenarios 01/09/24/40/41/46/47, including the newly merged cover-menu lifecycle path. |
| Historical emulator integration | Head `8333f986` / main `5d12c2ae`: 200/200 across 01/09/24/40/41/47. The pre-publication candidate over main `4451163` passed 122/122 across 01/09/24/47. |
| Repeated new integration scenario | Pre-publication candidate over main `4451163`, three additional fresh profiles: 29/29 checks each (87/87 total) |
| Independent review | Before the main merges, static code and evidence-log review found no remaining blocking issue; not an independent native rerun. |
| Lint and whitespace | Luacheck API using repository options: zero warnings/errors; `git diff --check` passes |

Scenario 47 taps the actual `TouchMenu` Wi-Fi item, paints/dismisses the actual error `InfoMessage`, retries shutdown through the real two-second queue and event broadcast, retries enable through actual manager connectivity polling, checks the action listener's failed-off message and failed/later-successful resume. Kindle's real seamless-toggle capability is retained, so failed enable also exercises the existing abort cleanup. All synthetic LIPC handles must close once; no false success task/event may remain. Cleanup cancels exact owned callbacks, restores manager/device/module/settings state, and combines body/cleanup errors.

Negative controls with unchanged fork production code from main `4451163`:

- The new 17-case backend suite yields 4 passes, 3 assertion failures and 10 uncaught errors.
- The new manager/listener assertions expose five newly covered regressions, in addition to the separately documented existing loopback-host failure.
- Scenario 47 fails immediately through `TouchMenu:onMenuSelect → toggleWifiOff → disableWifi → kindleEnableWifi` with the injected `lipcErrNoSuchSource`. Restoring the candidate makes that same real UI path pass.

Retained local evidence: backend and flow negative-control logs, failing/passing scenario JSON reports, final-main unit and integration logs, and the fork changed-line coverage report. Public documentation intentionally omits private workspace paths. Non-interactive enable failures retain the existing caller behavior (log/abort rather than an additional backend popup); automatic restore remains silent. Native Kindle/ARM firmware behavior remains unverified; ordinary exact-head CI and CodeRabbit review are still required before merge.
