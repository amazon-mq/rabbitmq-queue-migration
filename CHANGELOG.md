# Changelog

## [1.0.1](https://github.com/amazon-mq/rabbitmq-queue-migration/tree/1.0.1) (2026-02-09)

[Full Changelog](https://github.com/amazon-mq/rabbitmq-queue-migration/compare/1.0.0...1.0.1)

**Merged pull requests:**

- Query quorum queue leader directly for message counts [\#27](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/27) ([lukebakken](https://github.com/lukebakken))
- Add load balancer support for RabbitMQ cluster connections [\#26](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/26) ([lukebakken](https://github.com/lukebakken))
- Bump ch.qos.logback:logback-classic from 1.5.25 to 1.5.27 in /test/integration [\#25](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/25) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump org.apache.maven.plugins:maven-compiler-plugin from 3.14.1 to 3.15.0 in /test/integration [\#24](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/24) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump actions/cache from 5.0.2 to 5.0.3 [\#23](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/23) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump actions/setup-java from 5.1.0 to 5.2.0 [\#21](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/21) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump actions/checkout from 6.0.1 to 6.0.2 [\#20](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/20) ([dependabot[bot]](https://github.com/apps/dependabot))

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
- Bump org.apache.maven.plugins:maven-surefire-plugin from 3.5.2 to 3.5.4 in /test/integration [\#11](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/11) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump ch.qos.logback:logback-classic from 1.5.22 to 1.5.25 in /test/integration [\#10](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/10) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump org.apache.maven.plugins:maven-compiler-plugin from 3.13.0 to 3.14.1 in /test/integration [\#9](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/9) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump org.apache.maven.plugins:maven-shade-plugin from 3.6.0 to 3.6.1 in /test/integration [\#8](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/8) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump actions/cache from 5.0.1 to 5.0.2 [\#7](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/7) ([dependabot[bot]](https://github.com/apps/dependabot))
- Bump com.fasterxml.jackson.core:jackson-databind from 2.20.1 to 2.21.0 in /test/integration [\#6](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/6) ([dependabot[bot]](https://github.com/apps/dependabot))
- Add migration interruption integration test [\#5](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/5) ([lukebakken](https://github.com/lukebakken))
- Standardize terminology: replace "incompatible" with "unsuitable" [\#4](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/4) ([lukebakken](https://github.com/lukebakken))
- Add integration tests and documentation for 1.0.0 release [\#3](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/3) ([lukebakken](https://github.com/lukebakken))
- Update GH actions refs [\#2](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/2) ([lukebakken](https://github.com/lukebakken))
- Updates for rollback [\#1](https://github.com/amazon-mq/rabbitmq-queue-migration/pull/1) ([lukebakken](https://github.com/lukebakken))
