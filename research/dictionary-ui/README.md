# Dictionary UI profiling (local research)

This branch keeps the test-only `spec/integration/scenarios/99_user_dictionary_profile.lua`; do not backport that private-data scenario into main or device overlays. It uses real ReaderDictionary UI events, three locally supplied dictionaries, exact process reaping, rapidjson decode, widget initialization and actual paint hooks. No definition, image, or dictionary file is committed. Hashes cover ordered final definitions and final screen pixels. Observed native-process elapsed time includes UI polling; independent CLI CPU and wall measurements are separate.

Use the exact main33 CI emulator native artifact from run40770515010 with this branch’s Lua and spec tree. First copy the supplied dictionary directory into an isolated local directory (`cp -a --reflink=auto`). The source dictionaries must remain untouched. Run:

```sh
STARDICT_DATA_DIR=/absolute/isolated/dict DICT_PROFILE_ROUNDS=3 \
  bash tools/run_integration_tests.sh --kodir /runtime/overlay \
  --output /results/before 99_user_dictionary_profile
STARDICT_DATA_DIR=/absolute/isolated/dict DICT_PROFILE_ROUNDS=3 DICT_PROFILE_POLL_MS=2 \
  bash tools/run_integration_tests.sh --kodir /runtime/overlay \
  --output /results/after 99_user_dictionary_profile
```

Repeat in AB/BA/AB order in fresh processes, preserving dictionary files and the same machine cache policy. Default floor is 10ms in the recorded frontend; only the optional diagnostic replaces the shared interval upvalue. It retains elapsed/8 backoff and the250ms cap. No daemon, global page-cache clearing or product forced GC is used. Metrics use CLOCK_MONOTONIC at microsecond resolution. Every process checks six-word result equivalence across classic and progressive modes and exercises real full-screen tap cancellation with exact pid reaping. Aggregate228 rows include216 successful queries and12 cancellations.

`python3 research/dictionary-ui/native_cli.py --kodir /runtime/overlay --dict-dir /isolated/dict --output /results/native.json` starts sdcv separately for each word, captures bytes in memory, and collects child CPU time with wait4. Launcher-contaminated ru_maxrss values are deliberately excluded. UI RSS measurements are sampled target-process memory, not Kindle hardware evidence; no memory reduction is claimed.
