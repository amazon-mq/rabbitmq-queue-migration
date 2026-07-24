# Message Count Verification and Message Loss

This is the single reference for how the plugin verifies that no messages are lost during migration, why a migration can fail with `message_count_mismatch`, and how per-message TTL interacts with that check. Other documents link here rather than repeat this material.

If you are here because a migration failed with `message_count_mismatch`, jump to [The `message_count_mismatch` error](#the-message_count_mismatch-error).

---

## How verification works

For every non-empty queue, the plugin records the source message count before the shovel transfer begins (`expected_total`). After the transfer, it compares that against the actual count found across the source and destination queues:

```
actual_total  = source_final_count + destination_final_count
lost_messages = expected_total - actual_total
```

- `lost_messages > 0` is **under-delivery**: fewer messages ended up in the destination than the source started with.
- `lost_messages < 0` is **over-delivery**: more messages arrived than expected (for example, a duplicate redelivery during shovel retry).
- `lost_messages == 0` passes immediately.

A non-zero difference is compared against a tolerance. If the difference is within tolerance the queue passes with a warning; if it exceeds tolerance the migration fails for that queue. See `verify_message_counts/5` and `check_message_count_tolerance/6` in `src/rqm.erl`.

---

## Tolerance

Tolerance is a percentage of `expected_total`. The under-delivery and over-delivery directions have separate defaults:

| Direction | Default | Config key |
|-----------|---------|------------|
| Under-delivery (messages missing) | **0.0%** (exact match required) | `queue_migration.message_count_under_tolerance_percent` |
| Over-delivery (extra messages) | **5.0%** | `queue_migration.message_count_over_tolerance_percent` |

The under-delivery default is **0.0%**, meaning that by default **any** missing message fails the migration. This is deliberate: silently losing messages during a migration is treated as a hard error unless you opt into a tolerance. The defaults live in `include/rqm.hrl`; see [CONFIGURATION](CONFIGURATION.md) to change them broker-wide.

### The `tolerance` migration option

The `tolerance` option on the `start` request overrides **both** directions for that one migration with a single value (0.0 to 100.0):

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"tolerance": 10.0}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

With `tolerance: 10.0`, a queue whose source held 1000 messages passes as long as the destination has at least 900. Use this when you expect some messages to disappear during migration for a legitimate reason, the most common being per-message TTL expiry (below).

> [!WARNING]
> A non-zero under-tolerance can mask real message loss. It cannot distinguish a message that expired from one dropped by a bug. Set it only when you understand why messages are expected to be missing, and size it to that expectation.

---

## Per-message TTL: the invisible cause of loss

The single most common reason a migration loses messages is **per-message TTL**, and the plugin cannot see it in advance.

