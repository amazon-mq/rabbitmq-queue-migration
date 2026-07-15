# RabbitMQ Queue Migration Plugin

A RabbitMQ plugin for migrating mirrored classic queues to quorum queues in RabbitMQ 3.13.x clusters.

## Overview

- Two-phase migration algorithm with message-by-message transfer
- Automatic binding preservation and rollback support
- Selective migration by queue name or batch size
- EBS or tar-based snapshots before migration
- HTTP API and Web UI for control and monitoring

## ⚠️ Mnesia-Only Compatibility

> **This plugin requires Mnesia as the metadata store.**
>
> The plugin manages two internal Mnesia tables (`queue_migration` and `queue_migration_status`). On brokers where Mnesia is unavailable - Khepri-enabled 3.13.x brokers, or any cluster where peer Mnesia replicas are unreachable at boot - the plugin's table initialisation will fail. Starting in 1.1.0, the plugin tolerates this gracefully: the broker boots normally, the plugin's HTTP API returns `503 Service Unavailable` with a JSON body identifying initialisation status (see [HTTP API](docs/HTTP_API.md#plugin-initialization-states)), and the UI shows the same state. To recover from a `failed` state, run `rabbitmq-plugins disable rabbitmq_queue_migration` followed by `rabbitmq-plugins enable rabbitmq_queue_migration` on each broker node.
>
> **Before enabling this plugin, confirm your broker is using Mnesia (the default in RabbitMQ 3.13.x).**

## ⚠️ Broker actions during migration

Restarting any broker node, performing a full cluster reboot, or applying a maintenance window restart to a broker while a migration is in progress is not supported and is not tested. Mid-migration state is complex; recovery generally requires snapshot restore (see [Snapshots Guide](docs/SNAPSHOTS.md)). Only initiate broker restarts when no migration is in flight.

## Prerequisites

- RabbitMQ 3.13.x
- Multi-node cluster (3+ nodes recommended)
- `rabbitmq_management` plugin enabled
- `rabbitmq_shovel` plugin enabled
- **Mnesia metadata store** (Khepri must NOT be enabled)

**Note:** The setting `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true` must be enabled in `rabbitmq.conf` **before** starting migration. This is validated during pre-migration checks. This setting allows applications to redeclare queues with classic arguments after migration without errors.

## Documentation

Start with the guide for what you are doing:

**Plan a migration** - understand how it works and what will bite you
- [Migration Guide](docs/MIGRATION_GUIDE.md) - two-phase process, queue eligibility, argument conversion, policy and client-redeclaration behavior
- [Message Loss and Verification](docs/MESSAGE_LOSS_AND_VERIFICATION.md) - message-count verification, tolerance, and per-message TTL (the most common cause of a failed migration)

**Run a migration** - the operator path, start to finish
- [Running a Migration](docs/RUNNING_A_MIGRATION.md) - check, start, monitor, interrupt, and every start option in one place
- [Skip Unsuitable Queues](docs/SKIP_UNSUITABLE_QUEUES.md) - migrate the majority now and address problem queues later

**Recover from a problem**
- [Troubleshooting](docs/TROUBLESHOOTING.md) - error messages, diagnostics, and recovery

**Reference**
- [HTTP API](docs/HTTP_API.md) - complete request/response schemas
- [API Examples](docs/API_EXAMPLES.md) - practical API usage examples
- [Configuration](docs/CONFIGURATION.md) - all configuration parameters and defaults
- [Snapshots](docs/SNAPSHOTS.md) - snapshot modes and configuration
- [EC2 Setup](docs/EC2_SETUP.md) - AWS EC2 and IAM configuration when EBS snapshots are used
- [Performance](docs/PERFORMANCE.md) - real-world migration timing data
- [OSS 3.13.7 Known Issues](docs/OSS_313_KNOWN_ISSUES.md) - upstream issues affecting open-source builds

See [the `docs/` directory](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/main/docs).

## ⚠️ Known Limitations

### Open-Source RabbitMQ 3.13.7

Three upstream RabbitMQ issues are known to affect migrations performed by this
plugin when running on open-source RabbitMQ 3.13.7. There are no effective
mitigations within the plugin. Migrating empty queues prevents these issues
entirely; migrating shorter queues reduces their likelihood. **Amazon MQ for
RabbitMQ** broker builds on the 3.13 series include backports of the fixes.

See [OSS 3.13.7 Known Issues](docs/OSS_313_KNOWN_ISSUES.md) for details.

### Per-Message TTL

**This plugin cannot detect per-message TTL set by publishers.** Messages with the `expiration` property may expire during migration, causing a `message_count_mismatch` failure. This is the most common cause of a failed migration, especially on dead-letter and `_error` queues.

See [Message Loss and Verification](docs/MESSAGE_LOSS_AND_VERIFICATION.md) for why it happens and how to handle it (set a `tolerance` or drain first).

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

To skip unsuitable queues, migrate in batches, migrate specific queues by name, set a message-count `tolerance`, or set the vhost default queue type, see [Running a Migration](docs/RUNNING_A_MIGRATION.md#start-options) for every start option.

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

## Troubleshooting

For troubleshooting guidance, see [Troubleshooting Guide](docs/TROUBLESHOOTING.md).

Quick checks:
- **Migration fails to start:** Run compatibility check to identify issues
- **Migration stuck:** Check status and broker logs
- **Rollback required:** Manual cleanup needed (automatic rollback available on Amazon MQ for RabbitMQ only)

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) for contribution guidelines.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for security issue reporting.

## License

This project is licensed under the Apache-2.0 License.
