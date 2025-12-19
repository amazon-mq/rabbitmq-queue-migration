# RabbitMQ Queue Migration - Integration Tests

End-to-end integration testing for the `rabbitmq_queue_migration` plugin.

## Overview

This test suite creates a complete RabbitMQ test environment, triggers queue migration, monitors progress, and validates results. It provides comprehensive validation of the migration plugin's functionality.

## Prerequisites

- Java 11 or higher
- Maven 3.6+ (or use included Maven wrapper)
- Running RabbitMQ cluster with:
  - `rabbitmq_queue_migration` plugin enabled
  - `rabbitmq_management` plugin enabled
  - Default credentials (guest/guest) or custom credentials

## Quick Start

### Build
```bash
./mvnw clean package
```

### Run End-to-End Test (Default Configuration)
```bash
java -jar target/migration-test-setup-1.0.0.jar end-to-end
```

This will:
1. Clean up any previous test artifacts
2. Create 10 mirrored classic queues with 5,500 messages
3. Trigger migration via HTTP API
4. Monitor migration progress
5. Validate all queues converted to quorum type
6. Verify message counts and bindings preserved

## Test Configurations

### Small Test (Quick Validation)
```bash
java -jar target/migration-test-setup-1.0.0.jar end-to-end \
  --queue-count=10 \
  --total-messages=1000 \
  --migration-timeout=300
```
**Duration:** ~2-3 minutes

### Medium Test (Standard Validation)
```bash
java -jar target/migration-test-setup-1.0.0.jar end-to-end \
  --queue-count=32 \
  --total-messages=50000 \
  --migration-timeout=1800
```
**Duration:** ~10-15 minutes

### Large Test (Performance Validation)
```bash
java -jar target/migration-test-setup-1.0.0.jar end-to-end \
  --queue-count=128 \
  --total-messages=2000000 \
  --migration-timeout=7200
```
**Duration:** ~1-2 hours

## Configuration Options

### Core Parameters
| Option | Description | Default |
|--------|-------------|---------|
| `--queue-count=N` | Number of queues to create | 10 |
| `--total-messages=N` | Total messages across all queues | 5,500 |
| `--migration-timeout=N` | Migration timeout in seconds | 3600 |
| `--exchange-count=N` | Number of topic exchanges | 5 |
| `--bindings-per-queue=N` | Bindings per queue | 6 |

### Message Configuration
| Option | Description | Default |
|--------|-------------|---------|
| `--message-distribution=X,Y,Z` | Message size percentages (must sum to 100) | 70,20,10 |
| `--message-sizes=S,M,L` | Message sizes in bytes | 1024,102400,1048576 |
| `--confirmation-window=N` | Confirmations per publishing thread | 4 |

### Connection Configuration
| Option | Description | Default |
|--------|-------------|---------|
| `--amqp-uris=URIS` | Comma-separated AMQP URIs | localhost:5672,5673,5674 |
| `--http-uris=URIS` | Comma-separated HTTP URIs | localhost:15672,15673,15674 |
| `--hostname=HOST` | Single hostname (alternative) | localhost |
| `--port=PORT` | HTTP port (alternative) | 15672 |

### Test Control
| Option | Description | Default |
|--------|-------------|---------|
| `--skip-cleanup` | Skip cleanup phase | false |
| `--skip-setup` | Skip setup phase | false |
| `--no-ha` | Disable HA/mirroring | false |

## Multi-Node Cluster Example

```bash
java -jar target/migration-test-setup-1.0.0.jar end-to-end \
  --amqp-uris="amqp://admin:secret@node1:5672,amqp://admin:secret@node2:5672,amqp://admin:secret@node3:5672" \
  --http-uris="http://admin:secret@node1:15672,http://admin:secret@node2:15672,http://admin:secret@node3:15672" \
  --queue-count=30 \
  --total-messages=50000
```

## Test Phases

### Phase 0: Cleanup
Removes previous test artifacts (queues, exchanges, policies)

### Phase 1: Setup
- Creates mirrored classic queues with HA policy
- Creates topic, direct, fanout, and headers exchanges
- Creates complex binding patterns
- Publishes messages with configurable sizes

