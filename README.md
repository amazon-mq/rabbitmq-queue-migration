# RabbitMQ Queue Migration Plugin

A RabbitMQ plugin for migrating mirrored classic queues to quorum queues in RabbitMQ 3.13.x clusters.

## Overview

- Two-phase migration algorithm with message-by-message transfer
- Automatic binding preservation and rollback support
- Selective migration by queue name or batch size
- EBS or tar-based snapshots before migration
- HTTP API and Web UI for control and monitoring

## Prerequisites

- RabbitMQ 3.13.x
- Multi-node cluster (3+ nodes recommended)
- `rabbitmq_management` plugin enabled
- `rabbitmq_shovel` plugin enabled
- **Mnesia metadata store** (Khepri must NOT be enabled)

**Note:** The setting `quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true` must be enabled in `rabbitmq.conf` **before** starting migration. This is validated during pre-migration checks. This setting allows applications to redeclare queues with classic arguments after migration without errors.

## Installation

```shell
rabbitmq-plugins enable rabbitmq_queue_migration
```

This plugin must be enabled on all cluster nodes for consistent behavior.

## Known Limitations

### Open-Source RabbitMQ 3.13.7

Three upstream RabbitMQ issues are known to affect migrations performed by this plugin when running on open-source RabbitMQ 3.13.7. There are no effective mitigations within the plugin. Migrating empty queues prevents these issues entirely; migrating shorter queues reduces their likelihood. **Amazon MQ for RabbitMQ** broker builds on the 3.13 series include backports of the fixes.

See [OSS 3.13.7 Known Issues](docs/OSS_313_KNOWN_ISSUES.md) for details.

### Per-Message TTL

> [!WARNING]
> **This plugin cannot detect per-message TTL set by publishers.** Messages with the `expiration` property may expire during migration, causing a `message_count_mismatch` failure. This is the most common cause of a failed migration, especially on dead-letter and `_error` queues.

See [Message Loss and Verification](docs/MESSAGE_LOSS_AND_VERIFICATION.md) for why it happens and how to handle it (set a `tolerance` or drain first).

## Documentation

Once installed, follow [Running a Migration](docs/RUNNING_A_MIGRATION.md) for the full operator path. Otherwise start with the guide for what you are doing:

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

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) for contribution guidelines.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for security issue reporting.

## License

This project is licensed under the Apache-2.0 License.
