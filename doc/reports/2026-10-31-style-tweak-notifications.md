# Style tweak actions honor notification preferences

## Provenance and reproduced scope

Upstream [issue 16250](https://github.com/koreader/koreader/issues/16250)
reports profile-triggered notifications despite disabling global notifications
and the profile's execution notification. The reporter clarifies that the
messages concern style tweaks. A read-only issue/comment and PR search found no
matching fix. The original style-tweak gesture feedback from upstream PR 10674
is retained when notifications are enabled.

Accepted main `bb8c3c7a213921874d0aec64216c87d523114393` was characterized before
production edits with a native EPUB and actual Profiles/Dispatcher instances.
With `notification_sources_to_show_mask = 0` and profile `notify = false`, each
of the individual/all/book-specific tweak actions still displays one toast.
The normal dispatcher-mask setting displays one toast per action as a positive
control; the real auto-execution next-tick path also displays a toast with the
zero mask, while explicit menu suppression displays none. Fourteen private
characterization checks passed, establishing the unwanted display behavior.

All three toggle handlers directly constructed/shown `Notification` widgets,
bypassing the existing source-mask API. The fix calls `Notification:notify(text)`
instead. Dispatcher still supplies its notification source, the global mask
still selects that source, and explicit `no_notification` arguments remain
effective. The profile `notify` flag still controls only its separate execution
message, not the actions' messages. CSS application, toggling, settings, unknown
tweak handling, book-tweak editor entry, clipboard/editor-save feedback and
notification timing/painting are otherwise unchanged.

This is not a physical Onyx device reproduction or a diagnosis of persistent
e-ink pixels/timeout behavior. It fixes the independently reproduced preference
bypass; it does not change all notification callers or promise universal popup
suppression.

## Validation

Final code/test commit `61df74934333463ce1beca20c707d1d1d0f9b7aa`, tree
`57ece0824d09d8592a6abe180254bfbd3c5fc04f`, is based on accepted main above.
This report is a later documentation-only change; the PR records exact remote
publication heads and verified trees.

- **28/28 focused units**: all three handlers across zero/default/dispatcher/
  other masks and source inclusion/exclusion; notification history, explicit
  menu suppression, repeated toggles, idempotent set, global/document overrides,
  unknown tweaks and missing-book-tweak editor entry. Actual CSS aggregation and
  notification widgets run; only the reader's ApplyStyleSheet boundary is a
  lightweight observer. Saved notification state, settings, widgets/timeouts
  and input fields are restored after closing the owned notifications.
- **285/285 across twelve related unit suites**, with no selected exclusions:
  readerstyletweak_notifications, dispatcher, readerwikipedia_languages,
  wikipedia, dictquicklookup, readerhighlight_actions, readerui_lifecycle,
  button, inputtext, readerzooming_settings, readerzooming_keyboard and
  terminal_ime_output.
- Scenario **64: 92/92**, including actual profile Execute menus, notification
  preference menu, profile checkbox, three tweak actions, batched execution
  messages, actual ReaderReady auto-execution on two reopenings, painted enabled
  toasts, and native page turning after dismissal. Profile fixtures belong to
  the isolated emulator profile; no network, shell, device or external data.
- **586/586** in thirteen related scenarios
  (01/02/03/05/06/12/55/56/59/60/62/63/64), with applicable budgets passing;
  scenario 64 additionally passed **three fresh profiles, 92/92 each**.
- Exact main production with final unit assertions: **18 pass / 10 fail**.
  The final native scenario fails on the first real profile Execute action,
  observing one notification instead of zero. Candidate production is restored
  and byte-compared after negative controls.
- Fresh changed-line unit coverage is **8/8** per the repository coverage tool.
  Configuration-aware lint has zero warnings/errors; original unscaled-size
  and whitespace checks pass.
- Independent review identified a fixture ownership issue: retaining a settings
  table reference did not protect it from in-place mutation, and unconditional
  action removal could erase preexisting registrations. The final scenario first
  asserts its key/actions are absent, copies the table, and removes only actions
  it owns. The reviewer accepted this correction and independently passed
  **28/28 units and 92/92 integration checks** with matching source/spec hashes.
  Earlier 89-check scenario results are superseded by the final reruns above.

The unchanged selector requests full unit CI due to opaque external
`ffi/blitbuffer`. Required exact-head CI, included AI review and the unchanged
merge gate remain required. Native Linux emulator assets were reused, not
freshly rebuilt; the base gitlink is unchanged. Scoped local tests and diff
coverage are not whole-repository/release coverage or physical-device evidence.
