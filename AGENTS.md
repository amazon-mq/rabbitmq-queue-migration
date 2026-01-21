# RabbitMQ Queue Migration Plugin - Codebase Summary

**Version**: RabbitMQ 3.13.x
**Purpose**: Migrate mirrored classic queues to quorum queues
**Plugin Name**: `rabbitmq_queue_migration`
**Repository**: https://github.com/amazon-mq/rabbitmq-queue-migration

## Overview

This plugin provides a production-ready solution for migrating mirrored classic queues to quorum queues in RabbitMQ clusters. It implements a two-phase migration process with comprehensive progress tracking, distributed execution across cluster nodes, and a RESTful HTTP API for control and monitoring.

## Architecture Components

### Core Modules

| Module | Purpose | Key Responsibilities |
|--------|---------|---------------------|
| `rqm_app.erl` | Application entry point | Worker pool setup, schema initialization, configuration validation |
| `rqm.erl` | Core migration engine | Two-phase migration logic, distributed coordination, rollback handling |
| `rqm_db.erl` | State management | Mnesia database operations, progress tracking, rollback state |
| `rqm_mgmt.erl` | HTTP API | REST endpoints for migration control and status monitoring |
| `rqm_util.erl` | Utilities | URL-safe base64 encoding for migration IDs, HA policy checking |
| `rqm_config.erl` | Configuration management | Dynamic configuration calculation, safety limits, worker pool sizing |
| `rqm_checks.erl` | Pre-migration validation | Comprehensive system readiness checks, resource validation |
| `rqm_compat_checker.erl` | Queue compatibility analysis | Individual queue eligibility assessment |
| `rqm_snapshot.erl` | Snapshot management | Creates EBS or tar-based snapshots during pre-migration preparation |
| `rqm_ebs.erl` | AWS EBS operations | Low-level EBS snapshot creation/deletion, volume discovery |
| `rqm_db_queue.erl` | Queue database queries | Query queues by vhost/type, supports both Mnesia and Khepri |
| `rqm_gatherer.erl` | Distributed result collection | Coordinates asynchronous task results across cluster nodes |
| `rqm_shovel.erl` | Shovel management | Creates and manages shovels for message transfer with retry logic |
| `rqm_queue_naming.erl` | Queue naming | Generates unique temporary queue names using migration ID timestamp |

### Data Structures

#### Migration Record (`queue_migration`)
```erlang
-record(queue_migration, {
    id,                              % Unique migration ID (timestamp + node)
    vhost,                           % Virtual host being migrated
    started_at,                      % Timestamp when migration started
    completed_at,                    % Timestamp when migration completed (null if in progress)
    total_queues,                    % Total number of queues to migrate
    completed_queues,                % Number of queues completed
    skipped_queues = 0,              % Number of queues skipped
    status :: migration_status(),    % Status: 'pending', 'in_progress', 'completed', 'failed', 'interrupted', 'rollback_pending', 'rollback_completed'
    error,                           % Error details if failed (null otherwise)
    rollback_started_at,             % Timestamp when rollback started
    rollback_completed_at,           % Timestamp when rollback completed
    rollback_errors,                 % List of rollback errors per queue
    snapshots,                       % List of snapshot info: [{Node, SnapshotId, VolumeId}, ...]
    skip_unsuitable_queues = false   % Whether to skip unsuitable queues instead of blocking migration
}).
```

#### Queue Status Record (`queue_migration_status`)
```erlang
-record(queue_migration_status, {
    key,                             % Composite primary key: {QueueResource, MigrationId}
    queue_resource,                  % Queue resource record
    migration_id,                    % Reference to parent migration
    original_queue_args,             % Store original classic queue arguments for rollback
    original_bindings,               % Store original binding details for rollback
    started_at,                      % When this queue's migration started
    completed_at,                    % When this queue's migration completed (null if in progress)
    total_messages,                  % Total messages in queue at start
    migrated_messages,               % Number of messages migrated so far
    status :: queue_migration_status(), % Status: 'pending', 'in_progress', 'completed', 'failed', 'skipped'
    error,                           % Error details if failed or skip reason if skipped (null otherwise)
    rollback_started_at,             % When rollback started for this queue
    rollback_completed_at,           % When rollback completed for this queue
    rollback_error                   % Specific rollback error if any
}).
```

## Migration Process

### Prerequisites (BEFORE Migration)

