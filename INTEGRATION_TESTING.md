# RabbitMQ Queue Migration Plugin - Integration Testing

End-to-end integration testing for the `rabbitmq_queue_migration` plugin.

## Overview

The integration test suite validates the complete migration workflow by creating a 3-node RabbitMQ cluster in Docker, populating it with test data, triggering migration, and validating results.

## Prerequisites

- Docker and Docker Compose
- Java 11+ and Maven
- Make
- `/etc/hosts` entries for cluster hostname resolution

## Quick Start

### 1. Add Hostname Aliases

The test discovers cluster topology from RabbitMQ, which reports internal Docker hostnames (rmq0, rmq1, rmq2). Add aliases to resolve these to localhost:

```bash
echo "127.0.0.1 rmq0" | sudo tee -a /etc/hosts
echo "127.0.0.1 rmq1" | sudo tee -a /etc/hosts
echo "127.0.0.1 rmq2" | sudo tee -a /etc/hosts
```

### 2. Run Integration Tests

```bash
make --file integration-test.mk integration-test
```

This will:
1. Build the plugin as an ez file
2. Create custom Docker images with the plugin
3. Start a 3-node RabbitMQ cluster
4. Run end-to-end migration test (10 queues, 1000 messages)
5. Validate migration success
6. Stop the cluster

**Duration:** ~2-3 minutes

## What Gets Tested

### Test Phases

**Phase 0: Cleanup**
- Removes previous test artifacts (queues, exchanges, policies)

**Phase 1: Setup**
- Creates 10 mirrored classic queues with HA policy
- Creates 8 exchanges (topic, direct, fanout, headers)
- Creates 68 bindings with complex routing patterns
- Publishes 1000 messages with mixed sizes

**Phase 2: Pre-Migration Statistics**
- Collects baseline metrics (queue counts, message counts, bindings)

**Phase 3: Migration Trigger**
- Starts migration via `POST /api/queue-migration/start`
- Waits for migration to start (120s timeout)

**Phase 4: Progress Monitoring**
- Polls migration status every 5 seconds
- Logs progress percentage and queue completion
- Enforces 5-minute timeout

**Phase 5: Validation**
- Verifies all queues converted to quorum type
- Validates message counts match pre-migration
- Confirms bindings preserved
- Checks cluster health

### Expected Output

```
=== Phase 0: Cleaning up previous test artifacts ===
Cleanup complete

=== Phase 1: Setting up test environment ===
Creating 10 queues...
Creating 8 exchanges...
Creating 68 bindings...
Publishing 1000 messages...
Setup complete in 5165 ms

=== Phase 2: Collecting pre-migration statistics ===
Pre-migration: 10 classic queues, 1000 total messages

=== Phase 3: Triggering queue migration ===
Migration started: g2gCbgYA8U2NKJsBdxhyYWJiaXQtMUBTRUEtM0xHNUhWSlVXSks

=== Phase 4: Monitoring migration progress ===
[00:00:05] Migration in progress: 20% (2/10 queues)
[00:00:10] Migration in progress: 50% (5/10 queues)
[00:00:15] Migration in progress: 80% (8/10 queues)
[00:00:18] Migration completed: 100% (10/10 queues)

=== Phase 5: Validating migration results ===
✅ All queues converted to quorum type
✅ Message counts match (1000 messages)
✅ Bindings preserved (68 bindings)
✅ Cluster health: OK
✅ Complete end-to-end migration test finished successfully!
```

## Cluster Configuration

### Docker Compose Setup

The test uses a 3-node RabbitMQ cluster with unique ports per node:

| Node | AMQP Port | Management Port | Hostname |
|------|-----------|-----------------|----------|
| rmq0 | 5672 | 15672 | rmq0 |
| rmq1 | 5673 | 15673 | rmq1 |
| rmq2 | 5674 | 15674 | rmq2 |

**Key Design:** Each node listens on unique ports both inside and outside the container, allowing the Java test to discover and connect to all nodes via localhost with proper port mapping.

### RabbitMQ Configuration

All nodes use identical configuration:

```ini
cluster_formation.peer_discovery_backend = rabbit_peer_discovery_classic_config
cluster_formation.classic_config.nodes.1 = rabbit@rmq0
cluster_formation.classic_config.nodes.2 = rabbit@rmq1
cluster_formation.classic_config.nodes.3 = rabbit@rmq2
loopback_users = none
```

Node-specific port configuration:
- **rmq0:** `listeners.tcp.default = 5672`, `management.tcp.port = 15672`
- **rmq1:** `listeners.tcp.default = 5673`, `management.tcp.port = 15673`
- **rmq2:** `listeners.tcp.default = 5674`, `management.tcp.port = 15674`

### Enabled Plugins

```erlang
[rabbitmq_management,rabbitmq_queue_migration,rabbitmq_shovel].
```

## Manual Testing

### Start Cluster Only

```bash
make --file integration-test.mk --directory test/integration start-cluster
```

### Run Test Against Existing Cluster

```bash
cd test/integration
java -jar target/migration-test-setup-1.0.0.jar end-to-end \
  --queue-count=10 \
  --total-messages=1000 \
  --migration-timeout=300 \
  --hostname=localhost \
  --port=15672
```

### Stop Cluster

```bash
make --file integration-test.mk --directory test/integration stop-cluster
```

## Test Configuration Options

The integration test supports various configurations. See [test/integration/README.md](test/integration/README.md) for complete options including:

- Queue count (10-65,536)
- Message volume and sizes
- Exchange and binding counts
- Migration timeout
- Message distribution percentages

## Troubleshooting

### Hostname Resolution Fails

```
ERROR: node0: Temporary failure in name resolution
```

**Solution:** Add `/etc/hosts` entries for rmq0, rmq1, rmq2

### Port Already in Use

```
Error: bind: address already in use
```

**Solution:** Stop any existing RabbitMQ instances or Docker containers using ports 5672-5674 or 15672-15674

### Plugin Not Found

```
HTTP 404 Not Found: /api/queue-migration/start
```

**Solution:** Verify plugin was built and copied to Docker images. Check `docker/rmq*/` directories for `rabbitmq_queue_migration.ez`

### Docker Compose Fails

```
Error: no configuration file provided
```

**Solution:** Ensure you're running from the correct directory or using the full path to docker-compose.yml

## CI/CD Integration

The integration tests run automatically in GitHub Actions:
- On every push to main
- On every pull request
- Nightly at 16:00 UTC

See `.github/workflows/build-test.yaml` for the complete workflow.

## Performance

### Small Test (Default)
- **Configuration:** 10 queues, 1000 messages
- **Duration:** 2-3 minutes
- **Use Case:** Quick validation, CI/CD

### Custom Configurations

Modify `test/integration/Makefile` or run the JAR directly with custom parameters for different test scenarios.

## See Also

- [README.md](../../README.md) - Plugin overview and quick start
- [test/integration/README.md](test/integration/README.md) - Detailed test suite documentation
- [HTTP_API.md](../../HTTP_API.md) - Complete API reference
