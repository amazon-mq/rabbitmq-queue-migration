# Configuration Reference

**Last Updated:** January 21, 2026

Complete reference for all configuration parameters in the RabbitMQ Queue Migration Plugin.

---

## Configuration File

All parameters are configured in `rabbitmq.conf` using the `queue_migration.` prefix.

**Example:**
```erlang
queue_migration.worker_pool_max = 24
queue_migration.shovel_prefetch_count = 256
```

---

## Worker Pool Configuration

### `worker_pool_max`

**Type:** Positive integer  
**Default:** 32  
**Range:** 1-32  
**Description:** Maximum number of concurrent queue migrations per node

**Note:** The default value is optimized for typical production workloads. Actual pool size is `min(schedulers, worker_pool_max)`.

---

## Message Count Verification

### `message_count_over_tolerance_percent`

**Type:** Float  
**Default:** 5.0  
**Range:** 0.0-100.0  
**Description:** Percentage tolerance for extra messages in destination queue

**Usage:**
```erlang
queue_migration.message_count_over_tolerance_percent = 10.0
```

**Example:**
- Source: 1000 messages
- Tolerance: 5.0%
- Acceptable range: 1000-1050 messages

---

### `message_count_under_tolerance_percent`

**Type:** Float  
**Default:** 0.0  
**Range:** 0.0-100.0  
**Description:** Percentage tolerance for missing messages in destination queue

**Usage:**
```erlang
queue_migration.message_count_under_tolerance_percent = 2.0
```

**Example:**
- Source: 1000 messages
- Tolerance: 2.0%
- Acceptable range: 980-1000 messages

**Warning:** Non-zero under-tolerance may mask message loss. Use with caution.

---

## Shovel Configuration

### `shovel_prefetch_count`

**Type:** Positive integer  
**Default:** 128  
**Description:** Number of messages to prefetch during shovel transfer

**Usage:**
**Note:** The default value is optimized for typical production workloads.

---

## Disk Space Configuration

### `min_disk_space_buffer`

**Type:** Positive integer (bytes)  
**Default:** 524288000 (500 MB)  
**Description:** Minimum free disk space buffer required for migration

---

### `disk_usage_peak_multiplier`

**Type:** Float  
**Default:** 2.0  
**Range:** >= 1.5  
**Description:** Multiplier for estimating peak disk usage during migration

**Usage:**
```erlang
queue_migration.disk_usage_peak_multiplier = 3.0
```

**Calculation:**
```
Required space = (concurrent_workers × avg_queue_size × multiplier) + buffer
```

---

## Memory Configuration

### `max_memory_usage_percent`

**Type:** Integer  
**Default:** 40  
**Range:** 1-100  
**Description:** Maximum memory usage percentage allowed for migration to start

**Usage:**
```erlang
queue_migration.max_memory_usage_percent = 50
```

---

## Queue Limits

### `max_queues_for_migration`

**Type:** Positive integer  
**Default:** 10000  
**Description:** Maximum number of queues allowed in a single migration

**Usage:**
```erlang
queue_migration.max_queues_for_migration = 5000
```

**Note:** Use `batch_size` parameter to migrate in smaller batches.

---

### `max_migration_duration_ms`

**Type:** Positive integer (milliseconds)  
**Default:** 2700000 (45 minutes)  
**Description:** Maximum duration for entire migration process

**Usage:**
```erlang
queue_migration.max_migration_duration_ms = 3600000  % 1 hour
```

---

## Progress Updates

### `progress_update_frequency`

**Type:** Positive integer  
**Default:** 10  
**Range:** 1-4096  
**Description:** Number of messages between progress updates

**Usage:**
```erlang
queue_migration.progress_update_frequency = 100
```

**Note:** The default value provides good balance between update frequency and overhead.

---

## Snapshot Configuration

### `snapshot_mode`

**Type:** Atom  
**Default:** ebs  
**Options:** `tar`, `ebs`, `none`  
**Description:** Snapshot creation method

**Usage:**
```erlang
queue_migration.snapshot_mode = tar
```

**Options:**
- `ebs` - Create EBS snapshots (AWS only, requires IAM permissions)
- `tar` - Create tar archive snapshots
- `none` - Skip snapshot creation

---

### `cleanup_snapshots_on_success`

**Type:** Boolean  
**Default:** true  
**Description:** Whether to delete snapshots after successful migration

**Usage:**
```erlang
queue_migration.cleanup_snapshots_on_success = false
```

---

### `ebs_volume_device`

**Type:** String  
**Default:** "/dev/sdh"  
**Description:** EBS volume device path for RabbitMQ data

**Usage:**
```erlang
queue_migration.ebs_volume_device = "/dev/nvme1n1"
```

**Note:** Only used when `snapshot_mode = ebs`

---

## Queue Leader Balance

### `max_imbalance_ratio`

**Type:** Float  
**Default:** 1.6  
**Description:** Maximum allowed ratio between most and least loaded nodes

**Note:** Not configurable via rabbitmq.conf (hardcoded constant)

---

### `min_queues_for_balance_check`

**Type:** Integer  
**Default:** 10  
**Description:** Minimum number of queues required to perform balance check

**Note:** Not configurable via rabbitmq.conf (hardcoded constant)

---

## Related Documentation

- **Troubleshooting Guide:** TROUBLESHOOTING.md
- **HTTP API Reference:** HTTP_API.md