1. **Cluster Health**: All cluster nodes must be running
2. **Plugin Enabled**: `rabbitmq_queue_migration` and `rabbitmq_shovel` plugins loaded
3. **Queue Eligibility**: Only mirrored classic queues with HA policies
4. **Khepri Disabled**: Classic Mnesia required (Khepri not compatible)
5. **AWS Configuration**: For EBS snapshots, AWS credentials and region must be configured
6. **EBS Volume**: RabbitMQ data directory must be on EBS volume (configurable device path)

**Note:** The plugin suspends non-HTTP listeners and closes client connections during migration. Active connections are not a prerequisite - they are handled automatically.

### Two-Phase Migration Algorithm

```
Pre-migration Preparation:
├── Stop connections to target virtual host
├── Quiesce all cluster nodes
├── Create EBS snapshots (or tar archives for testing)
└── Validate cluster state before proceeding

Phase 1: Classic Queue → Temporary Quorum Queue
├── Create temporary quorum queue with "tmp_<timestamp>_" prefix
├── Copy all bindings from classic to temporary queue
├── Migrate messages one-by-one (dequeue → deliver → settle)
├── Delete original classic queue
└── Progress: ~50% completion

Phase 2: Temporary Quorum Queue → Final Quorum Queue
├── Create final quorum queue with original name
├── Copy all bindings from temporary to final queue
├── Migrate messages from temporary to final queue
├── Delete temporary queue
└── Progress: 100% completion

Post-migration Restore:
├── Restore connections to virtual host
├── Validate migration success
└── Generate migration statistics
```

### Queue Eligibility Criteria

A queue is eligible for migration if ALL conditions are met:
- **Queue Type**: Must be `rabbit_classic_queue`
- **Node Location**: Queue process runs on current node
- **Non-Exclusive**: Exclusive queues are skipped
- **HA Policy**: Must have high-availability policy applied

### Message Migration Details

- **Transfer Method**: Shovel-based message transfer between queues
- **Shovel Configuration**: `ack-mode: on-confirm` for reliable delivery
- **Prefetch**: Configurable (default: 128 messages)
- **Progress Updates**: Configurable frequency (default: every 10 messages)
- **Timeout Handling**: 2-minute timeout per queue, 15 retries (30 minutes total)
- **Error Recovery**: Failed queues don't stop overall migration
- **Retry Logic**: Shovel creation retries up to 10 times (handles transient errors)

### Queue Argument Conversion

```erlang
% Automatic argument transformations:
x-queue-type: classic → quorum                    % Required change
x-max-priority: <removed>                         % Not supported in quorum
x-queue-mode: <removed>                          % Lazy mode works differently
x-queue-master-locator: <removed>                % Classic queue specific
x-queue-version: <removed>                       % Classic queue specific
```

**Unsuitable Arguments:**
- `x-overflow: reject-publish-dlx` - Not compatible with quorum queues, causes queue to be marked unsuitable
- Use `skip_unsuitable_queues` mode to skip these queues during migration

## HTTP API Endpoints

### Migration Control
```
POST /api/queue-migration/start           # Start migration on default vhost (/)
POST /api/queue-migration/start/:vhost    # Start migration on specific vhost
POST /api/queue-migration/check/:vhost    # Check compatibility before migration
POST /api/queue-migration/interrupt/:migration_id  # Interrupt running migration
```

**Start Request Body (optional):**
```json
{
  "skip_unsuitable_queues": true,
  "batch_size": 50,
  "batch_order": "smallest_first",
  "queue_names": ["queue1", "queue2"]
}
```

**Start Response:**
```json
{
  "migration_id": "base64url_encoded_migration_id",
  "status": "started"
}
```

### Status Monitoring
```
GET  /api/queue-migration/status          # Overall migration status + history
GET  /api/queue-migration/status/:id      # Specific migration details
```

### Status Response Structure
```json
{
  "status": "in_progress",
  "migrations": [
    {
      "id": "base64url_encoded_migration_id",
      "display_id": "/ (2025-06-17 20:35:08) on rabbit-1@node",
      "vhost": "/",
      "started_at": "2025-06-17 20:35:08",
      "completed_at": null,
      "total_queues": 64,
      "completed_queues": 32,
      "skipped_queues": 0,
      "progress_percentage": 50,
      "status": "in_progress",
      "skip_unsuitable_queues": false,
      "error": null
    }
  ]
}
```

## Implementation Details

### Worker Pool Architecture

