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
- **Selective Migration**: Migrate specific queues by name via HTTP API
- **Interruption Support**: Gracefully interrupt running migrations via HTTP API or management UI
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

This plugin must be enabled on all cluster nodes for consistent behavior.

## Quick Start

### 1. Validate Migration Readiness

Check if your cluster is ready for migration:

```bash
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2F
```

### 2. Start Migration

Migrate all mirrored classic queues on the default vhost (`/`):

```bash
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start
```

To migrate a specific vhost, include it in the URL path (URL-encoded):

```bash
# Migrate vhost "/production"
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start/%2Fproduction
```

> **Note:** The vhost must be specified in the URL path, not in the request body.

To skip unsuitable queues instead of blocking migration:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

To migrate queues in batches (useful for large vhosts):

```bash
# Migrate 10 queues at a time, smallest first
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 10, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start/%2Fmy-vhost
```

To migrate specific queues by name:

```bash
# Migrate only specified queues
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["orders", "payments", "notifications"]}' \
  http://localhost:15672/api/queue-migration/start/%2Fproduction

# queue_names takes precedence over batch_size
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["queue1", "queue2"], "batch_size": 10}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

> **Note:** When `queue_names` is specified, `batch_size` and `batch_order` are ignored. Non-existent or ineligible queues are logged as warnings and skipped. If all specified queues are non-existent or ineligible, the migration fails with HTTP 400.

### 3. Monitor Progress

Check migration status:

```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/status
```

### 4. Interrupt Migration (Optional)

Gracefully interrupt a running migration:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/interrupt/:migration_id
```

In-flight queue migrations complete while remaining queues are skipped. The migration ends with status `interrupted`.

See [docs/HTTP_API.md](docs/HTTP_API.md) for complete API reference.

## Migration Process

The plugin uses a two-phase migration process to safely convert classic queues to quorum queues:

1. **Phase 1:** Classic → Temporary Quorum (with `tmp_<timestamp>_` prefix)
2. **Phase 2:** Temporary → Final Quorum (original name)

This approach ensures no name conflicts and allows safe rollback if issues occur. Empty queues use a fast path that skips the two-phase process.

**Important:** Migration suspends non-HTTP listeners broker-wide and closes all client connections. Plan migration windows accordingly.

See [docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md) for complete details on the migration process, validation checks, queue eligibility, and argument conversion.

## Configuration

The plugin provides extensive configuration options for tuning performance, disk space management, and message count verification.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for complete configuration reference including all parameters, defaults, and tuning examples.

## Snapshot Support

The plugin creates snapshots before migration to enable rollback in case of failure. Two modes are supported:

### Tar Mode (Development/Testing)

Creates tar.gz archives of the RabbitMQ data directory. Use this mode for
development and testing environments.

**Configuration** (in `rabbitmq.conf`):
```ini
queue_migration.snapshot_mode = tar
```

Or in `advanced.config`:
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

### EBS Mode (Production - Default)

Creates real AWS EBS snapshots using the EC2 API. This is the default mode
for production deployments.

**Configuration** (optional, these are the defaults):
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

See [docs/EC2_SETUP.md](docs/EC2_SETUP.md) for detailed IAM role configuration and setup instructions.

### None Mode (Disabled)

Disables snapshot creation entirely. Use this mode when snapshots are not
needed or are handled externally.

**Configuration** (in `rabbitmq.conf`):
```ini
queue_migration.snapshot_mode = none
```

Or in `advanced.config`:
```erlang
{snapshot_mode, none}
```

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

See [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md) for detailed testing documentation.

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

## Web UI

The plugin extends the RabbitMQ Management UI with:
- **Queue Migration** tab in Admin section
- Real-time progress monitoring
- Migration history
- Per-queue status details

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## Documentation

### Getting Started
- [README.md](README.md) - Overview, installation, and quick start
- [docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md) - Migration process and validation
- [docs/HTTP_API.md](docs/HTTP_API.md) - Complete HTTP API reference
- [docs/API_EXAMPLES.md](docs/API_EXAMPLES.md) - Practical API usage examples
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) - Configuration parameter reference

### Feature Guides
- [docs/SKIP_UNSUITABLE_QUEUES.md](docs/SKIP_UNSUITABLE_QUEUES.md) - Skip unsuitable queues feature guide
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Common issues and solutions

### Technical Documentation
- [AGENTS.md](AGENTS.md) - Architecture and implementation details
- [docs/VALIDATION_CHAIN.md](docs/VALIDATION_CHAIN.md) - Validation chain architecture

### Testing and Deployment
- [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md) - Integration testing guide
- [docs/EC2_SETUP.md](docs/EC2_SETUP.md) - AWS EC2 and IAM configuration

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for security issue reporting.

## License

This project is licensed under the Apache-2.0 License.
