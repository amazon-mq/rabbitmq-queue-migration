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
| `rqm_compat_checker_mgmt.erl` | Compatibility API | HTTP endpoints for queue compatibility checking |
| `rqm_snapshot.erl` | EBS snapshot management | Creates EBS or tar-based snapshots during pre-migration preparation |
| `rqm_ebs.erl` | AWS EBS operations | Low-level EBS snapshot creation/deletion, volume discovery |
| `rqm_db_queue.erl` | Queue database queries | Query queues by vhost/type, supports both Mnesia and Khepri |
| `rqm_gatherer.erl` | Distributed result collection | Coordinates asynchronous task results across cluster nodes |

### Data Structures

#### Migration Record (`queue_migration`)
```erlang
-record(queue_migration, {
    id,                     % Unique migration ID (timestamp + node)
    vhost,                  % Virtual host being migrated
    started_at,             % Timestamp when migration started
    completed_at,           % Timestamp when migration completed (null if in progress)
    total_queues,           % Total number of queues to migrate
    completed_queues,       % Number of queues completed
    status,                 % Status: 'in_progress', 'completed', 'failed', 'rollback_pending', 'rollback_completed'
    rollback_started_at,    % Timestamp when rollback started
    rollback_completed_at,  % Timestamp when rollback completed
    rollback_errors         % List of rollback errors per queue
}).
```

#### Queue Status Record (`queue_migration_status`)
```erlang
-record(queue_migration_status, {
    queue_resource,         % Queue resource record (primary key)
    migration_id,           % Reference to parent migration
    original_queue_args,    % Store original classic queue arguments for rollback
    original_bindings,      % Store original binding details for rollback
    started_at,             % When this queue's migration started
    completed_at,           % When this queue's migration completed (null if in progress)
    total_messages,         % Total messages in queue at start
    migrated_messages,      % Number of messages migrated so far
    status,                 % Status: 'pending', 'in_progress', 'completed', 'failed', 'rollback_completed', 'rollback_failed'
    error,                  % Error details if failed (null otherwise)
    rollback_started_at,    % When rollback started for this queue
    rollback_completed_at,  % When rollback completed for this queue
    rollback_error          % Specific rollback error if any
}).
```

## Migration Process

### Prerequisites (BEFORE Migration)

1. **Cluster Health**: All cluster nodes must be running
2. **No Active Connections**: No connections/channels to target virtual host
3. **Queue Eligibility**: Only mirrored classic queues with HA policies
4. **Plugin Enabled**: `rabbitmq_queue_migration` plugin loaded
5. **AWS Configuration**: For EBS snapshots, AWS credentials and region must be configured
6. **EBS Volume**: RabbitMQ data directory must be on EBS volume (configurable device path)

### Two-Phase Migration Algorithm