- **Pool Name**: `rqm_worker_pool`
- **Dynamic Sizing**: Formula `min(schedulers, worker_pool_max())` caps pool at CPU core count
- **Default Maximum**: 32 workers (allows large instances to fully utilize cores)
- **Performance**: Testing shows optimal performance at scheduler count (2 workers on 2 vCPU = 2x speedup vs 1 worker)
- **Stability**: Exceeding scheduler count causes network saturation, timeouts, and cluster partitions
- **Async Processing**: Each queue migration runs in separate worker
- **Resource Management**: Proper cleanup and error handling
- **Shovel Retry**: Shovel creation retries up to 10 times on exceptions (handles transient `noproc` errors)

### Distributed Coordination

- **Global Locks**: Prevents concurrent migrations using `{rqm, pid()}`
- **Node-Specific Processing**: Each node processes queues local to it
- **Gatherer Pattern**: Coordinates completion across all cluster nodes
- **ERPC Communication**: Uses `erpc:call/4` for inter-node communication

### Database Operations

- **Storage**: Mnesia distributed database with disc_copies
- **Tables**: `queue_migration` and `queue_migration_status`
- **Transactions**: Atomic updates for consistency
- **Dirty Operations**: Used for performance where consistency allows

### Progress Tracking

- **Update Frequency**: Configurable via `progress_update_frequency` (default: 10)
- **Calculation**: Messages processed ÷ 4 for progress count
- **Real-time Updates**: Database updated during message migration
- **Percentage Calculation**: `(completed / total) * 100`

## Post-Migration Configuration

After successful migration, consider applying these configurations:

### Set Default Queue Type

```bash
curl -X POST -u guest:guest \
    -H "Content-Type: application/json" \
    -d '{"default_queue_type":"quorum"}' \
    "http://localhost:15672/api/vhosts/%2F"
```

This ensures new queues are created as quorum type by default.

**Note:** The setting `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true` must be enabled **before** migration (validated during pre-migration checks). This allows applications to redeclare queues with classic arguments after migration without errors.

## Key Functions by Module

### `rqm.erl` (Core Migration Engine)

**Exported API:**
- `start/1` - Start migration with options map
- `validate_migration/1` - Pre-migration validation without starting
- `status/0` - Get overall migration system status
- `get_migration_status/0` - Get list of all migrations
- `get_queue_migration_status/1` - Get detailed status for specific migration
- `get_rollback_pending_migration_json/0` - Get migration requiring rollback
- `start_migration_preparation_on_node/2` - Distributed preparation phase
- `start_post_migration_restore_on_node/3` - Distributed restoration phase
- `start_migration_on_node/7` - Distributed migration execution

**Key Internal Functions:**
- `mcq_qq_migration/3` - Core two-phase migration logic
- `migrate_to_tmp_qq/3` - Phase 1: Classic → Temporary quorum
- `tmp_qq_to_qq/3` - Phase 2: Temporary → Final quorum
- `migrate_empty_queue_fast_path/4` - Optimized path for empty queues
- `verify_message_counts/5` - Message count verification with tolerances

### `rqm_db.erl` (State Management)

**Key Functions:**
- `create_migration/3` - Initialize migration record
- `update_migration_with_queues/3` - Update migration with queue list
- `update_migration_status/2` - Update migration status
- `update_migration_skipped_count/1` - Update skipped queue count
- `create_queue_status/3` - Create queue status record
- `create_skipped_queue_status/3` - Create skipped queue record
- `update_queue_status_*` - Various queue status updates
- `get_migration_status/0` - Get all migrations
- `get_queue_migration_status/1` - Get specific migration details

### `rqm_mgmt.erl` (HTTP API)

**Endpoints:**
- `accept_migration_start/2` - Handle POST /api/queue-migration/start
- `accept_compatibility_check/2` - Handle POST /api/queue-migration/check/:vhost
- `accept_interrupt/3` - Handle POST /api/queue-migration/interrupt/:migration_id
- `to_json/2` - Format responses for status endpoints

### `rqm_checks.erl` (Validation)

**System Checks:**
- `check_shovel_plugin/0` - Verify shovel plugin enabled
- `check_khepri_disabled/0` - Verify Khepri not enabled
- `check_leader_balance/1` - Verify queue leaders balanced
- `check_disk_space/2` - Verify sufficient disk space
- `check_active_alarms/0` - Check for memory/disk alarms
- `check_memory_usage/0` - Verify memory usage acceptable
- `check_snapshot_not_in_progress/0` - Verify no concurrent snapshots
- `check_cluster_partitions/0` - Verify no network partitions

