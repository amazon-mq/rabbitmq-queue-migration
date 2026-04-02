# Changelog

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



\* *This Changelog was automatically generated by [github_changelog_generator](https://github.com/github-changelog-generator/github-changelog-generator)*