Publishers can set a TTL on individual messages using the AMQP `expiration` property (see [Per-Message TTL in Publishers](https://www.rabbitmq.com/docs/3.13/ttl#per-message-ttl-in-publishers)). Unlike a queue-level TTL (`x-message-ttl` argument or `message-ttl` policy), per-message TTL is a property of each message, not of the queue declaration, so it is **not visible when the plugin inspects the queue** before migration.

### Why it drops messages during migration

A classic queue only removes an expired message from the **head** of the queue, during a delivery attempt or a periodic expiry timer. Messages that have passed their TTL but sit deeper in the queue are still counted in the queue's `messages` total, even though they are effectively dead.

When the migration shovel starts consuming, it drains the queue from the head. As live messages are delivered, expired messages behind them reach the head and are dropped by the queue's own expiry mechanism. The result: `expected_total` was counted including the dead messages, but only the live ones reach the destination. The difference is counted as under-delivery.

This is especially pronounced on dead-letter or `_error` queues, which accumulate messages that are rarely consumed. Such a queue can hold a large backlog of already-expired messages that all drop the moment migration begins.

### A removed queue-level TTL policy can leave expiring messages behind

There is a subtle variant of this that looks like a clean queue to the pre-check but still fails during migration. It happens when a queue-level TTL was applied, messages were enqueued under it, and the TTL is then removed before migrating.

A queue-level TTL (an `x-message-ttl` argument or a `message-ttl` policy) does not stay abstract at the queue level. Each time a message is enqueued, the queue resolves the effective TTL and **stamps an absolute expiry timestamp onto that individual message** (`calculate_msg_expiry/2` in the broker's `rabbit_amqqueue_process`, which stores `now + ttl` in the message's properties). Once written, that per-message expiry travels with the message and is independent of the queue's current TTL setting.

Removing the policy or argument only clears the queue-level TTL going forward (`init_ttl(undefined, ...)`); it stops applying a TTL to *newly* enqueued messages and cancels the queue's expiry timer, but it does **not** revisit or strip the expiry already stamped onto messages sitting in the queue. Expiry is evaluated per message against its own stored timestamp (`drop_expired_msgs/2` drops any message where `now >= expiry`), regardless of whether the queue still has a TTL.

This produces the following sequence, which is easy to mistake for a fixed queue:

1. A `message-ttl` policy (or `x-message-ttl` argument) applies to the queue, and messages are enqueued while it is in effect. Each of those messages is stamped with an absolute expiry.
2. You run the pre-check. It reports the queue as unsuitable with the `message_ttl` reason, because the queue-level TTL is visible.
3. You delete the policy (or the argument) to clear that reason, and re-run the pre-check. It now reports the queue as suitable: the queue-level TTL is gone, and the pre-check has no way to see the expiry already baked into the buffered messages.
4. You start the migration. As the shovel drains the queue, the previously stamped messages reach their expiry and are dropped, exactly as with publisher-set per-message TTL. Verification records them as under-delivery, and the migration fails with `message_count_mismatch` and rolls back.

The trap is that step 3 makes the queue *look* clean while the backlog is still carrying expiry stamps from step 1. Deleting the policy does not un-stamp existing messages.

To avoid it, treat a queue that ever had a TTL the same as one with publisher-set per-message TTL: after removing the policy, **drain or let the existing backlog expire before migrating** (an empty queue takes the fast path and cannot hit this check), or migrate with a `tolerance` sized to the expected loss. Simply removing the policy immediately before migrating is not sufficient.

### What to do about it

Pick the approach that fits your risk tolerance:

1. **Set a `tolerance`.** If you accept that expired messages may be lost, set the `tolerance` option high enough to cover the expected proportion (see above). This is the direct remedy for the `message_count_mismatch` failure.
2. **Drain the queue first.** Let consumers process the backlog, or let the messages expire, before migrating. A queue that is empty at migration time uses the fast path and cannot hit this check at all.
3. **Migrate during low-depth periods.** Fewer buffered messages means fewer candidates for mid-migration expiry.

There is no way for the plugin to detect or pre-count per-message TTL, so it cannot warn you before you start. Decide up front whether your publishers set `expiration` and plan accordingly.

> [!NOTE]
> **Queue-level TTL is different, while it is still applied.** A queue-level `x-message-ttl` or `message-ttl` policy **is** visible, and the plugin blocks such queues as unsuitable unless you pass `allow_message_ttl` (which forces `tolerance` to 100% for the whole migration). See the `message_ttl` skip reason in [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md). But note that this visibility disappears the moment you remove the policy: the expiry it already stamped onto buffered messages remains and is invisible to the pre-check, exactly like publisher-set per-message TTL. See [A removed queue-level TTL policy can leave expiring messages behind](#a-removed-queue-level-ttl-policy-can-leave-expiring-messages-behind).

---

## The `message_count_mismatch` error

**Symptom:** a queue fails migration, and the broker log shows:

```
[error] rqm: message count under-delivery exceeds tolerance (0.0%) - Expected: 9118, Actual: 2137, Diff: 6981
```

The per-queue error is reported as the tuple `{message_count_mismatch, Expected, Actual, Diff}` (here `{message_count_mismatch, 9118, 2137, 6981}`), and surfaces in the migration status as:

```
message count mismatch (expected: 9118, actual: 2137, diff: 6981)
```

When this is the first failure in a run, the migration transitions to `rollback_pending` and remaining queues are aborted.

**Reading the numbers:** `Expected` is the source count before transfer, `Actual` is source-plus-destination after, and `Diff` is how many messages went missing. A large `Diff` on a dead-letter or `_error` queue almost always means per-message TTL expiry (above), not data corruption: the source drained to zero and the destination simply received fewer messages than the source originally reported.

**Recovery:**

1. Confirm the cause. If the failing queue is a dead-letter/`_error` queue or its publishers set the `expiration` property, per-message TTL expiry is the likely explanation.
2. Re-run the migration with a `tolerance` high enough to cover the loss, or drain the queue first (see [What to do about it](#what-to-do-about-it)). Idempotency means already-migrated queues are skipped on the re-run.
3. If you cannot explain the missing messages, do **not** raise the tolerance to force it through. Investigate first: an unexplained mismatch is exactly what the 0.0% default is meant to catch.

See also [TROUBLESHOOTING](TROUBLESHOOTING.md) for the failure in the context of other migration errors, and [Rollback and Recovery](TROUBLESHOOTING.md#rollback-and-recovery).
