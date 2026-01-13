# RabbitMQ Queue Migration Plugin

A RabbitMQ plugin for migrating mirrored classic queues to quorum queues in RabbitMQ 3.13.x clusters.

## Overview

This plugin provides a safe, automated solution for migrating classic queues to quorum queues with:
- Two-phase migration algorithm (classic → temporary quorum → final quorum)
- Message-by-message transfer with progress tracking
- Automatic binding preservation
- Snapshot support for rollback capability
- HTTP API for control and monitoring
- Web UI integration with the RabbitMQ Management Plugin

## Features

- **Safe Migration**: Pre-migration validation checks ensure cluster readiness
- **Progress Tracking**: Real-time progress monitoring via HTTP API
- **Distributed Execution**: Leverages all cluster nodes for parallel processing
- **Rollback Support**: Tracks rollback state for failed migrations
- **Snapshot Integration**: Creates EBS or tar-based snapshots before migration
- **Web UI**: Management plugin integration for visual monitoring
- **Default Queue Type:** The plugin automatically sets the vhost's default queue type to `quorum` upon successful migration completion.

## Prerequisites

- RabbitMQ 3.13.x
- Multi-node cluster (3+ nodes recommended)
- `rabbitmq_management` plugin enabled
- `rabbitmq_shovel` plugin enabled
- Khepri database disabled (classic Mnesia required)

**Note:** The setting `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true` must be enabled in `rabbitmq.conf` **before** starting migration. This is validated during pre-migration checks. This setting allows applications to redeclare queues with classic arguments after migration without errors.

## Installation

```shell
rabbitmq-plugins enable rabbitmq_queue_migration
```

Enable on all cluster nodes for consistent behavior.

## Quick Start

### 1. Validate Migration Readiness

Check if your cluster is ready for migration:

```bash
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2F
```

### 2. Start Migration

Migrate all mirrored classic queues on the default vhost:

```bash
curl -u guest:guest -X PUT http://localhost:15672/api/queue-migration/start
```

To skip unsuitable queues instead of blocking migration:

```bash
curl -u guest:guest -X PUT \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

### 3. Monitor Progress

Check migration status:

```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/status
```

See [HTTP_API.md](HTTP_API.md) for complete API reference.

## Migration Process

### Pre-Migration Validation

The plugin performs comprehensive checks before starting migration:

**System-Level Checks** (always block migration):
1. **Plugin Requirements**: Validates `rabbitmq_shovel` is enabled and Khepri is disabled
2. **Configuration**: Checks `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration` is enabled
3. **Queue Balance**: Ensures queue leaders are balanced across nodes
4. **Disk Space**: Estimates required disk space and verifies availability
5. **System Health**: Checks for active alarms and memory pressure
6. **Snapshot Availability**: Verifies no concurrent EBS snapshots in progress
7. **Cluster Health**: Validates no partitions and all nodes are up

**Queue-Level Checks** (can be skipped with `skip_unsuitable_queues` option):
1. **Queue Synchronization**: Verifies all queue mirrors are synchronized
2. **Queue Suitability**: Confirms queues don't have unsuitable arguments (e.g., `reject-publish-dlx`)
3. **Message Limits**: Validates queue message counts and bytes are within limits

When `skip_unsuitable_queues` is enabled, queues that fail queue-level checks are skipped during migration instead of blocking the entire process.

### Two-Phase Migration

**Phase 1: Classic → Temporary Quorum**
1. Create temporary quorum queue with `tmp_` prefix
2. Copy all bindings from classic to temporary queue
3. Migrate messages one-by-one
4. Delete original classic queue

**Phase 2: Temporary → Final Quorum**
1. Create final quorum queue with original name
2. Copy all bindings from temporary to final queue
3. Migrate messages from temporary to final queue
4. Delete temporary queue

### Connection Handling During Migration

**Pre-Migration Preparation:**
- Non-HTTP listeners (AMQP, MQTT, STOMP) are suspended broker-wide
- All existing client connections are closed
- HTTP API remains available for monitoring migration progress

**During Migration:**
- Clients cannot connect to the broker (non-HTTP protocols)
- HTTP API remains accessible for monitoring
- Migration progress can be monitored via HTTP API

**Post-Migration:**
- All listeners are restored automatically
- Clients can reconnect to the broker
- Migrated queues are now quorum queues with preserved bindings and messages

**Important:** The connection suspension affects the entire broker, not just the vhost being migrated. Plan migration windows accordingly.

### Queue Eligibility

A queue is eligible for migration if:
- Queue type is `rabbit_classic_queue`
- Queue has HA policy applied (mirrored)
- Queue is not exclusive

### Automatic Argument Conversion

The plugin automatically converts or removes queue arguments during migration:

| Classic Queue Argument | Quorum Queue Equivalent | Notes |
|------------------------|-------------------------|-------|
| `x-queue-type: classic` | `x-queue-type: quorum` | Required conversion |
| `x-max-priority` | *removed* | Not supported in quorum queues |
| `x-queue-mode` | *removed* | Lazy mode doesn't apply |
| `x-queue-master-locator` | *removed* | Classic queue specific |
| `x-queue-version` | *removed* | Classic queue specific |

**Important:** Queues with `x-overflow: reject-publish-dlx` are **not eligible** for migration. This argument is unsuitable with quorum queues and will cause the compatibility check to fail. Quorum queues support `drop-head` and `reject-publish`, but `reject-publish` does not provide dead lettering like `reject-publish-dlx` does in classic queues.

## Configuration

### Application Environment Variables

The plugin supports the following configuration options via `advanced.config`:

```erlang
[
  {rabbitmq_queue_migration, [
    %% Progress update frequency (messages between database updates)
    %% Range: 1-4096, Default: 10
    {progress_update_frequency, 10},

    %% Worker pool size (capped at scheduler count for stability)
    %% Range: 1-32, Default: 32
    {worker_pool_max, 32},

    %% Maximum queues per migration
    %% Default: 500
    {max_queues_for_migration, 500},

    %% Base maximum message bytes per queue (scales with queue count)
    %% Default: 536870912 (512 MiB)
    {base_max_message_bytes_in_queue, 536870912},

    %% Disk space safety multiplier
    %% Default: 2.5
    {disk_space_safety_multiplier, 2.5},

    %% Minimum free disk space buffer (bytes)
    %% Default: 500000000 (500MB)
    {min_disk_space_buffer, 500000000},

    %% Maximum memory usage percentage
    %% Range: 1-100, Default: 40
    {max_memory_usage_percent, 40},

    %% Message count verification tolerances
    %% Over-delivery tolerance (extra messages), Default: 5.0%
    {message_count_over_tolerance_percent, 5.0},
    %% Under-delivery tolerance (missing messages), Default: 2.0%
    {message_count_under_tolerance_percent, 2.0},

    %% Shovel prefetch count for message transfer
    %% Default: 1024
    {shovel_prefetch_count, 1024},

    %% Snapshot mode: tar (testing) or ebs (production)
    %% Default: tar
    {snapshot_mode, tar},

    %% EBS volume device path (for EBS snapshots)
    %% Default: "/dev/sdh"
    {ebs_volume_device, "/dev/sdh"},

    %% Cleanup snapshots on successful migration
    %% Default: true
    {cleanup_snapshots_on_success, true}
  ]}
].
```

**Note:** Most users should not need to change these defaults. They are tuned for typical production workloads based on extensive testing with 500-1000 queues on m7g.large instances.

## Snapshot Support

The plugin creates snapshots before migration to enable rollback in case of failure. Two modes are supported:

### Tar Mode (Development/Testing)

Creates tar.gz archives of the RabbitMQ data directory.

**Configuration** (in `advanced.config`):
```erlang
{snapshot_mode, tar}
```

**Snapshot Location:**
```
/tmp/rabbitmq_migration_snapshots/{ISO8601_timestamp}/{node_name}.tar.gz
```

**Example:**
```
/tmp/rabbitmq_migration_snapshots/2025-12-21T17:30:00Z/rabbit@node1.tar.gz
```

**Cleanup:** Controlled by `cleanup_snapshots_on_success` setting (default: `true`).

### EBS Mode (Production)

Creates real AWS EBS snapshots using the EC2 API.

**Configuration** (in `advanced.config`):
```erlang
{snapshot_mode, ebs},
{ebs_volume_device, "/dev/sdh"}
```

**Requirements:**
- RabbitMQ data directory must be on an EBS volume
- EBS volume must be attached at the configured device path (default: `/dev/sdh`)
- EC2 instance must have IAM permissions:
  - `ec2:CreateSnapshot`
  - `ec2:DescribeVolumes`
  - `ec2:DescribeSnapshots`
  - `ec2:CreateTags`
- AWS credentials configured (EC2 instance role recommended)

**Snapshot Naming:**
```
Description: "RabbitMQ migration snapshot {ISO8601_timestamp} on {node_name}"
```

**Cleanup:** Controlled by `cleanup_snapshots_on_success` setting (default: `true`).

See [EC2_SETUP.md](EC2_SETUP.md) for detailed IAM role configuration and setup instructions.

## Testing

### Unit Tests

Run the Erlang unit test suite:

```bash
make tests
```

### Integration Tests

Run end-to-end integration tests with a 3-node Docker cluster:

```bash
# Add hostname aliases (required for cluster discovery)
echo "127.0.0.1 rmq0" | sudo tee -a /etc/hosts
echo "127.0.0.1 rmq1" | sudo tee -a /etc/hosts
echo "127.0.0.1 rmq2" | sudo tee -a /etc/hosts

