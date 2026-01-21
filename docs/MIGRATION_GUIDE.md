# Migration Guide

**Last Updated:** January 21, 2026

This guide explains how the RabbitMQ Queue Migration Plugin works, including the migration process, validation checks, and queue eligibility requirements.

---

## Table of Contents

1. [Pre-Migration Validation](#pre-migration-validation)
2. [Two-Phase Migration Process](#two-phase-migration-process)
3. [Connection Handling](#connection-handling-during-migration)
4. [Queue Eligibility](#queue-eligibility)
5. [Automatic Argument Conversion](#automatic-argument-conversion)

---

## Pre-Migration Validation

The plugin performs comprehensive checks before starting migration to ensure safety and success.

### System-Level Checks

These checks always block migration if they fail:

1. **Plugin Requirements**
   - Validates `rabbitmq_shovel` plugin is enabled
   - Validates Khepri is disabled (not compatible with classic queue migration)

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
- All existing client connections are closed gracefully
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

### Preserved Arguments

Arguments that are compatible with quorum queues are preserved:
- `x-message-ttl` - Message TTL
- `x-max-length` - Maximum queue length
- `x-max-length-bytes` - Maximum queue size in bytes
- `x-overflow: drop-head` - Drop oldest messages when limit reached
- `x-overflow: reject-publish` - Reject new messages when limit reached (no DLX)

---

## Related Documentation

- **API Reference:** [HTTP_API](HTTP_API.md)
- **API Examples:** [API_EXAMPLES](API_EXAMPLES.md)
- **Skip Unsuitable Queues:** [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md)
- **Troubleshooting:** [TROUBLESHOOTING](TROUBLESHOOTING.md)
- **Configuration:** [CONFIGURATION](CONFIGURATION.md)