### Phase 2: Pre-Migration Statistics
Collects baseline metrics (queue counts, message counts, bindings)

### Phase 3: Migration Trigger
Starts migration via `PUT /api/queue-migration/start`

### Phase 4: Progress Monitoring
Monitors migration status every 5 seconds until completion

### Phase 5: Validation
- Verifies all queues converted to quorum type
- Validates message counts match pre-migration
- Confirms bindings preserved
- Checks cluster health

## Expected Output

```
=== Phase 0: Cleaning up previous test artifacts ===
Cleanup complete

=== Phase 1: Setting up test environment ===
Creating 10 queues...
Creating 8 exchanges...
Creating 68 bindings...
Publishing 5500 messages...
Setup complete in 5165 ms

=== Phase 2: Collecting pre-migration statistics ===
Pre-migration: 10 classic queues, 5500 total messages

=== Phase 3: Triggering queue migration ===
Migration started: g2gCbgYA8U2NKJsBdxhyYWJiaXQtMUBTRUEtM0xHNUhWSlVXSks

=== Phase 4: Monitoring migration progress ===
[00:00:05] Migration in progress: 20% (2/10 queues)
[00:00:10] Migration in progress: 50% (5/10 queues)
[00:00:15] Migration in progress: 80% (8/10 queues)
[00:00:18] Migration completed: 100% (10/10 queues)

=== Phase 5: Validating migration results ===
✅ All queues converted to quorum type
✅ Message counts match (5500 messages)
✅ Bindings preserved (68 bindings)
✅ Cluster health: OK

✅ Complete end-to-end migration test finished successfully!
```

## Troubleshooting

### Connection Refused
```
Connection refused to localhost:15672
```
**Solution:** Verify RabbitMQ is running and Management Plugin enabled

### Plugin Not Enabled
```
HTTP 404 Not Found: /api/queue-migration/start
```
**Solution:** Enable plugin: `rabbitmq-plugins enable rabbitmq_queue_migration`

### Migration Timeout
```
❌ Migration did not complete within 3600 seconds
```
**Solution:** Increase timeout with `--migration-timeout=7200`

### Authentication Failure
```
HTTP 401 Unauthorized
```
**Solution:** Check username/password or specify with URIs

## Running Tests Only

### Setup Environment Only
```bash
java -jar target/migration-test-setup-1.0.0.jar setup-env \
  --queue-count=20 \
  --total-messages=10000
```

### Cleanup Environment Only
```bash
java -jar target/migration-test-setup-1.0.0.jar cleanup-env \
  --queue-count=20
```

### Test Connection Only
```bash
java -jar target/migration-test-setup-1.0.0.jar --test-connection
```

## Development

### Run Tests
```bash
./mvnw test
```

### Build Without Tests
```bash
./mvnw package -DskipTests
```

### Run Specific Test Class
```bash
./mvnw test -Dtest=MessageGeneratorTest
```

## Logging

- **Console:** INFO level messages
- **File:** `migration-test-setup.log` (DEBUG level, 10MB rotation, 30 days retention)

## Dependencies

- RabbitMQ AMQP Client 5.25.0
- RabbitMQ HTTP Client 5.4.0
- Jackson 2.18.2 (JSON processing)
- SLF4J + Logback (logging)
- JUnit 5 (testing)

## Architecture

### Key Classes
- `EndToEndMigrationTest` - Main test orchestration
- `MigrationTestSetup` - Environment setup
- `QueueMigrationClient` - Migration API client
- `RabbitMQSetup` - Queue/exchange/binding creation
- `MessageGenerator` - Message creation and publishing
- `CleanupEnvironment` - Test artifact cleanup
- `TestConfiguration` - Configuration management

## Performance Benchmarks

### Small (10 queues, 5,500 messages)
- Setup: 5-10 seconds
- Migration: 15-30 seconds
- Total: ~1 minute

### Medium (32 queues, 50,000 messages)
- Setup: 30-60 seconds
- Migration: 5-10 minutes
- Total: ~10-15 minutes

### Large (128 queues, 2,000,000 messages)
- Setup: 5-10 minutes
- Migration: 45-90 minutes
- Total: ~1-2 hours

## License

This project is licensed under the Apache-2.0 License.
