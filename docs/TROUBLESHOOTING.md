# Troubleshooting Guide - RabbitMQ Queue Migration Plugin

**Last Updated:** January 21, 2026

This guide covers potential issues, error messages, and solutions when using the RabbitMQ Queue Migration Plugin.

---

## Table of Contents

1. [Pre-Migration Issues](#pre-migration-issues)
2. [Migration Failures](#migration-failures)
3. [Performance Issues](#performance-issues)
4. [Rollback and Recovery](#rollback-and-recovery)

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

**Error:** `cluster_alarms_active`

**Cause:** Memory or disk alarms are triggered

**Solution:**
```bash
# Check alarms
rabbitmqctl list_alarms

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

#### 5. Too Many Queues to Migrate

**Error:** `too_many_queues`

**Cause:** Too many queues in the vhost to migrate safely at once

**Solution:**

**Option A:** Use batch migration
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

**Option B:** Use skip mode to handle automatically
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

Queues exceeding the safe migration limit will be skipped and can be migrated in subsequent runs.

---

#### 6. Unsuitable Queue Arguments

**Error:** `unsuitable_overflow`

**Cause:** Queue has `overflow: reject-publish-dlx` which is incompatible with quorum queues

**Solution:**

**Option A:** Change queue overflow policy before migration
```bash
# Delete and recreate queue with different overflow policy
# Or use policy to override
```

**Option B:** Use skip mode to skip these queues

---

### Network Partition Detected

**Error:** `network_partition_detected`

**Cause:** Cluster has network partition

**Solution:**
```bash
# Check partition status
rabbitmqctl cluster_status

# Resolve partition (choose appropriate strategy)
rabbitmqctl forget_cluster_node <node>
```

**Do not attempt migration during partition** - resolve partition first.

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

**Cause:** Shovel supervisor not available

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

#### 1. Shovel Transfer Failed

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
- Completed queues remain as quorum queues

**Recovery:**
```bash
# Start new migration for remaining queues
# Idempotency ensures already-migrated queues are skipped
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

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
- Automatic rollback is not implemented
- Manual intervention required to clean up

**Manual Recovery Steps:**

1. **Verify classic queues still have data:**
```bash
rabbitmqctl list_queues name type messages | grep classic
```

2. **Delete destination quorum queues manually:**
```bash
# For each failed queue, delete the corresponding quorum queue
rabbitmqctl delete_queue <queue_name>.quorum
```

3. **Verify bindings and listeners on classic queues:**
```bash
rabbitmqctl list_bindings
rabbitmqctl list_consumers
```

4. **Fix the issue that caused failure** (disk space, configuration, etc.)

5. **Start new migration when ready**

**Note:** Automatic rollback is planned for future release but not currently implemented.

---

### Partial Migration Recovery

**Scenario:** Some queues migrated successfully, some failed

**Status:** Migration shows mix of "completed" and "failed" queues

**Recovery:**
```bash
# Option 1: Keep successful migrations, fix failed queues
# Fix issues with failed queues, then start new migration
# Idempotency ensures already-migrated queues are skipped

# Option 2: Rollback everything (not currently supported)
# Would need manual intervention to delete quorum queues
# and restore traffic to classic queues
```

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
rabbitmqctl list_alarms
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
