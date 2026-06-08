# Known Issues on Open-Source RabbitMQ 3.13.7

This document describes upstream issues that affect migrations performed by this
plugin when running on open-source RabbitMQ 3.13.7 (the final release in the
3.13.x series).

---

## Overview

This plugin targets RabbitMQ 3.13.x because mirrored classic queues (the
subject of migration) are deprecated in 3.13.x and removed in 4.0; 3.13.x
is the final series in which they can be migrated. During development and
testing of the plugin, three upstream RabbitMQ issues were observed to occur
more frequently under migration workloads. The fixes for these issues are not
present in any open-source 3.13.x release.

---

## Affected Issues

The following upstream issues can affect migrations on open-source RabbitMQ
3.13.7:

- [rabbitmq/rabbitmq-server#13758](https://github.com/rabbitmq/rabbitmq-server/issues/13758)
- [rabbitmq/rabbitmq-server#14181](https://github.com/rabbitmq/rabbitmq-server/discussions/14181)
- [rabbitmq/rabbitmq-server#15229](https://github.com/rabbitmq/rabbitmq-server/pull/15229)

All three affect classic queues and the shovel subsystem, both of which are
exercised heavily during migration.

---

## Mitigations

There are no effective mitigations available within the plugin or its
configuration.

---

## Operational Best Practices

Migrating empty queues will prevent these issues entirely, and is also the
fastest way to complete migration. Migrating shorter queues reduces the
likelihood of encountering these issues. Where possible, drain queues before
migration, or schedule migration for a time when queue depth is low.

---

## Resolution Paths

- **Amazon MQ for RabbitMQ** broker builds on the 3.13 series include
  backports of the fixes for these issues.
- Operators with the necessary Erlang and RabbitMQ build expertise may
  backport the upstream fixes to their own 3.13.7 build.

---

## Related Documentation

- [Migration Guide](MIGRATION_GUIDE.md)
- [Troubleshooting Guide](TROUBLESHOOTING.md)
