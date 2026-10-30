# Kindle AutoSuspend overdue t1 check

Source: [upstream issue 16194](https://github.com/koreader/koreader/issues/16194).
The fork's `6c2508ea34912281aedb7aa693a51af492cd2734` still schedules an
already elapsed t1 delay when AutoSuspend is due but powerd has not acknowledged
the suspend request. A zero/negative recheck can repeatedly run in the UI task
loop instead of returning to input handling.

The narrow fix reuses the existing four-minute retry interval only when that
delay is non-positive. It does not reset powerd's t1 timer, advance its last-reset
timestamp, change KeepAlive/charging policy, or claim that the device suspended.
Positive remaining delays and normal t1 resets after new input are preserved.

`autosuspend_sequencing_spec.lua` covers negative and zero delays, repeated
unacknowledged checks, positive remaining time and recovery after input.
`32_kindle_t1_retry` uses the real reader and UI task queue with a synthetic
Kindle powerd to check heartbeats, page turns and timer cancellation. Its guard
rejects an unsafe delay before enqueueing it, rather than intentionally hanging
the emulator on the old code.

This is a host-testable scheduling invariant, not a measured battery saving or
Kindle hardware verification. Required CI, current-head AI review and unresolved
review threads remain governed by the existing repository merge policy.