```
Pre-migration Preparation:
├── Stop connections to target virtual host
├── Quiesce all cluster nodes
├── Create EBS snapshots (or tar archives for testing)
└── Validate cluster state before proceeding

Phase 1: Classic Queue → Temporary Quorum Queue
├── Create temporary quorum queue with "tmp_" prefix
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

- **Transfer Method**: Message-by-message dequeue/deliver/settle cycle
- **Progress Updates**: Configurable frequency (default: every 10 messages)
- **Timeout Handling**: 2-minute timeout per queue, 5 retries (10 minutes total)
- **Error Recovery**: Failed queues don't stop overall migration

### Queue Argument Conversion

```erlang
% Automatic argument transformations:
x-queue-type: classic → quorum                    % Required change
x-overflow: reject-publish-dlx → reject-publish   % Behavioral change!
x-max-priority: <removed>                         % Not supported in quorum
x-queue-mode: <removed>                          % Lazy mode works differently
```

## HTTP API Endpoints

### Migration Control
```
PUT  /api/queue-migration/start           # Start migration on default vhost (/)
PUT  /api/queue-migration/start/:vhost    # Start migration on specific vhost
```

### Status Monitoring
```
GET  /api/queue-migration/status          # Overall migration status + history
GET  /api/queue-migration/status/:id      # Specific migration details
```

### API Response Structure
```json
{
  "status": "cmq_qq_migration_in_progress",
  "migrations": [
    {
      "id": "base64url_encoded_migration_id",
      "display_id": "/ (2025-06-17 20:35:08) on rabbit-1@node",
      "vhost": "/",
      "started_at": "2025-06-17 20:35:08",
      "completed_at": null,
      "total_queues": 64,
      "completed_queues": 32,
      "progress_percentage": 50,
      "status": "in_progress"
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

After successful migration, these configurations should be applied:

### 1. Set Default Queue Type
```bash
curl -X PUT -u guest:guest \
    -H "Content-Type: application/json" \
    -d '{"default_queue_type":"quorum"}' \
    "http://localhost:15672/api/vhosts/%2F"
```

### 2. Enable Relaxed Argument Checks
```ini
# In rabbitmq.conf
quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true
```

This allows applications to redeclare queues with classic arguments without errors.

## Key Functions by Module

### `rqm.erl`
- `start/0`, `start/1` - Entry points for migration
- `validate_migration/1` - Pre-migration validation without starting
- `pre_migration_preparation/2` - Cluster preparation and connection blocking
- `mcq_qq_migration/3` - Core two-phase migration execution
- `post_migration_restore/3` - Restore normal operations after migration
- `start_rollback/2` - Initiate rollback process
- `handle_migration_exception/5` - Exception handling and recovery with summary logging
- `create_shovel_with_retry/4` - Retry shovel creation up to 10 times on exceptions
- `cleanup_migration_shovel/2` - Clean up shovel with exception handling (uses `case catch`)
- `verify_message_counts/4` - Verify message counts match expectations
- `check_message_count_tolerance/5` - Check over/under delivery against separate tolerances
- `check_within_tolerance/7` - Validate mismatch is within configured tolerance
- `count_errors_and_aborted/1` - Helper to count error and aborted results for logging

### `rqm_db.erl`
- `create_migration/3` - Initialize migration record
- `update_migration_with_queues/3` - Atomic queue count update
- `update_queue_status_progress/2` - Progress tracking
- `get_migration_status/0` - API status retrieval
- `store_original_queue_metadata/3` - Store rollback information
- `update_queue_status_rollback_*` - Rollback status management

### `rqm_mgmt.erl`
- `to_json/2` - Format API responses
- `accept_content/2` - Handle migration start requests
- `migration_to_json/1` - Convert internal records to JSON

### `rqm_gatherer.erl`
- `start_link/0` - Start gatherer process for collecting distributed results
- `stop/1` - Stop gatherer process
- `fork/1` - Declare intent to produce results (increment producer count)
- `finish/1` - Signal completion of work (decrement producer count)
- `in/2` - Add result to gatherer queue (async)
- `sync_in/2` - Add result to gatherer queue (sync)
- `out/1` - Retrieve result from gatherer queue (blocks if empty and producers active)

### `rqm_config.erl`
- `calculate_worker_pool_size/0` - Dynamic worker pool sizing (min of schedulers and worker_pool_max)
- `calculate_max_messages_per_queue/1` - Queue size limits based on total count
- `calculate_max_message_bytes_per_queue/1` - Byte limits for queues
- `max_queues_for_migration/0` - Maximum queue count limits
- `snapshot_mode/0` - Get snapshot mode configuration (tar or ebs)
- `ebs_volume_device/0` - Get EBS volume device path configuration
- `message_count_over_tolerance_percent/0` - Get tolerance for over-delivery (default: 5.0%)
- `message_count_under_tolerance_percent/0` - Get tolerance for under-delivery (default: 2.0%)
- `shovel_prefetch_count/0` - Get shovel prefetch count (default: 1024)

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
- `check_queue_message_count/1` - Validate message counts within limits
- `check_disk_space/1` - Disk space estimation and validation
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

### Application Environment
- `progress_update_frequency` - Messages between progress updates (default: 10)
- `worker_pool_max` - Maximum worker pool size (default: 32, capped at scheduler count)
- `rollback_on_error` - Enable automatic rollback on migration failure (default: true)
- `snapshot_mode` - Snapshot mode: `tar` (testing) or `ebs` (production EBS snapshots) (default: tar)
- `ebs_volume_device` - EBS device path for RabbitMQ data (default: "/dev/sdh")
- `max_queues_for_migration` - Maximum queues per migration (default: 500)
- `base_max_message_bytes_in_queue` - Base maximum bytes per queue (default: 512 MiB)
- `message_count_over_tolerance_percent` - Tolerance for extra messages (default: 5.0%)
- `message_count_under_tolerance_percent` - Tolerance for missing messages (default: 2.0%)
- `shovel_prefetch_count` - Shovel prefetch count for message transfer (default: 1024)
- `cleanup_snapshots_on_success` - Delete snapshots after successful migration (default: true)

### Constants (in header file)
- `QUEUE_MIGRATION_TIMEOUT_MS` - 120,000ms (2 minutes)
- `QUEUE_MIGRATION_TIMEOUT_RETRIES` - 15 retries (30 minutes total)
- `DEFAULT_PROGRESS_UPDATE_FREQUENCY` - 10 messages
- `DEFAULT_WORKER_POOL_MAX` - 32 workers (capped at scheduler count)
- `DEFAULT_ROLLBACK_ON_ERROR` - true (configurable)
- `MAX_QUEUES_FOR_MIGRATION` - 500 queues maximum
- `BASE_MAX_MESSAGES_IN_QUEUE` - 20,000 messages per queue
- `BASE_MAX_MESSAGE_BYTES_IN_QUEUE` - 512 MiB per queue
- `DISK_SPACE_SAFETY_MULTIPLIER` - 2.5x safety buffer
- `MIN_DISK_SPACE_BUFFER` - 500MB minimum free space
- `DEFAULT_EBS_VOLUME_DEVICE` - "/dev/sdh" default EBS device path
- `DEFAULT_MESSAGE_COUNT_OVER_TOLERANCE_PERCENT` - 5.0% tolerance for over-delivery
- `DEFAULT_MESSAGE_COUNT_UNDER_TOLERANCE_PERCENT` - 2.0% tolerance for under-delivery
- `DEFAULT_SHOVEL_PREFETCH_COUNT` - 1024 messages
- `DEFAULT_CLEANUP_SNAPSHOTS_ON_SUCCESS` - true

## Rollback Functionality

### Automatic Rollback
- **Trigger**: Configurable via `rollback_on_error` setting (default: enabled)
- **Scope**: Per-queue rollback when individual queue migration fails
- **State Preservation**: Original queue arguments and bindings stored before migration
- **Status Tracking**: Detailed rollback progress and error tracking

### Rollback Process
1. **Detection**: Migration failure triggers rollback evaluation
2. **State Restoration**: Recreate original classic queue with stored metadata
3. **Binding Restoration**: Restore all original queue bindings
4. **Message Recovery**: Attempt to recover messages from temporary queues
5. **Cleanup**: Remove temporary migration artifacts

### Rollback Status Tracking
- **Migration Level**: Overall rollback status in migration record
- **Queue Level**: Individual queue rollback status and errors
- **Timestamps**: Rollback start and completion times
- **Error Details**: Specific rollback failure reasons

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

### Current Test Implementation
- **Test Suite**: `unit_SUITE.erl` - Comprehensive unit test coverage with 6 test groups
- **Base64 URL Encoding**: Tests for migration ID encoding/decoding with URL-safety validation
- **Migration ID Generation**: Validation of unique ID creation and round-trip encoding
- **Configuration Validation**: Tests for balance checks and disk space estimation
- **Padding and Compatibility**: URL-safety and standard base64 comparison tests
- **Migration Checks**: Tests for leader balance, disk usage estimation, and synchronization checks
- **Test Groups**: Organized into parallel test groups for efficient execution

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

### Typical Migration Rates
- **Small queues** (empty or few messages): 3-4 queues per minute
- **Large queues** (thousands of messages): Depends on message size and queue depth
- **Parallel processing**: Multiple queues migrate simultaneously via worker pool
- **Resource usage**: Moderate memory increase during migration

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
- **Message count**: Configurable per-queue limits with scaling based on total queue count
- **Message bytes**: Configurable per-queue byte limits with scaling
- **Disk space**: 2.5x safety multiplier plus 500MB minimum buffer

## Critical Behavioral Changes

### Queue Argument Differences
1. **Overflow Behavior**: `reject-publish-dlx` → `reject-publish` (different semantics!)
2. **Priority Queues**: `x-max-priority` removed (quorum queues use high/low priority)
3. **Lazy Mode**: Removed (quorum queues handle memory management differently)

### Application Impact
- Applications may need updates for new overflow behavior
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
- **JavaScript Assets**: `queue-migration.js` and `queue-compatibility.js`
- **Management Plugin Integration**: Extends RabbitMQ management interface with new navigation items
- **Template System**: Uses RabbitMQ management plugin template system for UI rendering
- **Real-time Updates**: Web interface for monitoring migration progress with auto-refresh
- **Navigation Integration**: Adds "Queue Migration" and "Queue Compatibility" to Admin menu
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

### Validation Enhancements
- **Concurrent Snapshot Check**: Prevents migration when EBS snapshots are in progress (fixes `ConcurrentSnapshotLimitExceeded` errors)
- **Complete Validation Chain**: All checks properly integrated (shovel plugin, Khepri, snapshots, etc.)

### Error Handling Improvements
- **Shovel Creation Retry**: Retries up to 10 times on exceptions (handles transient `noproc` errors)
- **Shovel Cleanup Safety**: Uses `case catch` to handle badmatch and other cleanup exceptions gracefully
- **Reduced Log Verbosity**: Exception logs show summary counts instead of full error lists
- **Bad Key Fixes**: Removed dead code and fixed map access errors in validation handlers

### Configuration Flexibility
- **Message Count Verification**: Separate tolerances for over-delivery (5%) and under-delivery (2%)
- **Shovel Prefetch**: Configurable prefetch count for different message sizes
- **Worker Pool Maximum**: Increased to 32 (still capped at scheduler count for stability)

### Performance Validation
- **Testing Data**: Validated on m7g.large (2 vCPU) with 500-1000 queues
- **Optimal Workers**: Performance scales linearly up to scheduler count
- **Stability Limits**: Exceeding scheduler count causes network saturation and partitions

This codebase represents a production-ready, enterprise-grade solution for RabbitMQ queue migration with comprehensive safety features, detailed progress tracking, robust error handling, automatic rollback capabilities, and extensive testing infrastructure.
