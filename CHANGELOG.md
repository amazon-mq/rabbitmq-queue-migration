# Changelog

## [1.2.1](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.2.1) (2026-07-13)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.2.0...1.2.1)

**Closed issues:**

- Migration tables not replicated: disc\_copies live on a single node [\#96](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/96)

**Merged pull requests:**

- Add `release.sh` to automate the release process [\#98](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/98) ([lukebakken](https://github.com/lukebakken))
- Replicate migration tables as `disc_copies` on all cluster nodes [\#97](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/97) ([lukebakken](https://github.com/lukebakken))

## [1.2.0](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.2.0) (2026-07-13)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.1.0...1.2.0)

**Closed issues:**

- EndToEndMigrationTest message-count validation ignores tolerance and allow\_message\_ttl [\#84](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/84)
- Misleading 'shovel status format unexpected' debug log on every migration [\#83](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/83)
- Spurious per-node WARNING for queue\_names not hosted locally during successful migration [\#82](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/82)
- Add opt-in option to migrate queues with a queue-level message TTL [\#80](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/80)
- Add opt-in flag to set the vhost default queue type to `quorum` after migration [\#79](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/79)
- Document how policy applicability changes when migrating classic queues to quorum queues [\#78](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/78)
- Document post-migration queue redeclaration behavior for clients that omit `x-queue-type` [\#77](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/77)

**Merged pull requests:**

- rabbitmq-queue-migration 1.2.0 [\#95](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/95) ([lukebakken](https://github.com/lukebakken))
- Document how policy applicability changes after migration [\#92](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/92) ([lukebakken](https://github.com/lukebakken))
- Document client redeclaration behavior after migration [\#91](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/91) ([lukebakken](https://github.com/lukebakken))
- Fix per-node warning noise and misleading shovel status log [\#90](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/90) ([lukebakken](https://github.com/lukebakken))
- Make e2e message-count validation aware of `allow_message_ttl` [\#89](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/89) ([lukebakken](https://github.com/lukebakken))
- Add `set_default_queue_type` migration option [\#86](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/86) ([lukebakken](https://github.com/lukebakken))
- Add `allow_message_ttl` migration option [\#85](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/85) ([lukebakken](https://github.com/lukebakken))

## [1.1.0](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.1.0) (2026-06-08)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.6...1.1.0)

**Closed issues:**

- Review all documentation for technical correctness [\#71](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/71)
- Make plugin table init asynchronous; never abort RabbitMQ broker boot [\#69](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/69)
- Do not start plugin in Khepri environments. [\#60](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/60)

**Merged pull requests:**

- rabbitmq-queue-migration 1.1.0 [\#73](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/73) ([lukebakken](https://github.com/lukebakken))
- Review all documentation for technical correctness [\#72](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/72) ([lukebakken](https://github.com/lukebakken))
- Make plugin table init asynchronous; never abort RabbitMQ broker boot [\#70](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/70) ([lukebakken](https://github.com/lukebakken))

## [1.0.6](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.6) (2026-05-19)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.5...1.0.6)

**Closed issues:**

- Do not set default queue type to `quorum` at the end of a migration [\#63](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/63)
- Use `PROJECT_VERSION` [\#61](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/61)

**Merged pull requests:**

- docs: Add prominent Mnesia-only compatibility notice [\#59](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/59) ([sauravonwww](https://github.com/sauravonwww))
- Document OSS RabbitMQ 3.13.7 known issues [\#57](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/57) ([lukebakken](https://github.com/lukebakken))
- rabbitmq-queue-migration 1.0.6 [\#65](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/65) ([lukebakken](https://github.com/lukebakken))
- Do not set default queue type after migration [\#64](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/64) ([lukebakken](https://github.com/lukebakken))
- Use `PROJECT_VERSION` [\#62](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/62) ([lukebakken](https://github.com/lukebakken))

## [1.0.5](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.5) (2026-04-02)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.4...1.0.5)

**Merged pull requests:**

- Validate vhost binding is valid UTF-8 before processing [\#51](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/51) ([lukebakken](https://github.com/lukebakken))
- Fix documentation accuracy across all docs [\#49](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/49) ([lukebakken](https://github.com/lukebakken))

## [1.0.4](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.4) (2026-03-19)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.3...1.0.4)

**Closed issues:**

- 1.0.4 [\#42](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/42)
- Check free disk space on all cluster members [\#44](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/44)
- Check alarm statuses in "Check Compatibility" [\#43](https://github.com/amazon-mq/rabbitmq-queue-migration/issues/43)

**Merged pull requests:**

- Fix several issues in compatibility check [\#45](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/45) ([lukebakken](https://github.com/lukebakken))

## [1.0.3](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.3) (2026-03-10)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.2...1.0.3)

**Merged pull requests:**

- Handle 3-tuple EBS snapshot state in `cleanup_node_snapshots` [\#37](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/37) ([lukebakken](https://github.com/lukebakken))

## [1.0.2](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.2) (2026-02-28)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.1...1.0.2)

**Merged pull requests:**

- Preserve rollback\_pending status in migration exception handler [\#32](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/32) ([lukebakken](https://github.com/lukebakken))

## [1.0.1](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.1) (2026-02-09)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.0...1.0.1)

**Merged pull requests:**

- Add load balancer support for RabbitMQ cluster connections [\#26](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/26) ([lukebakken](https://github.com/lukebakken))
- Query quorum queue leader directly for message counts [\#27](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/27) ([lukebakken](https://github.com/lukebakken))

## [1.0.0](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.0) (2026-01-26)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/29adee4f7e44b10295bbad651c97d071b559eec5...1.0.0)

**Merged pull requests:**

- Fix all dialyzer warnings [\#19](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/19) ([lukebakken](https://github.com/lukebakken))
- Add message count tolerance for per-message TTL queues [\#18](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/18) ([lukebakken](https://github.com/lukebakken))
- Align test/integration with migration-test-setup features [\#17](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/17) ([lukebakken](https://github.com/lukebakken))
- Reorganize and improve documentation [\#16](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/16) ([lukebakken](https://github.com/lukebakken))
- Add timestamp-based unique prefixes for temporary queues [\#15](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/15) ([lukebakken](https://github.com/lukebakken))
- Add empty queue migration integration test [\#14](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/14) ([lukebakken](https://github.com/lukebakken))
- Add batch migration integration test and fix batch\_size bug [\#13](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/13) ([lukebakken](https://github.com/lukebakken))
- Fix migration skipped queue count bug and add skip unsuitable queues integration test [\#12](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/12) ([lukebakken](https://github.com/lukebakken))
- Add migration interruption integration test [\#5](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/5) ([lukebakken](https://github.com/lukebakken))
- Standardize terminology: replace "incompatible" with "unsuitable" [\#4](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/4) ([lukebakken](https://github.com/lukebakken))
- Add integration tests and documentation for 1.0.0 release [\#3](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/3) ([lukebakken](https://github.com/lukebakken))
- Update GH actions refs [\#2](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/2) ([lukebakken](https://github.com/lukebakken))
- Updates for rollback [\#1](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/1) ([lukebakken](https://github.com/lukebakken))
