# TODO

Tracker for known follow-up work that is intentionally deferred from a shipped change.

## Testing follow-ups for #69 (1.1.0)

The async-init change in #69 ships without automated test coverage of its new code paths. The following items should land in a separate change.

1. **Verify HTTP route re-registration on plugin disable/enable.** Confirm that `rabbitmq-plugins disable rabbitmq_queue_migration` followed by `rabbitmq-plugins enable rabbitmq_queue_migration` reliably re-registers the management plugin's extension routes. If it does not, the "disable + enable to retry" recovery flow is broken. Manual test: on a single node, watch for `GET /api/queue-migration/status` returning a response after the second `enable`.

2. **Multi-node cluster integration test.** Bring two of three nodes down, bring the third up alone, assert that the broker boots, that `rqm_init_state:status() =:= failed` after roughly 5 minutes, and that `GET /api/queue-migration/status` returns 503 with a body whose `status` field is `"failed"`.

3. **UI snapshot test for the init-status partial.** Out of scope until the existing UI test harness gains a facility for mocking non-2xx responses.

4. **Schema mismatch fast-fail.** The retry loop in `rqm_init_state` will exhaust all 10 attempts even when the failure is non-recoverable (e.g. `{aborted, {bad_type, ...}}` from `rabbit_table:create/2` when the on-disk schema differs). Could short-circuit to `failed` after the first such error rather than waiting 5 minutes. Minor optimisation.
