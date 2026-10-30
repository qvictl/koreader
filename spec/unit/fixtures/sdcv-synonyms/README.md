# Compressed StarDict fixture

These files preserve the bytes of `tests/stardict-test_synonyms-2.4.2` from sdcv commit `a4ab0d45c53100433098b8d3e4c21d04b7c42f11`, the revision pinned by native base `7c4e2f0d81afafb8a19dfa2a28ec2df461962272`.

Source and licensing: https://github.com/Dushistov/sdcv/tree/a4ab0d45c53100433098b8d3e4c21d04b7c42f11

The source's `tests/t_synonyms` oracle expects queries `foo`, `bar` and `test` to return `result of test`. The complete set includes `.syn` and its XML source. Tests derive compressed indices and decompressed data inside isolated profiles while retaining these original fixture bytes.
