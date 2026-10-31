# Wallabag export file ownership and completion errors

## Origin and verified defect

This is an original follow-on to the isolated failure investigation for fork
[PR 84](https://github.com/qvictl/koreader/pull/84), not a port of an upstream
transactional-update fix. Upstream [issue 14147](https://github.com/koreader/koreader/issues/14147)
concerned nullable metadata; this report does not attribute the file-I/O defects
to that reporter or claim to explain every Wallabag synchronization failure.

`Wallabag:callAPI` gave `io.open(filepath, "w")` directly to `ltn12.sink.file`.
The exact authorized emulator's LuaSocket implementation closes that handle on
EOF but ignores the close result. Its pump stops on a write error without sending
another EOF; an HTTP request can also fail before receiving a body. Consequently:

- connection/partial-transfer/write failures could return without closing the file;
- a close failure after HTTP 200 could be reported as a saved article;
- a failed open still issued the request, and failure cleanup could remove a path
  that this request never opened successfully.

These behaviors were reproduced with private regular files, real Lua file handles,
and synthetic HTTP callbacks/I/O return failures. No live account, credentials,
service or network request was used.

## Narrow correction

The caller now owns the handle. Its sink writes chunks and acknowledges EOF without
closing. After the outer request returns, the caller resets timeouts and closes the
owned handle exactly once before deciding whether the download succeeded.

| Outcome | Contract |
|---|---|
| HTTP 200, successful close | Existing `true, filepath`; bytes and empty exports accepted |
| Normal network/write failure | Existing `false, "network_error"`; close before failed-file cleanup |
| Non-200 HTTP response | Existing `false, "http_error", code`; close even with no body/EOF |
| HTTP 200, failed/throwing close | `false, "file_error"`; do not report or inventory a saved article |
| Failed open | `false, "network_error"`; no request, no deletion of an unopened path |
| Unexpected request/write exception | Reset and close, then rethrow the original error object; no claim of preserving its original traceback |

A request exception remains primary if close also throws. Close is not retried.
Ordinary HTTP errors remain primary over a simultaneous close error. JSON requests
retain their successful result and do not acquire a file handle. No shared
LuaSocket, timeout helper, native implementation or review/CI policy is changed.

## Explicit limits

**This is not stable-ID or transactional replacement.** A successful `open("w")`
still truncates an existing same-path article before transfer. Same-ID title or
format changes may still leave a separate file without migrated reading state.
The fix does not preserve old content after that successful open, make sidecar
migration safe across formats, add fsync/rename staging, or promise power-failure
atomicity. Those are separate design problems; blindly reusing an old path would
not solve them.

The existing failed-transfer removal behavior is retained. Unexpected exceptions
still leave their partial file, as before, but now close the owned handle and reset
timeouts before rethrowing. Tests only inject write/close errors after real private
file operations; they are not physical ENOSPC/EIO or device/storage certification.

## Tests and exact attribution

Accepted base: `bb8c3c7a213921874d0aec64216c87d523114393` (main after PR 89).
Code object `4f82ba66ee285c3a6f3ca5b24d8049d799ee5793` and local tested code
`4e484c6479ff003bf92eca9b83f050a7b82bf492` have identical tree
`ad279a4b9951446695a9ab102c1f97c4ba565937`. The report-only successor changes no
production or tests. README rows 58/59/60/62/63 remain present.

- `spec/unit/wallabag_file_sink_spec.lua`: **17/17**. Real files and owned handle
  proxies cover successful/empty exports, no-body HTTP, pre-body and partial
  connection failures, partial writes, nil/throwing close failures, original
  exception identity, simultaneous errors, failed open of an owned existing path,
  fresh-handle retry and JSON success.
- Exact-main negative control with the final fixture: **5 pass / 11 fail / 1
  error**. The initial fifteen-case development fixture had 7 pass / 7 fail / 1
  error; these are separately attributed, not additional product bugs.
- Final related run: **541/541 across 32 selected suite runs**, including the new
  tests, existing Wallabag/metadata/input/reader/network flows and accepted
  Japanese/Wikipedia language cases. One pre-existing host loopback-address test
  in `networkmgr_flows_spec.lua` is explicitly excluded: the initial unfiltered
  run again produced 72 pass / 1 failure in that suite. This is not a full-suite
  or full-repository pass.
- Expanded existing scenario **58**: **49/49**, plus **3 × 49/49** fresh-profile
  repeats. The real Wallabag menu/summary sees synthetic connection, write and
  close failures, verifies exactly-once close, removal of the failed new export,
  unchanged earlier successful EPUBs/annotations, and then retries successfully.
  The native reader opens, navigates and reopens the real exported EPUB. Existing
  shared-config/disk-config restoration checks remain; no synthetic credentials
  are persisted.
- Final related integration: **599/599** across fourteen scenarios
  01/02/16/46/50/53/55/56/57/58/59/60/62/63; applicable budgets pass.
- Exact-main scenario control fails because the connection-error export handle
  was not closed before return. Candidate production was restored byte-for-byte
  after both negative controls.
- Fresh changed-line unit coverage: **18/18**, not whole-repository coverage.
  Configuration-aware lint: **0**; original size and whitespace checks pass.
- Independent reviewer: static review found no actionable issue and independently
  reran **17/17 units + 49/49 integration checks** in an isolated runtime with
  matching production/unit hashes. No independent full-combination, negative
  control, native rebuild or hardware run is claimed.

A local variable was renamed solely to remove a lint shadowing warning; the final
combined/repeated results above were rerun afterward. Native assets are reused
from the authorized Linux emulator, not rebuilt by this candidate. Full CI,
formal CodeRabbit review, and the normal repository merge gate remain required.