**Queue Checks:**
- `check_queue_synchronization/1` - Verify mirrored queues synchronized
- `check_queue_suitability/1` - Verify queue arguments suitable

### `rqm_shovel.erl` (Shovel Management)

**Key Functions:**
- `setup_shovel/4` - Create shovel for message transfer
- `create_with_retry/4` - Retry shovel creation (10 attempts, 1-second delays)
- `delete_shovel/2` - Delete shovel after migration

### `rqm_queue_naming.erl` (Queue Naming)

**Key Functions:**
- `add_temp_prefix/2` - Create temporary name with timestamp
- `remove_temp_prefix/2` - Extract original name using migration ID

### `rqm_config.erl` (Configuration)

**Key Functions:**
- All configuration getters return values from application environment or defaults
- See Configuration Parameters section for complete list
- `fork/1` - Declare intent to produce results (increment producer count)
- `finish/1` - Signal completion of work (decrement producer count)
- `in/2` - Add result to gatherer queue (async)
- `sync_in/2` - Add result to gatherer queue (sync)
- `out/1` - Retrieve result from gatherer queue (blocks if empty and producers active)

### `rqm_config.erl`
- `calculate_worker_pool_size/0` - Dynamic worker pool sizing (min of schedulers and worker_pool_max)
- `max_queues_for_migration/0` - Maximum queue count limits
- `snapshot_mode/0` - Get snapshot mode configuration (tar, ebs, or none)
- `ebs_volume_device/0` - Get EBS volume device path configuration
- `message_count_over_tolerance_percent/0` - Get tolerance for over-delivery (default: 5.0%)
- `message_count_under_tolerance_percent/0` - Get tolerance for under-delivery (default: 0.0%)
- `shovel_prefetch_count/0` - Get shovel prefetch count (default: 128)

### `rqm_snapshot.erl`
- `create_snapshot/1` - Create snapshot using configured mode (tar or ebs)
- `create_snapshot/2` - Create snapshot with specific mode
- `check_no_snapshots_in_progress/0` - Validate no concurrent EBS snapshots (used by validation chain)
- `check_no_snapshots_in_progress/1` - Pattern match on snapshot mode (tar skips, ebs checks)
- `find_rabbitmq_volume/1` - Discover EBS volume for RabbitMQ data
- `create_ebs_snapshot/1` - Create EBS snapshot for discovered volume
- `cleanup_snapshot/1` - Clean up snapshot using configured mode
- `cleanup_snapshot/2` - Clean up snapshot with specific mode

### `rqm_ebs.erl`
- `instance_volumes/0` - List all EBS volumes attached to current instance
- `create_volume_snapshot/1` - Create snapshot for volume with default description
- `create_volume_snapshot/2` - Create snapshot with custom description
- `delete_volume_snapshot/1` - Delete snapshot with default region
- `delete_volume_snapshot/2` - Delete snapshot with specific region

### `rqm_db_queue.erl`
- `get_all_by_vhost_and_type/2` - Query queues by vhost and type (supports Mnesia and Khepri)
- `get_all_by_type_and_node/2` - Query queues by type and node (supports Mnesia and Khepri)

### `rqm_util.erl`
- `has_ha_policy/1` - Check if queue has HA policy applied
- `has_all_mirrors_synchronized/1` - Check if all mirrors are synchronized
- `base64url_encode/1` - URL-safe base64 encoding for migration IDs
- `base64url_decode/1` - URL-safe base64 decoding
- `add_base64_padding/1` - Add appropriate padding to base64 data
- `format_migration_id/1` - Format migration ID using URL-safe encoding
- `to_unicode/1` - Convert string to Unicode binary
- `unicode_format/2` - Format string using io_lib:format and convert to Unicode binary
- `suspend_non_http_listeners/0` - Suspend AMQP listeners for snapshot preparation
- `resume_non_http_listeners/1` - Resume previously suspended listeners
- `close_all_client_connections/0` - Close all client connections
- `resume_all_non_http_listeners/0` - Resume all non-HTTP listeners on current node
- `format_iso8601_utc/0` - Format current time as ISO8601 UTC string

