# Transport buffer lifetime probe

Release incremental transport chunks after concatenation, before decoding, so
the collector can reclaim them while it creates the decoded value. This restores
the lifetime of chunks formerly owned by the separate readAllFromFD function.

The controlled probe uses the same Linux x86_64 emulator and synthetic 8 MiB
result. Each sample starts a fresh emulator process and isolated profile. It
forces collection just before decoding and records the live Lua heap increase
from the pre-request baseline. This measures retained Lua data, not default-GC
peak memory, process RSS, or Kindle device savings.

Three fresh-process samples per variant gave median deltas of 24,817.465 KiB
before and 16,672.453 KiB after: a reduction of 8,145.012 KiB (7.95 MiB). Every
sample decoded the expected 8 MiB result length. Raw samples and source commits
are in trapper-transport-memory.json.

The research branch carries scenario 99 for reproduction; it is not part of the
production integration suite. Local Git history must contain the baseline
commit, and KODIR must load this branch's frontend and base bcd3758d or later.
Run each mode in separate processes to avoid warmed-cache and previous-coroutine
lifetimes biasing the comparison:

```sh
TRANSPORT_PROBE_MODE=before bash tools/run_integration_tests.sh --kodir "$KODIR" --output .agent-transport-before --repeat 3 99_transport
TRANSPORT_PROBE_MODE=after bash tools/run_integration_tests.sh --kodir "$KODIR" --output .agent-transport-after --repeat 3 99_transport
```
