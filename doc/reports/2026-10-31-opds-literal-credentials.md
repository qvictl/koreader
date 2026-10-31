# OPDS literal catalog credentials

## Evidence and scope

[Upstream issue 13111](https://github.com/koreader/koreader/issues/13111)
initially describes special characters. The subsequent diagnosis is more
specific: a password containing literal percent-encoded-looking sequences such
as `%F5` is incorrectly decoded by LuaSocket before generating Basic auth.
Simply testing `^@%!` does not expose that defect.

The fork's pinned LuaSocket still calls `url.unescape(reqt.password)` in
`adjustheaders`. OPDSClient passes the catalog form's literal password as that
field. The wire-level negative tests confirm the mismatch, without contacting a
service. [RFC 7617 section 2](https://www.rfc-editor.org/rfc/rfc7617.html#section-2)
defines Basic credentials from the user-id, colon and password octets, encoded
with Base64; URL-userinfo decoding is a separate concern.

This change is confined to `plugins/opds.koplugin/opdsclient.lua`:

- For a complete explicit username/password pair on the existing same-origin
  path, construct a Basic Authorization header from the literal strings.
- Build it in each hop's new header table, never in the caller's table. A
  cross-origin hop gets no newly generated origin credentials; returning to the
  original origin rebuilds them.
- Preserve a caller-supplied Authorization header, case-insensitively, and retain
  the existing `user`/`password` fields. LuaSocket's explicit header override
  supplies the corrected bytes without changing its global URL semantics.
- Leave empty strings valid, partial explicit pairs and URL-only credentials on
  their old paths, and retain redirects, cookies, proxy handling and TLS retries.

No native dependency, shared URL parser, authentication challenge policy,
encoding negotiation or settings format is changed. UTF-8 tests prove preservation
of supplied bytes, not interoperability with every server's character encoding.
OPDS-PSE's separate direct HTTP calls are **not** fixed by this change. Existing
caller-supplied Authorization redirect behavior, URL-embedded credentials and
origin comparison rules are not redesigned. The new header is never generated
for another origin; that is not a claim about every pre-existing auth path.

## Frozen candidate and validation

Base: actual accepted main `9b1834c0b8333dc7d9c456b591a0706d72ee8622`.
Local code commit `4d60a21ca3d9aedc4981e60cae620005917a5fe3` and published
code object `1904eaaa79a181977eecdc9f3aaf51865e1e9774` have the same tree
`b5dd5bf74ec250d5c967e0af39ff7e3e3bdf75e6`. This report is a documentation-only
successor; it does not change the executable/test snapshot below.

| Check | Result |
|---|---|
| Focused credentials unit suite | **33/33** |
| Selected related suites, separate processes | **300/300 in 16 nonempty suites; 18 invocations** |
| Real emulator integration combination | **732/732 across 16 scenarios** |
| Scenario 66, fresh profiles | **3 × 23/23** |
| Changed-line unit coverage, fresh statistics | **5/5**, 100% |
| Lua lint / original size / whitespace | **0 warnings/errors**, pass, pass |
| Python fixture syntax | pass |
| Independent isolated runtime | **33/33 units + 23/23 scenario 66**, matching source |

The related unit selection covers credentials, OPDS, network manager/settings/flows,
Wallabag sink/null metadata, Wikipedia languages,
DocSettings/location, document registry, ReaderUI lifecycle/password cancellation,
dispatcher, button and menu sorting. HTTP client and Spore were also invoked but
ran **zero tests** under the default exclusions; they are not validated by this
selection. The known host-only loopback-address case in
`networkmgr_flows_spec` is explicitly excluded; this is not an unfiltered full
suite or whole-repository pass. No new host defect is claimed from that exclusion.

The integration combination is 01, 02, 16, 46, 49, 50, 55, 56, 57, 58, 59, 60,
62, 63, 64 and 66; applicable existing budgets pass. Scenario 49 also confirms
compatibility with the accepted proxy request-target fix. Whole-repository and
release combined coverage are unmeasured here; the coverage report is diff mode.

### What the new tests exercise

`opds_credentials_spec.lua` invokes the real HTTP request parser/header writer
with an injected transport, never opening a socket or resolving a hostname.
It covers GET/HEAD, `%F5`, `%40%3A`, `%25%00%0d%0a`, `%2520`, bare/invalid percent
sequences, plus signs, punctuation, UTF-8, empty fields, proxy/origin separation,
three Authorization header casings, unchanged caller headers, URL-only and
partial-pair compatibility, relative redirects, changed host/port/scheme,
HTTPS downgrade refusal, A-to-B-to-A redirects and interrupted TLS retries.
The percent sequences in those fixtures are literal printable characters, not
actual control characters in a password.

Scenario 66 launches a bounded private Python fixture with two separately bound
`127.0.0.1` origins. It cannot forward requests. Synthetic credentials are checked
by the server against the actual received Basic header. A real catalog menu tap
fetches and renders a publication; direct calls to the normal browser HEAD and
`downloadFile` methods exercise those paths, then the downloaded EPUB is opened
and paged using the native reader. Same-origin redirects retain credentials and
the second origin rejects any leaked Authorization. This is not a full download
button/dialog test or a real TLS/server-account test.

Cleanup restores proxy, connectivity prerequisite and timeout state independently
of widget/worker cleanup failures, closes the private browser/reader and terminates
and reaps the owned fixture process. Private reader inputs remain available to
queued workers. No real account, device setting, network service or user file is
used. Emulator/native assets are reused, not rebuilt; no physical reader claim.

### Negative controls and review

With **actual main's OPDSClient** substituted and the final 33 tests unchanged,
**15 pass / 18 fail**. The real scenario receives HTTP **403** because the wire
password has been unescaped, and fails at the authenticated catalog assertion.
The candidate source is restored and byte-compared after both controls.
An earlier 27-case development control was 13 pass / 14 fail; it is not the final
33-case result.

Four initial integration fixture attempts are excluded from passing evidence:
wrong Menu child field, omitted displayed author suffix, JSON null vs nil in
observation data, and binary EPUB bytes in assertion diagnostics producing
invalid UTF-8 JSON. These were fixture-only corrections, not production fixes.
The final repeated and combined results use the corrected fixture.

The independent reviewer found no actionable source/cleanup issue and reran the
33 focused units and 23 integration checks in a separate runtime with matching
production/test bytes. That review did not independently run the full selection,
negative controls, native rebuilds or remote CI. Exact-head CI and the repository's
formal AI review/merge gate remain separate publication requirements.

## Accepted-main synchronization

After Calibre inbox initialization merged as actual main
`a7f4a2f31e47807bcd39b7bcadc62f6d153cae61`, the candidate was combined with it.
The only conflict was adjacent README rows; both scenarios **65 and 66** are
retained. There was no production conflict, and all four OPDS production/test
files are unchanged from the frozen code snapshot above.

Local merge `e611158151081eb41ca0a6b31abeda6f3010dd09` and published merge object
`a1226a8d0e6c26857763bed4db07e5afc1ca7200` share tree
`873a9c8d39de7accfe5fa25013ffea9f12741d02`. The updated combination passed:

- **315/315 in 17 nonempty suites, 19 invocations**, adding Calibre's 15-case
  inbox-initialization suite; the same two default-excluded zero-case invocations
  and one host loopback exclusion remain explicit.
- **819/819 in 17 emulator scenarios**, the previous selection plus scenario 65;
  all applicable budgets pass. Scenario 66 again passes all 23 checks.
- Candidate runtime/source byte comparison and whitespace checks pass.

The earlier 300/732 totals, repeats, negative controls, fresh coverage and
independent runtime results retain their original snapshot attribution; this
section does not claim the independent reviewer reran the expanded combination.
The report-only successor leaves this tested combined tree's executable files
unchanged. Final exact-head CI and formal review remain required.