### `rqm_checks.erl`
- `check_shovel_plugin/0` - Validate rabbitmq_shovel plugin is enabled
- `check_khepri_disabled/0` - Validate Khepri database is disabled
- `check_relaxed_checks_setting/0` - Validate quorum queue configuration
- `check_leader_balance/1` - Ensure balanced queue distribution
- `check_queue_synchronization/1` - Verify all mirrors are synchronized
- `check_queue_suitability/1` - Comprehensive queue eligibility
- `check_disk_space/1` - Disk space estimation and validation based on worker pool concurrency
- `check_active_alarms/0` - Check for active RabbitMQ alarms
- `check_memory_usage/0` - Validate memory usage is within limits
- `check_snapshot_not_in_progress/0` - Verify no concurrent EBS snapshots (delegates to `rqm_snapshot`)
- `check_cluster_partitions/0` - Verify no cluster partitions and all nodes up
- `check_system_migration_readiness/1` - Overall system readiness

### `rqm_compat_checker.erl`
- `check_all_vhosts/0` - Check compatibility across all vhosts
- `check_vhost/1` - Check compatibility for specific vhost
- `check_queue/1` - Check individual queue compatibility
- `check_migration_readiness/1` - Complete migration readiness assessment

### `rqm_compat_checker_mgmt.erl`
- `to_json/2` - Format compatibility check results for API
- `format_migration_readiness_response/1` - Format readiness check response
- `format_system_checks_for_ui/1` - Format system checks for web UI
- `format_queue_checks_for_ui/1` - Format queue checks for web UI
- `check_queue_suitability/1` - Comprehensive queue eligibility
- `check_disk_space/1` - Disk space estimation and validation
- `check_system_migration_readiness/1` - Overall system readiness

## Configuration Parameters

### Using `rabbitmq.conf`
```ini
queue_migration.snapshot_mode = ebs
queue_migration.ebs_volume_device = /dev/sdh
queue_migration.cleanup_snapshots_on_success = true
queue_migration.worker_pool_max = 32
queue_migration.max_queues_for_migration = 10000
queue_migration.max_migration_duration_ms = 2700000
queue_migration.min_disk_space_buffer = 524288000
queue_migration.disk_usage_peak_multiplier = 2.0
queue_migration.max_memory_usage_percent = 40
queue_migration.message_count_over_tolerance_percent = 5.0
queue_migration.message_count_under_tolerance_percent = 0.0
queue_migration.shovel_prefetch_count = 128
```

### Application Environment
- `progress_update_frequency` - Messages between progress updates (default: 10)
- `worker_pool_max` - Maximum worker pool size (default: 32, capped at scheduler count)
- `snapshot_mode` - Snapshot mode: `tar` (testing), `ebs` (production EBS snapshots), or `none` (disabled) (default: ebs)
- `ebs_volume_device` - EBS device path for RabbitMQ data (default: "/dev/sdh")
- `cleanup_snapshots_on_success` - Delete snapshots after successful migration (default: true)
- `max_queues_for_migration` - Maximum queues per migration (default: 10,000)
- `max_migration_duration_ms` - Maximum migration duration (default: 2,700,000ms / 45 minutes)
- `min_disk_space_buffer` - Minimum free disk space buffer (default: 524,288,000 bytes / 500MB)
- `disk_usage_peak_multiplier` - Peak disk usage multiplier (default: 2.0)
- `max_memory_usage_percent` - Maximum memory usage percentage (default: 40)
- `message_count_over_tolerance_percent` - Tolerance for extra messages (default: 5.0%)
- `message_count_under_tolerance_percent` - Tolerance for missing messages (default: 0.0%)
- `shovel_prefetch_count` - Shovel prefetch count for message transfer (default: 128)

### Constants (in header file)
- `QUEUE_MIGRATION_TIMEOUT_MS` - 120,000ms (2 minutes)
- `QUEUE_MIGRATION_TIMEOUT_RETRIES` - 15 retries (30 minutes total)
- `DEFAULT_PROGRESS_UPDATE_FREQUENCY` - 10 messages
- `DEFAULT_WORKER_POOL_MAX` - 32 workers (capped at scheduler count)
- `MAX_QUEUES_FOR_MIGRATION` - 10,000 queues maximum
- `MIN_DISK_SPACE_BUFFER` - 524,288,000 bytes (500MB)
- `DISK_USAGE_PEAK_MULTIPLIER` - 2.0x multiplier for peak disk usage estimation
- `MIN_DISK_USAGE_PEAK_MULTIPLIER` - 1.5x minimum safety margin
- `DEFAULT_EBS_VOLUME_DEVICE` - "/dev/sdh" default EBS device path
- `DEFAULT_MESSAGE_COUNT_OVER_TOLERANCE_PERCENT` - 5.0% tolerance for over-delivery
- `DEFAULT_MESSAGE_COUNT_UNDER_TOLERANCE_PERCENT` - 0.0% tolerance for under-delivery
- `DEFAULT_SHOVEL_PREFETCH_COUNT` - 128 messages
- `DEFAULT_CLEANUP_SNAPSHOTS_ON_SUCCESS` - true
- `MAX_MEMORY_USAGE_PERCENT` - 40%
- `MAX_MIGRATION_DURATION_MS` - 2,700,000ms (45 minutes)

