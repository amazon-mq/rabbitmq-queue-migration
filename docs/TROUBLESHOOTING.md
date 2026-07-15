# Troubleshooting Guide - RabbitMQ Queue Migration Plugin

This guide covers potential issues, error messages, and solutions when using the RabbitMQ Queue Migration Plugin.

---

## Table of Contents

1. [Pre-Migration Issues](#pre-migration-issues)
2. [Plugin Initialization](#plugin-initialization)
3. [Migration Failures](#migration-failures)
4. [Post-Migration Issues](#post-migration-issues)
5. [Performance Issues](#performance-issues)
6. [Rollback and Recovery](#rollback-and-recovery)

---

> **Note:** Users running open-source RabbitMQ 3.13.7 should also review
> [OSS 3.13.7 Known Issues](OSS_313_KNOWN_ISSUES.md) for upstream issues that
> affect migration but cannot be worked around in this plugin.

---

## Pre-Migration Issues

### Compatibility Check Fails

**Symptom:** Compatibility check returns errors before migration can start

**Possible Causes and Solutions:**

#### 1. Shovel Plugin Not Enabled

**Error:** `shovel_plugin_not_enabled`

**Solution:**
```bash
rabbitmq-plugins enable rabbitmq_shovel
rabbitmq-plugins enable rabbitmq_shovel_management
```

Verify plugins are enabled:
```bash
rabbitmq-plugins list | grep shovel
```

---

#### 2. Insufficient Disk Space

**Error:** `insufficient_disk_space`

**Cause:** Not enough free disk space for snapshots and message transfer

**Understanding Disk Space Requirements:**

During migration, disk usage increases because:
1. **Snapshots** - Khepri snapshots created before migration
2. **Destination queues** - New quorum queues created alongside classic queues
3. **Message transfer** - Messages exist in both source and destination during transfer
4. **Concurrent migrations** - Multiple queues migrating simultaneously

**Calculation:**

The plugin calculates required space based on:
```
Required = (total_queue_data × multiplier) + buffer
```

Where:
- `total_queue_data` = sum of message_bytes for all migratable queues
- `multiplier` = disk_usage_peak_multiplier (default: 2.0, configurable)
- `buffer` = min_disk_space_buffer (default: 500MB, configurable)

**Example:**
- Total queue data: 5GB
- Multiplier: 2.0
- Buffer: 500MB
- Required: (5GB × 2.0) + 500MB = **10.5GB**

**Why 2x multiplier:**
During migration, disk temporarily holds both classic queue data AND quorum queue data before garbage collection reclaims the classic segments. The 2x multiplier provides adequate safety margin based on empirical testing.

**Note:** Actual peak usage may be higher (~3-4x) due to:
- Quorum queue write amplification (Raft log overhead)
- Delayed cleanup of source queues
- Filesystem fragmentation
- Multiple concurrent migrations

**Solution:**

**Check current disk usage:**
```bash
# On each node
df -h /var/lib/rabbitmq

# Check queue data size
du -sh /var/lib/rabbitmq/mnesia/rabbit@*/queues
```

**Calculate safe minimum:**
```
Minimum free space = (total queue data × 3) + 2GB buffer
```

**Example:**
- Total queue data: 10GB
- Minimum free: (10GB × 3) + 2GB = **32GB**

**Free up space:**
```bash
# Remove old log files
find /var/log/rabbitmq -name "*.log.*" -mtime +7 -delete

# Check for unused queues
rabbitmqctl list_queues name messages consumers | grep " 0 0$"

# Increase disk capacity if needed
```

**Adjust worker pool** to reduce concurrent disk usage:
```erlang
% In rabbitmq.conf
queue_migration.worker_pool_max = 8  % Reduce from default 32
```

---

#### 3. Cluster Alarms Active

**Error:** `alarms_active`

**Cause:** Memory or disk alarms are triggered

**Solution:**
```bash
# Check cluster alarms (RabbitMQ 3.13 has no `list_alarms` subcommand;
# alarm state appears under the "Alarms" header in the status output)
rabbitmqctl status | grep -A 2 'Alarms'

# Clear memory alarm (if safe)
rabbitmqctl set_vm_memory_high_watermark 0.6

# Clear disk alarm (after freeing space)
rabbitmqctl set_disk_free_limit 2GB
```

---

#### 4. Unsynchronized Mirrored Queues

**Error:** `unsynchronized_queues`

**Cause:** Classic mirrored queues have unsynchronized mirrors

**Solution:**

**Option A:** Wait for synchronization
```bash
# Check sync status
rabbitmqctl list_queues name slave_pids synchronised_slave_pids

# Force sync (may impact performance)
rabbitmqctl sync_queue <queue_name>
```

**Option B:** Use skip mode
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

Unsynchronized queues will be skipped and can be migrated later after synchronization.

---

#### 5. Unsuitable Queues

**Error term:** `{unsuitable_queues, Details}` (returned from the validation chain in `rqm:start/1` and `rqm:validate_migration/1`)

**Variant from the `/check/:vhost` HTTP endpoint:** `{unsuitable_overflow_behavior, Details}` is returned when the only blocker is overflow behavior (`rqm_mgmt.erl` returns this distinct shape with a `queue_name` and `overflow_behavior` field).

**Cause:** One or more queues in the vhost have characteristics that prevent migration. The `Details` map contains a `problematic_queues` list, where each entry has a `reason` field. Common reasons:

- `too_many_queues` - The vhost has more classic queues than the plugin will migrate in a single run (limit configured by `queue_migration.max_queues_for_migration`).
- `unsuitable_overflow` - A queue uses `x-overflow=reject-publish-dlx`, which is not supported in quorum queues. Quorum queues support `drop-head` and `reject-publish` only.
- `too_many_messages` / `too_many_bytes` - A queue exceeds the per-queue message-count or byte-size thresholds for safe migration.

**Solutions:**

**Option A:** Use batch migration to handle a high queue count:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

**Option B:** Use skip mode to skip individual unsuitable queues (the migration proceeds with the suitable ones):

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

**Option C:** For `unsuitable_overflow` specifically, change the queue's overflow behavior before migration. Quorum queues support `drop-head` and `reject-publish`. Either redeclare the queue with the supported value, or set a policy that overrides `x-overflow`.

---

#### 6. Plugin Not Ready On Some Nodes

**Error:** `plugin_not_ready_on_nodes`

**Cause:** The pre-migration validation chain checks every running cluster node and refuses to start the migration unless all nodes confirm the queue-migration plugin is `ready`. A node will be flagged here when its `rqm_init_state` reports `initializing` or `failed`, or when an `erpc:call` to that node returns an error such as `{erpc, timeout}` or `{erpc, noconnection}`.

The error term lists the affected nodes and what each reported, e.g.:

```erlang
{plugin_not_ready_on_nodes,
 [{'rabbit@ip-10-0-1-20', failed},
  {'rabbit@ip-10-0-1-210', {rpc_error, timeout}}]}
```

**Solution:**

For nodes reporting `initializing`, wait up to 5 minutes for the plugin's table-setup retry budget to complete and try again.

For nodes reporting `failed`, recover by running on each affected node:

```bash
rabbitmq-plugins disable rabbitmq_queue_migration
rabbitmq-plugins enable rabbitmq_queue_migration
```

For nodes reporting `{rpc_error, _}`, investigate cluster connectivity and node health before retrying. Errors of this shape commonly indicate a partial network partition or an overloaded node.

See [Plugin Initialization](#plugin-initialization) for the full lifecycle of `initializing` and `failed` states.

---

### Network Partition Detected

**Error:** `partitions_detected`

**Cause:** RabbitMQ has detected a network partition between cluster nodes.

**Solution:**

```bash
# Check partition state
rabbitmqctl cluster_status
```

How to recover depends on your cluster's `cluster_partition_handling` strategy and which side of the partition you trust. See the [RabbitMQ partitions documentation](https://www.rabbitmq.com/docs/partitions) for resolution procedures appropriate to each strategy. **Do not attempt migration during partition** - resolve the partition first.

---

## Plugin Initialization

### Plugin returns 503 from every endpoint

**Symptom:** Every request to `/api/queue-migration/*` returns `503 Service Unavailable` with a JSON body whose `status` field is `initializing` or `failed`.

**Why this happens:** Starting in plugin version 1.1.0, the plugin's Mnesia table setup runs asynchronously after the broker starts so that table-setup failures cannot abort broker boot. Until the tables are ready, the plugin's HTTP routes return 503. See [HTTP API: Plugin Initialization States](HTTP_API.md#plugin-initialization-states) for the response contract.

#### While `initializing`

The plugin is still attempting to create and load its Mnesia tables. The retry budget is 10 attempts of 30 seconds each, totalling 5 minutes. No operator action is needed; subsequent requests will succeed once the plugin transitions to `ready`.

The most common reasons for the plugin to spend time in `initializing`:

1. **Cluster recovery from a full cluster reboot.** When peer nodes are not yet up, `rabbit_table:wait/1` blocks until peer Mnesia replicas come online. As nodes come up one at a time, the plugin's tables on this node become reachable and the plugin transitions to `ready`.
2. **Slow disc IO during peer Mnesia replication.** Large Mnesia datasets take longer to load.

#### After `failed`

The plugin exhausted its retry budget without ever loading its tables. Common causes:

1. **The broker is using Khepri instead of Mnesia.** This plugin is incompatible with Khepri. Confirm the metadata store with `rabbitmq-diagnostics status` and check the `Metadata Store` field. If the broker is on Khepri, the plugin should be disabled.
2. **Peer Mnesia replicas are permanently unreachable.** A node was forgotten from the cluster but its hostname remains in this node's Mnesia schema, or DNS for cluster peers is broken. Investigate cluster membership with `rabbitmqctl cluster_status`.
3. **Mnesia schema is in an inconsistent state.** Examine the broker logs around the plugin start time for `[error] rqm: schema setup attempt N/10 failed: ...` entries. The error term is the exact `rabbit_table:create/2` or `rabbit_table:wait/1` failure.

**Recovery:** Once the underlying issue is resolved (peer replicas are reachable, schema is consistent, etc.), retry initialisation by running:

```bash
rabbitmq-plugins disable rabbitmq_queue_migration
rabbitmq-plugins enable rabbitmq_queue_migration
```

on each broker node. The plugin restarts its state machine from `initializing` and runs the same retry loop. See the [README's Mnesia-Only Compatibility section](../README.md#%EF%B8%8F-mnesia-only-compatibility) for the full lifecycle.

---

## Migration Failures

### Migration Stuck "In Progress"

**Symptom:** Migration shows "in_progress" but no queues completing

**Diagnosis:**
```bash
# Check migration status
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Check broker logs
tail -f /var/log/rabbitmq/rabbit@<node>.log | grep rqm

# Check shovel status
curl -u guest:guest http://localhost:15672/api/shovels
```

**Possible Causes:**

#### 1. Shovel Creation Failed

**Log Message:** `Failed to create shovel: noproc`

**Cause:** A race condition in `mirrored_supervisor:child/2` causes a `badmatch` exception during shovel cleanup. If this occurs frequently enough, the shovel supervisor exceeds its restart intensity and stops, preventing new shovels from being created.

**Note:** This is fixed in RabbitMQ 4.1.x and later via [rabbitmq/rabbitmq-server#15229](https://github.com/rabbitmq/rabbitmq-server/pull/15229). On RabbitMQ 3.13.x this fix must be backported manually. Amazon MQ for RabbitMQ includes this fix.

**Solution:** Plugin has automatic retry (10 attempts). If still failing:
```bash
# Restart shovel plugin
rabbitmq-plugins disable rabbitmq_shovel
rabbitmq-plugins enable rabbitmq_shovel
```

#### 2. Worker Process Crashed

**Log Message:** `Worker process terminated`

**Solution:**
- Check logs for crash reason
- May need to interrupt and restart migration
- Report issue if reproducible

#### 3. Network Issues

**Symptom:** Shovels created but no message transfer

**Solution:**
- Check network connectivity between nodes
- Verify AMQP ports (5672) are accessible
- Check firewall rules

---

### Queue Migration Failed

**Status:** `failed` in queue status

**Cause:** Individual queue migration encountered an error

**Diagnosis:**
```bash
# Get queue details
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Check error field for specific queue
```

**Possible Failure Reasons:**

#### 1. Message Count Mismatch

**Error term:** `{message_count_mismatch, Expected, Actual, Diff}`

**Log line:**
```
[error] rqm: message count under-delivery exceeds tolerance (0.0%) - Expected: 9118, Actual: 2137, Diff: 6981
```

**Status text:** `message count mismatch (expected: 9118, actual: 2137, diff: 6981)`

**Cause:** Fewer (or more) messages ended up in the destination queue than the source held before transfer, and the difference exceeded the configured tolerance. By default under-delivery tolerance is 0.0%, so any missing message fails the migration. The most common cause of a large under-delivery is per-message TTL expiry on a dead-letter or `_error` queue: expired messages are counted in the source total but dropped as the shovel drains the queue.

**Solution:** See [Message Count Verification and Message Loss](MESSAGE_LOSS_AND_VERIFICATION.md#the-message_count_mismatch-error) for how to read the numbers, confirm the cause, and re-run with an appropriate `tolerance` (or drain the queue first). Do not raise the tolerance to force a migration through when you cannot explain the missing messages.

#### 2. Shovel Transfer Failed

**Cause:** Shovel encountered error during message transfer

**Solution:**
- Check shovel logs for specific error
- Verify destination queue is healthy
- May need to interrupt and retry migration

---

### Migration Interrupted

**Symptom:** Migration status shows "interrupted"

**Cause:** User manually interrupted migration via the interrupt endpoint

**What Happens:**
- Queues actively migrating complete normally
- Queues not yet started are marked "skipped" with reason "interrupted"
- Original classic queues remain for skipped queues
- Completed queues remain as quorum queues

**Recovery:**
```bash
# Start new migration for remaining queues
# Idempotency ensures already-migrated queues are skipped
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

---

## Post-Migration Issues

### Queue Attributes (DLX, max-length) No Longer In Effect

**Symptom:** After a successful migration, attributes such as `dead-letter-exchange`, `max-length`, or `message-ttl` that were in effect on a queue via a policy are no longer applied to the migrated (now quorum) queue. The queue's effective policy is empty or missing attributes it had as a classic queue.

**Cause:** RabbitMQ matches policies to queues by both pattern and queue type, and a policy applies all-or-nothing. A policy scoped `apply-to: classic_queues` stops matching once the queue is quorum. A policy scoped `apply-to: queues` (or `quorum_queues`) that contains even one attribute quorum queues do not support (for example `ha-mode`) becomes inapplicable in full, dropping its supported attributes too.

**Resolution:** Define quorum-compatible policies scoped `apply-to: quorum_queues` (or `apply-to: queues`) containing only attributes supported by quorum queues, and remove classic-only attributes such as HA settings. See [Policy Applicability After Migration](MIGRATION_GUIDE.md#policy-applicability-after-migration) in the Migration Guide for the full behavior, the list of unsupported attributes, and effective-policy examples.

### Queue Redeclaration Fails With 406 PRECONDITION_FAILED

**Symptom:** After a successful migration, a client fails to redeclare a migrated queue with:

```
406 PRECONDITION_FAILED - inequivalent arg 'x-queue-type' for queue '<name>' in vhost '<vhost>': received none but current is the value 'quorum' of type 'longstr'
```

The connection and channel open normally; only the queue declaration fails.

**Cause:** The queue is now `quorum`, but the client declares it without an explicit `x-queue-type` and the virtual host has no default queue type set, so the declaration carries no type and fails the equivalence check against the existing `quorum` queue.

**Resolution:** Set the virtual host default queue type to `quorum` (via the `set_default_queue_type` migration option, `rabbitmqctl update_vhost_metadata`, or the management HTTP API). See [Client Redeclaration After Migration](MIGRATION_GUIDE.md#client-redeclaration-after-migration) in the Migration Guide for the full behavior matrix and recommendations.

---

## Performance Issues

### Migration Taking Longer Than Expected

**Symptom:** Migration duration is longer than desired

**Solution:**

Use batch migration to control migration scope:
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

This allows you to:
- Migrate in smaller increments
- Spread migration across multiple maintenance windows
- Reduce resource pressure on the cluster

---

### High Memory Usage

**Symptom:** Memory alarms triggered during migration

**Solution:**

Migrate in smaller batches to reduce concurrent resource usage:
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 10}' \
  http://localhost:15672/api/queue-migration/start
```

If memory alarms persist, increase the memory limit:
```erlang
% In rabbitmq.conf
vm_memory_high_watermark.relative = 0.6
```

---

### High Disk I/O

**Symptom:** Slow migration with high disk wait times

**Cause:** Quorum queues writing to disk, snapshots being created

**Recommendations:**
- Use SSD storage for RabbitMQ data
- Ensure sufficient disk I/O capacity
- Migrate during low-traffic periods
- Use batch migration to reduce concurrent disk operations

---

## Rollback and Recovery

**Note:** Migration failures requiring rollback are rare. The plugin's comprehensive pre-migration validation prevents most issues before migration starts.

### After Failed Migration

**Scenario:** Migration failed with status `rollback_pending` (rare edge case)

**What Happens:**
- Migration status set to `rollback_pending`
- Failed queue marked with error details
- Shovels cleaned up automatically
- Destination quorum queues remain (not automatically deleted)
- Classic queues remain with original data

**Current State:**
- Automatic rollback is not implemented in this plugin
- Manual intervention required to clean up

**Manual Recovery:**

Since automatic rollback is not implemented in this plugin, the safest recovery method is to restore from snapshots:

1. **Stop RabbitMQ on all nodes**
2. **Restore from snapshots** (EBS or tar - see [Snapshots Guide](SNAPSHOTS.md))
3. **Restart RabbitMQ cluster**
4. **Fix the issue that caused failure**
5. **Start new migration when ready**

**Why snapshot restore is recommended:**
- Migration state is complex (some queues completed, some failed at different phases)
- Failed queues may have temporary queues with `tmp_<timestamp>_` prefix
- Classic queues may have been deleted during phase 1
- Manual cleanup is error-prone and risks data loss

**Note:** Automatic rollback is a feature of Amazon MQ for RabbitMQ and is not planned for this open-source plugin. For tar snapshot restoration, see `priv/tools/restore_snapshot_test.sh` as a starting point.

---

### Partial Migration Recovery

**Scenario:** Some queues migrated successfully, some failed

**Status:** Migration shows mix of "completed" and "failed" queues

**Recovery:**

**Option 1: Keep successful migrations, continue with remaining queues**

If only a few queues failed:
1. Investigate the failure cause (check error field in queue status)
2. Fix the underlying issue
3. Start a new migration - idempotency ensures already-migrated queues are skipped

**Note:** Failed queues may be in inconsistent state (classic queue deleted, temporary quorum queue exists). Starting a new migration will attempt to migrate these queues again.

**Option 2: Full rollback to pre-migration state**

Restore from snapshots (only reliable method):
1. Stop RabbitMQ on all nodes
2. Restore from snapshots (EBS or tar)
3. Restart RabbitMQ cluster

**Warning:** Manual cleanup of failed queues is not recommended due to complex migration state.

---

## Getting Help

### Enable Debug Logging

```erlang
% In rabbitmq.conf
log.console.level = debug
```

Or dynamically:
```bash
rabbitmqctl set_log_level debug
```

**Note:** Debug logging is very verbose. Use only for troubleshooting.

---

### Collect Diagnostic Information

When reporting issues, include:

1. **Migration Status:**
```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>
```

2. **Broker Logs:**
```bash
tail -1000 /var/log/rabbitmq/rabbit@<node>.log | grep rqm
```

3. **Cluster Status:**
```bash
rabbitmqctl cluster_status
rabbitmqctl status | grep -A 2 'Alarms'
```

4. **Queue Information:**
```bash
rabbitmqctl list_queues name type messages
```

5. **Shovel Status:**
```bash
curl -u guest:guest http://localhost:15672/api/shovels
```

6. **Configuration:**
```bash
rabbitmqctl environment | grep queue_migration
```

---

## Additional Resources

- **HTTP API Documentation:** HTTP_API.md
- **Architecture Details:** ../AGENTS.md
- **EC2 Setup Guide:** EC2_SETUP.md
- **Integration Testing:** INTEGRATION_TESTING.md
