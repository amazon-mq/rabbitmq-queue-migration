# TODO

Tracker for known follow-up work that is intentionally deferred from a shipped change.

## Testing follow-ups for #69 (1.1.0)

The async-init change in #69 ships without automated test coverage of its new code paths. The following items should land in a separate change.

1. **Multi-node cluster integration test for the actual retry loop.** The intent is to exercise `try_setup_schema/0` through `rabbit_table:wait/1` failure, watch the gen-server schedule its retries via `send_after/3` for 10 attempts, and assert that the broker boots, that `rqm_init_state:status() =:= failed` after roughly 5 minutes, and that `GET /api/queue-migration/status` returns 503 with a body whose `status` field is `"failed"`. The naive recipe "stop two of three nodes, bring the third up alone" does not actually trigger `rabbit_table:wait/1` to time out in this plugin because the tables are created with `{disc_copies, [node()]}` and each node's local copy loads independently of peers. The customer's failure mode in the originating ticket involved Mnesia in a more specific waiting-for-peer-consensus state during a Full Cluster Reboot recovery; reproducing that locally requires more setup work than a simple node stop. Synthetic state injection via `sys:replace_state/2` has been used during PR #70 review to verify the 503 response shape, the JSON body produced by `build_status_detail/1`, and the disable/enable recovery procedure, but does not exercise `try_setup_schema/0`'s actual failure path.

2. **UI snapshot test for the init-status partial.** Out of scope until the existing UI test harness gains a facility for mocking non-2xx responses. The partial has been manually verified to render correctly for the `failed` state during PR #70 review.

3. **Schema mismatch fast-fail.** The retry loop in `rqm_init_state` will exhaust all 10 attempts even when the failure is non-recoverable (e.g. `{aborted, {bad_type, ...}}` from `rabbit_table:create/2` when the on-disk schema differs). Could short-circuit to `failed` after the first such error rather than waiting 5 minutes. Minor optimisation.