## Rollback Functionality

### Current State

**Automatic rollback is not implemented in this open-source plugin.** The migration record includes rollback-related fields (`rollback_started_at`, `rollback_completed_at`, `rollback_errors`) but these are not currently used.

When a migration fails:
- Migration status is set to `rollback_pending`
- Failed queue is marked with error details
- Shovels are cleaned up automatically
- Destination quorum queues remain (not automatically deleted)
- Classic queues remain with original data (if not yet deleted)

### Recovery Options

**Snapshot Restore (Recommended):**
1. Stop RabbitMQ on all nodes
2. Restore from snapshots (EBS or tar)
3. Restart RabbitMQ cluster

See `priv/tools/restore_snapshot_test.sh` for tar snapshot restoration example.

**Automatic Rollback:**
- Feature of Amazon MQ for RabbitMQ managed service
- Not planned for this open-source plugin
- Rollback fields in records reserved for potential future use

## Error Handling

### Migration Failures
- **Queue Level**: Individual queue failures don't stop overall migration
- **Error Storage**: Failed queue details stored in `queue_migration_status`
- **Logging**: Comprehensive error logging with stack traces
- **Status Tracking**: Migration status reflects partial failures
- **Summary Logging**: Exception handler logs error/aborted counts instead of full error lists

### Timeout Management
- **Per-Queue Timeout**: 2 minutes with 15 retries (30 minutes total)
- **Message Handling**: Waits for RA event confirmations
- **Graceful Degradation**: Continues with remaining queues on timeout

### Shovel Exception Handling
- **Creation Retry**: Shovel creation retries up to 10 times on exceptions (handles `noproc` errors)
- **Cleanup Exceptions**: Shovel cleanup uses `case catch` to handle badmatch and other exceptions gracefully
- **Benign Failures**: Cleanup failures are logged as warnings but don't fail the migration

### Message Count Verification
- **Configurable Tolerance**: Separate tolerances for over-delivery (5%) and under-delivery (2%)
- **Over-Delivery**: Extra messages logged as warning if within tolerance (may indicate timing or duplicates)
- **Under-Delivery**: Missing messages logged as warning if within tolerance (may indicate expiration)
- **Exceeds Tolerance**: Mismatches exceeding tolerance fail the migration
- **Strict Mode**: Set both tolerances to 0.0 for strict verification

## Testing Considerations

### Unit Tests

**Test Suite**: `unit_SUITE.erl` - Comprehensive unit test coverage with 8 test groups

**Test Groups:**
1. **base64url_encoding** - URL-safe base64 encoding tests
2. **base64url_decoding** - URL-safe base64 decoding tests
3. **roundtrip_tests** - Round-trip encoding/decoding validation
4. **migration_id_tests** - Migration ID generation and encoding
5. **padding_tests** - Base64 padding handling
6. **compatibility_tests** - URL-safety and standard base64 comparison
7. **migration_checks** - Leader balance, disk usage, synchronization checks
8. **queue_naming** - Temporary queue name generation with timestamp-based uniqueness

### Integration Tests

**Test Suite**: 6 comprehensive integration tests in `test/integration/`

**Tests:**
1. **EndToEndMigrationTest** - Happy path migration validation
2. **InterruptionTest** - Migration interruption handling
3. **SkipUnsuitableTest** - Skip unsuitable queues feature (25 suitable + 5 unsuitable)
4. **BatchMigrationTest** - Batch migration with batch_size/batch_order (50 queues in 3 batches)
5. **EmptyQueueTest** - Empty queue migration (20 queues, 0 messages)
6. **AlreadyQuorumTest** - Idempotency validation (15 classic + 10 quorum)

**CI Integration:** All tests run automatically in GitHub Actions

