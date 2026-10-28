# Dictionary startup polling latency (2026-10-28)

The initial sdcv polling floor is reduced from 10 ms to 2 ms. The existing elapsed/8 backoff and 250 ms cap remain: long lookups do not keep polling at the initial rate. No daemon or additional persistent process is introduced.

## Measurement

Same x86-64 host, 1072×1448 at 300 dpi, main #33 CI native artifact (run 40770515010), current main #36 Lua, and an isolated copy of three user dictionaries. Three fresh-process pairs ran in AB/BA/AB order. Each process did three rounds of six words in classic and progressive mode: 216 completed lookups and 12 immediate tap cancellations in total. No global page cache was cleared. Measurements use CLOCK_MONOTONIC at microsecond resolution; benchmark instrumentation stays outside product code.

[Raw measurements and research-only harness](https://github.com/qvictl/koreader/tree/b5dbb7f5c/research/dictionary-ui) contain counts, timings and hashes; no dictionary content or screenshots are committed. The research-only scenario 99 is excluded from main. Its optional diagnostic replaces only the same initial polling floor; the production change is the equivalent one-line update.

| Metric (108 completed queries per column) | Before | After |
| --- | ---: | ---: |
| Median first actual paint |49.76 ms |38.13 ms |
| Median final actual paint |61.27 ms |41.96 ms |
| Median UI process CPU time |27.67 ms |28.52 ms |
| Largest heartbeat gap observed |63.6 ms |50.4 ms |
| Largest sampled RSS while showing results |120.6 MiB |119.6 MiB |

First paint improves 23% and final paint 32% in this host sample. UI CPU median rises 3%, while summed CPU time falls 7%; the variation does not establish CPU savings. More early polls are expected. RSS is comparable and no memory benefit is claimed. These are emulator results, not Kindle hardware measurements or guaranteed device speedups.

For `run` (about 520 KB JSON output), the spawn-to-observed-EOF median falls 41.9→17.1 ms; this interval includes UI polling and is not native CPU time. Independent native CLI CPU medians across the six words are 3.46–21.38 ms. JSON decode medians are 0.01–1.36 ms; HTML widget initialization is another material cost, so a permanent sdcv process is not justified by these measurements.

All ordered definition digests match across both variants and classic/progressive modes. Final screen pixel hashes also match for every word and mode across all process pairs. Immediate cancellation tap dispatch stays below 0.5 ms, with the exact native pid reaped in 20.6–28.2 ms. This measures cancellation before the first result, rather than a delayed on-screen progress message.

## Regression checks

A deterministic coroutine test requires a ready short query to yield and get its first collection opportunity within 5 ms; it fails against the former 10 ms floor. Another checks that half-second and long-running lookups back off instead of retaining the initial polling rate. Existing real sdcv unit tests cover results, progressive ordering, cancellation, spawn/read failures and reaping. Public real UI scenarios 04/05/06 cover classic/progressive lookup and dictionary resources without private data. Updated scenario 05 repeats a short public query three times in each mode, checks complete result equality, and records first-paint medians with generous real-time response budgets; the precise startup deadline remains a fixed-clock unit assertion.
