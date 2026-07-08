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

> **Note:** If you are running open-source RabbitMQ 3.13.7, see
> [OSS 3.13.7 Known Issues](OSS_313_KNOWN_ISSUES.md) for upstream issues that
> can affect migration.

---

## Pre-Migration Validation

The plugin performs comprehensive checks before starting migration to ensure safety and success.

### System-Level Checks

These checks always block migration if they fail:

1. **Plugin Requirements**
   - Validates `rabbitmq_shovel` plugin is enabled
   - Validates Khepri is disabled (not compatible with classic queue migration)
   - Validates `rabbitmq_queue_migration` plugin reports `ready` on every running cluster node (the plugin's async init must have finished on each node before migration can proceed)

2. **Configuration**
   - Checks `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration` is enabled
   - Required for queue redeclaration during migration

3. **Queue Leader Balance**
   - Ensures queue leaders are balanced across cluster nodes
   - Prevents overloading specific nodes during migration

4. **Disk Space**
   - Estimates required disk space based on queue data size
   - Verifies sufficient free space available on all nodes
   - See [TROUBLESHOOTING](TROUBLESHOOTING.md) for disk space calculation details

5. **System Health**
   - Checks for active memory or disk alarms
   - Validates memory usage is below threshold

6. **Snapshot Availability**
   - Verifies no concurrent EBS snapshots in progress
   - Prevents snapshot conflicts

7. **Cluster Health**
   - Validates no network partitions exist
   - Confirms all cluster nodes are running

### Queue-Level Checks

These checks can be skipped with the `skip_unsuitable_queues` option:

1. **Queue Synchronization**
   - Verifies all mirrored classic queues are fully synchronized
   - Unsynchronized queues can be skipped and migrated later

2. **Queue Suitability**
   - Confirms queues don't have unsuitable arguments
   - Unsuitable queues can be skipped and fixed later

**Skip Mode:**

When `skip_unsuitable_queues` is enabled:
- Queues failing queue-level checks are marked as "skipped"
- Migration proceeds with suitable queues
- Skipped queues remain as classic queues
- Can be migrated in subsequent runs after fixing issues

See [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md) for complete guide on using skip mode.

---

## Two-Phase Migration Process

The plugin uses a two-phase approach to safely migrate queues while preserving messages and bindings.

### Phase 1: Classic → Temporary Quorum

1. **Create temporary quorum queue**
   - Name format: `tmp_<timestamp>_<original_name>`
   - Timestamp from migration ID ensures uniqueness
   - Prevents collision with user queues

2. **Copy bindings**
   - All bindings from classic queue copied to temporary queue
   - Preserves routing configuration

3. **Migrate messages**
   - Shovel transfers messages from classic to temporary queue
   - Messages transferred one-by-one with confirmations
   - Progress tracked and reported

4. **Delete classic queue**
   - Original classic queue deleted after successful transfer
   - Frees up disk space

### Phase 2: Temporary → Final Quorum

1. **Create final quorum queue**
   - Uses original queue name
   - No name conflict since classic queue was deleted

2. **Copy bindings**
   - All bindings from temporary queue copied to final queue
   - Ensures routing remains intact

3. **Migrate messages**
   - Shovel transfers messages from temporary to final queue
   - Verifies message counts match expectations

4. **Delete temporary queue**
   - Temporary queue deleted after successful transfer
   - Migration complete

### Fast Path for Empty Queues

Queues with zero messages skip the two-phase process:
- Create final quorum queue directly
- Copy bindings
- Delete classic queue
- Significantly faster (no message transfer needed)

---

## Connection Handling During Migration

### Pre-Migration Preparation

**Listener Suspension:**
- Non-HTTP listeners (AMQP, MQTT, STOMP) are suspended broker-wide
- All existing client connections are closed
- HTTP API remains available for monitoring

**Why Suspend Listeners:**
- Prevents new connections during migration
- Ensures no active publishers/consumers on migrating queues
- Guarantees accurate message counts

### During Migration

**Client Impact:**
- Clients cannot connect to the broker (non-HTTP protocols)
- Existing connections are closed
- HTTP API remains accessible for monitoring migration progress

**Monitoring:**
- Use HTTP API to check migration status
- View per-queue progress
- Identify any issues

### Post-Migration

**Automatic Restoration:**
- All listeners are restored automatically
- Clients can reconnect to the broker
- Migrated queues are now quorum queues

**Queue State:**
- All messages preserved
- All bindings intact
- Queue type changed from classic to quorum

### Important Considerations

**Broker-Wide Impact:**
The connection suspension affects the entire broker, not just the vhost being migrated. This means:
- All vhosts are affected
- All client connections are closed
- Plan migration windows accordingly
- Consider maintenance windows for production systems

**Reconnection:**
- Clients with automatic reconnection will reconnect after migration
- Applications should handle connection loss gracefully
- Test reconnection behavior before production migration

---

## Queue Eligibility

A queue is eligible for migration if it meets all these criteria:

### Required Characteristics

1. **Queue Type**
   - Must be `rabbit_classic_queue`
   - Quorum queues are automatically filtered out (idempotency)

2. **HA Policy**
   - Must have HA (High Availability) policy applied
   - Queue must be mirrored across cluster nodes
   - Non-mirrored classic queues are not eligible

3. **Not Exclusive**
   - Queue must not be exclusive
   - Exclusive queues are tied to specific connections

### Checking Eligibility

Use the compatibility check endpoint:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2F
```

This returns:
- Total queues in vhost
- Compatible queues (eligible for migration)
- Unsuitable queues (with reasons)
- System check results

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

**`x-overflow: reject-publish-dlx`**

This overflow policy is **not compatible** with quorum queues and will cause the queue to be marked as unsuitable.

**Why Unsuitable:**
- Quorum queues support `drop-head` and `reject-publish` overflow policies
- `reject-publish` in quorum queues does NOT provide dead lettering
- `reject-publish-dlx` behavior cannot be replicated in quorum queues

**Solution:**
- Change overflow policy before migration
- Or use `skip_unsuitable_queues` mode to skip these queues
- Consider alternative dead lettering approaches for quorum queues

**`x-message-ttl` (queue-level TTL)**

A queue with a queue-level message TTL (`x-message-ttl` argument or `message-ttl` policy) is marked as unsuitable.

**Why Unsuitable:**
- Messages can expire and be removed during the migration window
- Expired messages cause the source-vs-destination message count check to fail verification

**Solution:**
- Remove the `x-message-ttl` argument or `message-ttl` policy before migration
- Use the `tolerance` migration option to allow a per-queue percentage difference (see [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md))
- Or use `skip_unsuitable_queues` mode to skip these queues and migrate them later

**`x-expires` (queue expiry)**

A queue with `x-expires` argument or `expires` policy is marked as unsuitable.

**Why Unsuitable:**
- The queue itself can expire and be deleted during migration
- A queue that disappears mid-migration causes the migration to fail for that queue

**Solution:**
- Remove the `x-expires` argument or `expires` policy before migration
- Or use `skip_unsuitable_queues` mode to skip these queues

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