**Bug Discovery:** Integration tests caught:
- Batch migration using wrong queue list
- Skipped queue count not updated for interrupted migrations

### Prerequisites Testing
- Verify cluster health checks work correctly
- Test connection detection and blocking
- Validate queue eligibility filtering

### Migration Process Testing
- Empty queues (metadata-only migration)
- Various message volumes and sizes
- Complex binding patterns
- Mixed queue configurations
- Concurrent background load

### Error Scenario Testing
- Network interruptions during migration
- Node failures mid-migration
- Disk space exhaustion
- Memory pressure conditions

### API Testing
- All HTTP endpoints and methods
- Progress monitoring accuracy
- Error response handling
- Migration ID encoding/decoding

## Performance Characteristics

### Migration Performance

Performance varies significantly based on:
- Queue message counts
- Message sizes
- Worker pool size (capped at scheduler count)
- Disk I/O capacity
- Network bandwidth

**Example Results:**
- **5000 queues, 10 messages each**: 2.5 hours (33 queues/minute)
- **500 queues, 100 messages each, 2 workers**: 14-15 minutes (35 queues/minute)

**Note:** Empty queues migrate much faster using the fast-path optimization.

### Tested Performance (m7g.large, 2 vCPUs)
- **500 queues, 100 messages each**:
  - 1 worker: 29 minutes
  - 2 workers: 14-15 minutes (2x speedup)
  - 4 workers: Failed (network saturation, timeouts, partitions)
- **Optimal configuration**: Worker count = scheduler count

### Scalability Features
- **Worker pool scaling**: Capped at scheduler count for stability
- **Progress batching**: Reduces database write frequency
- **Distributed processing**: Leverages all cluster nodes
- **Configurable timeouts**: Adjustable for different environments
- **Configurable prefetch**: Shovel prefetch count tunable for different message sizes

### Resource Limits
- **Worker pool**: Never exceeds scheduler count (prevents cluster instability)
- **Disk space**: Total vhost size × configurable peak multiplier (default 2.0x) plus 500MiB minimum buffer

## Critical Behavioral Changes

### Queue Argument Differences
1. **Unsuitable Arguments**: Queues with `x-overflow: reject-publish-dlx` are marked unsuitable and skipped (use `skip_unsuitable_queues` mode)
2. **Priority Queues**: `x-max-priority` removed (quorum queues use high/low priority)
3. **Lazy Mode**: `x-queue-mode` removed (quorum queues handle memory management differently)
4. **Classic-Specific**: `x-queue-master-locator` and `x-queue-version` removed

### Application Impact
- Applications using `reject-publish-dlx` must change overflow policy before migration
- Priority queue usage patterns may need adjustment
- Memory usage patterns will change with quorum queues

## Monitoring and Observability

### Log Messages
- Migration start/completion with duration
- Per-queue migration progress
- Error conditions with detailed stack traces
- Timeout warnings and retry attempts

### Metrics Available
- Total/completed queue counts
- Message migration progress
- Migration duration
- Error rates and types

### Status Endpoints
- Real-time progress percentages
- Historical migration data
- Per-queue detailed status
- Error details for failed queues

## Integration Points

### Web UI Components
- **JavaScript Assets**: `queue-migration.js`
- **Management Plugin Integration**: Extends RabbitMQ management interface with new navigation items
- **Template System**: Uses RabbitMQ management plugin template system for UI rendering
- **Real-time Updates**: Web interface for monitoring migration progress with auto-refresh
- **Navigation Integration**: Adds "Queue Migration" to Admin menu
- **Status Formatting**: Custom formatters for migration status, progress bars, and queue resources

### RabbitMQ Core
- **Queue Type System**: Uses pluggable queue type architecture
- **Binding Management**: Preserves all queue bindings during migration
- **Policy System**: Integrates with HA policy framework
- **Management Plugin**: Extends management API and UI

### External Dependencies
- **Mnesia**: For persistent state storage
- **Worker Pool**: For parallel processing
- **Global**: For distributed locking
- **ERPC**: For cluster communication
- **RabbitMQ AWS Plugin**: For EBS snapshot operations and AWS integration

### Build System
- **Build Tool**: Erlang.mk with RabbitMQ plugin framework
- **Dependencies**: `rabbit_common`, `rabbit`, `rabbitmq_management`, `rabbitmq_aws`
- **Test Dependencies**: `rabbitmq_ct_helpers`, `rabbitmq_ct_client_helpers`
- **Compilation**: Automatic .beam file generation in ebin/ directory
- **Plugin Structure**: Standard RabbitMQ plugin layout with priv/www/ for web assets
- **Project Configuration**: Makefile with proper broker version requirements and plugin metadata

