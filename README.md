# RabbitMQ Queue Migration Plugin

A RabbitMQ plugin for migrating mirrored classic queues to quorum queues in RabbitMQ 3.13.x clusters.

## Overview

A RabbitMQ plugin for migrating mirrored classic queues to quorum queues in RabbitMQ 3.13.x clusters.

- Two-phase migration algorithm with message-by-message transfer
- Automatic binding preservation and rollback support
- Selective migration by queue name or batch size
- EBS or tar-based snapshots before migration
- HTTP API and Web UI for control and monitoring
- Sets vhost default queue type to `quorum` on completion

## Prerequisites

- RabbitMQ 3.13.x
- Multi-node cluster (3+ nodes recommended)
- `rabbitmq_management` plugin enabled
- `rabbitmq_shovel` plugin enabled
- Khepri database disabled (classic Mnesia required)

**Note:** The setting `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true` must be enabled in `rabbitmq.conf` **before** starting migration. This is validated during pre-migration checks. This setting allows applications to redeclare queues with classic arguments after migration without errors.

## Getting Started

- [README](README.md) - This document! Overview, installation, and quick start
- [Migration Guide](docs/MIGRATION_GUIDE.md) - Migration process and validation
- [Snapshots Guide](docs/SNAPSHOTS.md) - Snapshot modes and configuration
- [HTTP API](docs/HTTP_API.md) - Complete HTTP API reference
- [API Examples](docs/API_EXAMPLES.md) - Practical API usage examples
- [Configuration Reference](docs/CONFIGURATION.md) - Configuration parameter reference
- [EC2 Setup](docs/EC2_SETUP.md) - AWS EC2 and IAM configuration if EBS snapshots are used

See [the `docs/` directory](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/main/docs).

## ⚠️ Important: Per-Message TTL Limitation

**This plugin CANNOT detect per-message TTL set by publishers.**

If your publishers set the `expiration` property on individual messages (see [Per-Message TTL in Publishers](https://www.rabbitmq.com/docs/3.13/ttl#per-message-ttl-in-publishers)), messages may expire during migration, causing message count differences between source and destination queues.

The plugin detects and blocks migration for queues with:
- `x-message-ttl` queue argument
- `message-ttl` policy

However, per-message TTL is set on each message by publishers and is **not visible at the queue level**.

### Solution: Message Count Tolerance

Use the `tolerance` parameter to allow migrations to succeed despite message count differences caused by TTL expiration:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"tolerance": 10.0}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

The tolerance is a **per-queue percentage** (0.0-100.0). A queue passes verification if the message count difference is within the tolerance. For example, with `tolerance: 10.0`, a queue with 100 source messages passes if the destination has 90-100 messages.

**Recommendations:**
- Set tolerance slightly higher than your expected message loss rate
- If 5% of messages have short TTLs, use `tolerance: 10.0` for safety margin
- Monitor migration logs for "within tolerance" warnings to verify expected behavior

See [HTTP API](docs/HTTP_API.md#start-migration) for complete API reference.

## Web UI

The plugin extends the RabbitMQ Management UI with:
- **Queue Migration** tab in Admin section
- Real-time progress monitoring
- Migration history
- Per-queue status details

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

See [HTTP API](docs/HTTP_API.md) for complete API reference.

## Migration Process

The plugin uses a two-phase migration process to safely convert classic queues to quorum queues:

1. **Phase 1:** Classic → Temporary Quorum (with `tmp_<timestamp>_` prefix)
2. **Phase 2:** Temporary → Final Quorum (original name)

This approach ensures no name conflicts and allows safe rollback if issues occur. Empty queues use a fast path that skips the two-phase process.

**Important:** Migration suspends non-HTTP listeners broker-wide and closes all client connections. Plan migration windows accordingly.

See [Migration Guide](docs/MIGRATION_GUIDE.md) for complete details on the migration process, validation checks, queue eligibility, and argument conversion.

## Configuration

The plugin provides extensive configuration options for tuning performance, disk space management, and message count verification.

See [Configuration Reference](docs/CONFIGURATION.md) for complete configuration reference including all parameters, defaults, and tuning examples.

## Snapshot Support

The plugin creates snapshots before migration to enable rollback if issues occur. Three modes are supported:

- **EBS Mode** (default) - AWS EBS snapshots for production
- **Tar Mode** - Tar archives for development/testing
- **None Mode** - Disabled (snapshots handled externally)

See [Snapshots Guide](docs/SNAPSHOTS.md) for complete snapshot configuration and [EC2 Setup](docs/EC2_SETUP.md) for AWS IAM setup.

## Testing

The plugin includes comprehensive unit tests and integration tests.

See [Integration Testing](docs/INTEGRATION_TESTING.md) for test setup and execution instructions.

## Troubleshooting

For troubleshooting guidance, see [Troubleshooting Guide](docs/TROUBLESHOOTING.md).

Quick checks:
- **Migration fails to start:** Run compatibility check to identify issues
- **Migration stuck:** Check status and broker logs
- **Rollback required:** Manual cleanup needed (automatic rollback not implemented)

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) for contribution guidelines.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for security issue reporting.

## License

This project is licensed under the Apache-2.0 License.