# Run integration tests
make --file integration-test.mk integration-test
```

See [INTEGRATION_TESTING.md](INTEGRATION_TESTING.md) for detailed testing documentation.

## Limitations

### Queue Limits
- Maximum 500 queues per migration
- Maximum 15,000 messages per queue
- Configurable via safety checks

### Not Supported
- Exclusive queues (skipped)
- Non-mirrored classic queues (skipped)
- Queues without HA policies (skipped)

## Troubleshooting

### Migration Fails to Start

**Check validation errors:**
```bash
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2F
```

Common issues:
- `rabbitmq_shovel` plugin not enabled
- Khepri database enabled (must be disabled)
- Queue leaders not balanced
- Insufficient disk space

### Migration Stuck

**Check migration status:**
```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/status
```

**Check RabbitMQ logs:**
```bash
# Look for migration progress and errors
tail -f /var/log/rabbitmq/rabbit@hostname.log | grep rqm
```

### Rollback Required

If migration fails and enters `rollback_pending` state, manual intervention is required:

1. Check migration status to get snapshot IDs
2. Stop RabbitMQ on all nodes
3. Restore from snapshots (EBS or tar)
4. Restart RabbitMQ cluster

## Performance

### Typical Migration Rates
- **Small queues** (empty or few messages): 3-4 queues per minute
- **Large queues** (thousands of messages): Depends on message size and queue depth
- **Parallel processing**: Multiple queues migrate simultaneously

### Resource Usage
- **Memory**: Moderate increase during migration
- **Disk**: Requires 2.5x current queue data size
- **CPU**: Scales with worker pool size

## Web UI

The plugin extends the RabbitMQ Management UI with:
- **Queue Migration** tab in Admin section
- Real-time progress monitoring
- Migration history
- Per-queue status details

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## Documentation

- [HTTP_API.md](HTTP_API.md) - Complete HTTP API reference with examples
- [INTEGRATION_TESTING.md](INTEGRATION_TESTING.md) - Integration testing guide
- [AGENTS.md](AGENTS.md) - Comprehensive technical deep-dive and architecture
- [EC2_SETUP.md](EC2_SETUP.md) - AWS EC2 and IAM configuration guide

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for security issue reporting.

## License

This project is licensed under the Apache-2.0 License.