## EBS Snapshot Integration

### Snapshot Modes
- **tar**: Creates tar.gz archives in `/tmp/rabbitmq_migration_snapshots/` for development/testing
- **ebs**: Creates real EBS snapshots using AWS EC2 API for production use

### EBS Snapshot Process
1. **Volume Discovery**: Automatically discovers EBS volumes attached to the instance
2. **Volume Filtering**: Identifies volumes mounted at the configured device path (default: `/dev/sdh`)
3. **Snapshot Creation**: Creates snapshots for all discovered RabbitMQ data volumes
4. **Metadata Storage**: Stores snapshot IDs and metadata for potential rollback use
5. **Error Handling**: Comprehensive error handling with fallback to tar mode if EBS fails
6. **Concurrent Snapshot Detection**: Validates no snapshots in progress before starting migration

### AWS Configuration Requirements
- **Credentials**: AWS credentials via environment variables, config files, or EC2 instance roles
- **Region**: AWS region configuration (defaults to us-east-1, should match peer discovery)
- **Permissions**: EC2 permissions for `CreateSnapshot`, `DescribeVolumes`, `DescribeSnapshots`, and `DescribeInstances`
- **Volume Setup**: RabbitMQ data directory must be on EBS volume at configured device path

### Snapshot Timing
- **When**: Created during pre-migration preparation phase, after quiescing nodes
- **Purpose**: Provides point-in-time backup before migration starts
- **Usage**: Can be used for manual rollback if migration fails catastrophically
- **Validation**: Pre-migration check ensures no concurrent snapshots in progress

### Testing and Recovery Tools
- **Snapshot Restore Script**: `priv/tools/restore_snapshot_test.sh` - Bash script for testing snapshot recovery
- **Script Features**: Validates arguments, confirms destructive operations, supports force mode
- **Usage**: Restores tar-based snapshots to test data directory for migration testing
- **Safety**: Includes confirmation prompts and comprehensive error handling

## Recent Improvements (January 2026)

### Skip Unsuitable Queues Feature
- **Skip Mode**: `skip_unsuitable_queues` parameter allows migration to proceed by skipping problematic queues
- **Skip Reasons**: Tracks why queues were skipped (unsynchronized, too_many_queues, unsuitable_overflow, interrupted)
- **Integration Tests**: SkipUnsuitableTest validates feature works correctly

### Batch Migration Feature
- **Batch Size**: `batch_size` parameter limits number of queues per migration
- **Batch Order**: `batch_order` parameter controls selection order (smallest_first, largest_first)
- **Integration Tests**: BatchMigrationTest validates feature works correctly
- **Bug Fix**: Fixed batch migration using wrong queue list (EligibleQueues2 vs EligibleQueues3)

### Queue Naming Improvements
- **Unique Prefixes**: Temporary queues use `tmp_<timestamp>_<original_name>` format
- **Collision Prevention**: Timestamp from migration ID ensures uniqueness
- **Module**: `rqm_queue_naming` with comprehensive unit tests

### Integration Test Suite
- **6 Tests**: EndToEnd, Interruption, SkipUnsuitable, BatchMigration, EmptyQueue, AlreadyQuorum
- **CI Integration**: All tests run automatically in GitHub Actions
- **Bug Discovery**: Tests caught batch migration bug and skipped queue count bug

### Documentation Improvements
- **Comprehensive Guides**: Migration Guide, Snapshots Guide, API Examples, Troubleshooting Guide
- **Accuracy**: All documentation verified against actual code and API responses
- **Organization**: Detailed content moved to docs/ directory, README streamlined

### Validation Enhancements
- **Concurrent Snapshot Check**: Prevents migration when EBS snapshots are in progress
- **Complete Validation Chain**: All checks properly integrated

### Error Handling Improvements
- **Shovel Creation Retry**: Retries up to 10 times on exceptions (handles transient `noproc` errors)
- **Shovel Cleanup Safety**: Uses `case catch` to handle badmatch and other cleanup exceptions gracefully
- **Reduced Log Verbosity**: Per-queue messages moved to DEBUG level

This codebase represents a production-ready solution for RabbitMQ queue migration with comprehensive safety features, detailed progress tracking, robust error handling, and extensive testing infrastructure.
