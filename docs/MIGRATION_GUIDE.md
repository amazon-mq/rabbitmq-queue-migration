# Migration Guide

This guide explains how the RabbitMQ Queue Migration Plugin works, including the migration process, validation checks, and queue eligibility requirements.

---

## Table of Contents

1. [Pre-Migration Validation](#pre-migration-validation)
2. [Two-Phase Migration Process](#two-phase-migration-process)
3. [Connection Handling](#connection-handling-during-migration)
4. [Queue Eligibility](#queue-eligibility)
5. [Automatic Argument Conversion](#automatic-argument-conversion)
6. [Policy Applicability After Migration](#policy-applicability-after-migration)
7. [Client Redeclaration After Migration](#client-redeclaration-after-migration)

---

> [!NOTE]
> If you are running open-source RabbitMQ 3.13.7, see [OSS 3.13.7 Known Issues](OSS_313_KNOWN_ISSUES.md) for upstream issues that can affect migration.

---

## Pre-Migration Validation

The plugin performs comprehensive checks before starting migration to ensure safety and success. System-level checks always block migration if they fail. Queue-level checks apply per queue and can be skipped with the `skip_unsuitable_queues` option.

### System-Level Checks

These checks apply to the cluster as a whole and always block migration if they fail:

| Check | What it verifies |
|-------|------------------|
| Plugin Requirements | `rabbitmq_shovel` is enabled, Khepri is disabled (not compatible with classic queue migration), and `rabbitmq_queue_migration` reports `ready` on every running cluster node (its async init must have finished on each node before migration can proceed). |
| Configuration | `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration` is enabled, which is required for queue redeclaration during migration. |
| Queue Leader Balance | Queue leaders are balanced across cluster nodes, so no single node is overloaded during migration. |
| Disk Space | Enough free space exists on all nodes for the estimated migration footprint; see [TROUBLESHOOTING](TROUBLESHOOTING.md) for the calculation. |
| System Health | No active memory or disk alarms, and memory usage is below threshold. |
| Snapshot Availability | No concurrent EBS snapshots are in progress, avoiding snapshot conflicts. |
| Cluster Health | No network partitions exist and all cluster nodes are running. |

### Queue-Level Checks

These checks apply per queue and can be skipped with the `skip_unsuitable_queues` option:

| Check | What it verifies |
|-------|------------------|
| Queue Synchronization | All mirrors of the classic queue are fully synchronized. Unsynchronized queues can be skipped and migrated later. |
| Queue Suitability | The queue has no unsuitable arguments (see [Automatic Argument Conversion](#automatic-argument-conversion)). Unsuitable queues can be skipped and fixed later. |

When `skip_unsuitable_queues` is enabled, queues that fail a queue-level check are marked "skipped" and remain classic queues while migration proceeds with the suitable ones. Skipped queues can be migrated in a later run once their issues are fixed. See [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md) for the complete guide to skip mode.

---

## Two-Phase Migration Process

The plugin uses a two-phase approach to safely migrate queues while preserving messages and bindings.

### Phase 1: Classic → Temporary Quorum

The plugin creates a temporary quorum queue named `tmp_<timestamp>_<original_name>`, where the timestamp comes from the migration ID and guarantees the name cannot collide with a user queue. It copies all of the classic queue's bindings to the temporary queue to preserve routing, then uses a shovel to transfer messages one by one with confirmations, tracking and reporting progress. Once the transfer succeeds, the original classic queue is deleted, freeing its disk space and its name.

### Phase 2: Temporary → Final Quorum

The plugin creates the final quorum queue under the original queue name, which is now free because the classic queue was deleted in phase 1. It copies the bindings from the temporary queue so routing remains intact, shovels the messages across while verifying the counts match expectations, and deletes the temporary queue once the transfer succeeds. The migration is then complete.

### Fast Path for Empty Queues

A queue with zero messages skips the two-phase process entirely: the plugin creates the final quorum queue directly, copies its bindings, and deletes the classic queue. With no messages to transfer, this is significantly faster.

---

## Connection Handling During Migration

When a migration starts, the plugin suspends all non-HTTP listeners (AMQP, MQTT, STOMP) and closes existing client connections. This is broker-wide, not limited to the vhost being migrated: every vhost is affected. Suspending listeners keeps publishers and consumers off the migrating queues so that message counts stay accurate. The HTTP API stays available throughout so you can monitor progress.

When the migration ends, all listeners are restored automatically and clients can reconnect. Messages and bindings are preserved; the only change is that the migrated queues are now quorum queues.

Because the entire broker goes offline to non-HTTP clients, plan a maintenance window. Clients with automatic reconnection will recover on their own once listeners are restored, but test that behavior before running a production migration.

---

## Queue Eligibility

A queue is eligible for migration only if it meets all of these criteria:

| Criterion | Requirement |
|-----------|-------------|
| Queue type | Must be a classic queue (`rabbit_classic_queue`). Existing quorum queues are filtered out automatically, which keeps migration idempotent. |
| HA policy | Must have a high-availability policy applied so the queue is mirrored across cluster nodes. Non-mirrored classic queues are not eligible. |
| Not exclusive | Must not be exclusive, because exclusive queues are tied to the lifetime of a specific connection. |

### Checking Eligibility

Use the compatibility check endpoint:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2F
```

This returns the total queues in the vhost, the compatible queues eligible for migration, the unsuitable queues with their reasons, and the system check results.

---

## Automatic Argument Conversion

The plugin automatically converts or removes queue arguments during migration to ensure compatibility with quorum queues.

### Argument Conversion Table

| Classic Queue Argument | Quorum Queue Equivalent | Action |
|------------------------|-------------------------|--------|
| `x-queue-type: classic` | `x-queue-type: quorum` | Converted |
| `x-max-priority` | *removed* | Not supported in quorum queues |
| `x-queue-mode` | *removed* | Lazy mode doesn't apply to quorum queues |
| `x-queue-master-locator` | *removed* | Classic queue specific |
| `x-queue-version` | *removed* | Classic queue specific |

### Unsuitable Arguments

Three queue arguments have no safe quorum-queue equivalent, so a queue that uses any of them is marked unsuitable. In every case you can either fix the queue before migration or use `skip_unsuitable_queues` mode to migrate the rest now and come back to it later.

| Argument | Why it is unsuitable | What to do |
|----------|----------------------|------------|
| `x-overflow: reject-publish-dlx` | Quorum queues support only `drop-head` and `reject-publish` overflow, and `reject-publish` provides no dead lettering, so this policy cannot be replicated. | Change the overflow policy (and rethink dead lettering) before migration, or skip the queue. |
| `x-message-ttl` (queue-level TTL) | Messages can expire during the migration window, and expired messages fail the source-vs-destination count check. | Migrate with `allow_message_ttl`, which forces `tolerance` to 100% migration-wide and keeps `x-message-ttl` on the quorum queue (see [HTTP_API](HTTP_API.md)); set a `tolerance` sized to the expected loss; or skip the queue. Removing the policy alone is **not** sufficient: the expiry it already stamped onto buffered messages survives removal and still expires mid-migration, so drain or let the backlog expire first. See [Message Loss and Verification](MESSAGE_LOSS_AND_VERIFICATION.md#a-removed-queue-level-ttl-policy-can-leave-expiring-messages-behind). |
| `x-expires` (queue expiry) | The queue itself can expire and be deleted mid-migration, failing the migration for that queue. | Remove the `x-expires` argument or `expires` policy, or skip the queue. |

> [!NOTE]
> A *queue-level* TTL (the `x-message-ttl` row above) is detected and blocked only while the policy or argument is still applied. Two related cases stay invisible to the plugin: TTL set by publishers on individual messages (the `expiration` property), and the absolute expiry a queue-level TTL already stamped onto buffered messages, which survives removal of the policy. Both are common causes of a failed migration; see [Message Loss and Verification](MESSAGE_LOSS_AND_VERIFICATION.md).

### Preserved Arguments

Arguments that are compatible with quorum queues are preserved:
- `x-max-length` - Maximum queue length
- `x-max-length-bytes` - Maximum queue size in bytes
- `x-overflow: drop-head` - Drop oldest messages when limit reached
- `x-overflow: reject-publish` - Reject new messages when limit reached (no DLX)

---

## Policy Applicability After Migration

The migration plugin does not create, modify, or delete policies; it only reads them. However, a queue's *effective* policy can change after migration, because RabbitMQ matches policies to queues by both pattern and queue type, and a policy applies all-or-nothing. As a result, attributes such as `dead-letter-exchange` or `max-length` that were in effect on a classic queue may silently stop applying once the queue is quorum.

Two behaviors combine to cause this.

### Type Scoping

A policy's `apply-to` scope is matched against the queue's type:

- `apply-to: classic_queues` matches only classic queues. The moment a queue becomes `quorum`, it no longer matches, and any attributes defined only in that policy stop applying. The policy itself is unchanged; the queue simply no longer matches it.
- `apply-to: queues` matches all queue types, including quorum, so it continues to apply after migration (subject to the all-or-none rule below).
- `apply-to: quorum_queues` matches only quorum queues.

### All-or-None Applicability

A policy is applicable to a queue only if *every* attribute in its definition is supported by that queue's type (see `rabbit_queue_type:is_policy_applicable/2`). If a policy that otherwise matches a quorum queue, including an `apply-to: queues` policy, contains even one attribute that quorum queues do not support, the entire policy becomes inapplicable, and all of its attributes, including supported ones like `dead-letter-exchange`, are dropped from the queue's effective policy.

Quorum queues do not support these policy attributes:

`max-priority`, `queue-mode`, `single-active-consumer`, `ha-mode`, `ha-params`, `ha-sync-mode`, `ha-promote-on-shutdown`, `ha-promote-on-failure`, `queue-master-locator`, `max-age`, `stream-max-segment-size-bytes`, `initial-cluster-size`.

So a policy that worked for a classic queue may apply nothing at all to the same queue once it is quorum: a `classic_queues`-scoped policy no longer matches by type, and a `queues`-scoped (or `quorum_queues`-scoped) policy that contains even one unsupported attribute, such as an HA attribute, is rejected in full.

### Effective Policy Examples

The following shows the effective policy on a queue named `orders` after it has been migrated to quorum, for policies that all match the queue by pattern:

| Policy definition | `apply-to` | Effective on the migrated (quorum) queue |
|-------------------|------------|-------------------------------------------|
| `{"max-length": 1000}` | `classic_queues` | Not applied (no longer matches by type) |
| `{"max-length": 1000}` | `queues` | Applied: `max-length` in effect |
| `{"max-length": 1000, "ha-mode": "all"}` | `queues` | Not applied: the unsupported `ha-mode` drops the whole policy, including `max-length` |
| `{"max-length": 1000}` | `quorum_queues` | Applied: `max-length` in effect |

### Recommendation

To keep attributes such as `dead-letter-exchange` and `max-length` in effect on quorum queues, define quorum-compatible policies scoped `apply-to: quorum_queues` (or `apply-to: queues`) that contain only attributes supported by quorum queues. Remove HA and other classic-only attributes from any policy that must continue to apply after migration.

Manage these policies in the same place they are defined today (for example application code or infrastructure as code), so they remain the source of truth and do not drift. The plugin deliberately does not generate a companion policy at migration time, because a generated policy cannot stay in sync with externally managed ones.

---

## Client Redeclaration After Migration

After a classic queue is migrated, it keeps its name but its type is now `quorum`, and it carries `x-queue-type: quorum` in its arguments. When a client redeclares that queue, RabbitMQ applies its queue equivalence checks, comparing the arguments the client sends against the arguments of the existing queue. The outcome depends on what the client sends for `x-queue-type`.

### Clients That Omit `x-queue-type`

A client that declares queues **without** an explicit `x-queue-type` argument relies on the virtual host's default queue type. What happens after migration depends on whether a vhost default queue type is set:

- **No vhost default queue type:** the declaration carries no type, and RabbitMQ rejects it because the requested (absent) type is not equivalent to the existing `quorum` type. The redeclaration fails with:

  ```
  406 PRECONDITION_FAILED - inequivalent arg 'x-queue-type' for queue '<name>' in vhost '<vhost>': received none but current is the value 'quorum' of type 'longstr'
  ```

- **Vhost default queue type set to `quorum`:** the broker injects `x-queue-type: quorum` into the declaration, which matches the existing queue, and the redeclaration succeeds.

The connection and channel open successfully in both cases; the failure, when it occurs, is on the queue redeclaration, not on connect.

**Recommendation:** set the virtual host default queue type to `quorum` as part of the migration workflow so that clients which omit `x-queue-type` continue to work after migration. The start endpoint accepts a `set_default_queue_type` option that does this for you when the migration completes successfully; see [HTTP_API](HTTP_API.md). You can also set it independently with `rabbitmqctl update_vhost_metadata` or the management HTTP API.

### Clients That Declare `x-queue-type: classic`

A client that explicitly redeclares the migrated queue as `x-queue-type: classic` is covered by the `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration` setting, which the plugin requires to be enabled before migration (see [Pre-Migration Validation](#pre-migration-validation)). With that setting enabled, redeclaring a migrated queue as `classic` succeeds instead of failing the equivalence check.

Note that this relaxed setting applies only when a client explicitly declares `classic`. It does **not** cover clients that omit `x-queue-type` entirely; those are governed by the vhost default queue type as described above.

### Behavior Summary

For a migrated queue (now `quorum`), redeclaration behaves as follows:

| Client sends | No vhost default | Vhost default `quorum` |
|--------------|------------------|------------------------|
| no `x-queue-type` | `406 PRECONDITION_FAILED` | succeeds |
| `x-queue-type: quorum` | succeeds | succeeds |
| `x-queue-type: classic` | succeeds (relaxed checks) | succeeds (relaxed checks) |

---

## Related Documentation

- **API Reference:** [HTTP_API](HTTP_API.md)
- **API Examples:** [API_EXAMPLES](API_EXAMPLES.md)
- **Skip Unsuitable Queues:** [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md)
- **Troubleshooting:** [TROUBLESHOOTING](TROUBLESHOOTING.md)
- **Configuration:** [CONFIGURATION](CONFIGURATION.md)
