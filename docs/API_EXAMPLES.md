# API Examples - RabbitMQ Queue Migration Plugin

This is a task-oriented companion to the [HTTP API Reference](HTTP_API.md). It shows how to call and combine the endpoints; for full request and response schemas, field definitions, status codes, and error bodies, see the reference. For the end-to-end operator path, see [Running a Migration](RUNNING_A_MIGRATION.md).

All examples use `guest:guest` and the default vhost (`/`, URL-encoded `%2F`). The vhost always goes in the URL path, URL-encoded, never in the request body.

---

## Table of Contents

1. [Compatibility Check](#compatibility-check)
2. [Starting a Migration](#starting-a-migration)
3. [Checking Status](#checking-status)
4. [Interrupting a Migration](#interrupting-a-migration)
5. [Common Workflows](#common-workflows)

---

## Compatibility Check

Check whether a vhost is ready for migration without changing anything. For the full response shape (system checks and per-queue results), see [Check Compatibility](HTTP_API.md#check-compatibility).

```bash
# Default vhost
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2F

# Specific vhost
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2Fproduction

# Skip mode: also report which queues would be skipped and why
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

Skip reasons in the response (`unsynchronized`, `too_many_queues`, `unsuitable_overflow`, `queue_expires`, `message_ttl`, `interrupted`) are documented in [Skip Unsuitable Queues](SKIP_UNSUITABLE_QUEUES.md).

---

## Starting a Migration

Every option goes in the JSON body and is optional; see [Start Migration](HTTP_API.md#start-migration) for the full field list and the response shape. The response returns a `migration_id` used to monitor progress.

```bash
# Migrate all eligible queues in the default vhost
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start

# Specific vhost (vhost in the URL path, not the body)
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start/%2Fproduction

# Skip unsuitable queues and migrate the rest
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start

# Batch: migrate the 50 smallest queues (use "largest_first" to reverse)
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start

# Specific queues by name (takes precedence over batch_size and batch_order)
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["queue1", "queue2", "queue3"]}' \
  http://localhost:15672/api/queue-migration/start

# Allow a per-queue message count tolerance (useful with per-message TTL)
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"tolerance": 10.0}' \
  http://localhost:15672/api/queue-migration/start
```

Tolerance is a per-queue percentage; see [Message Loss and Verification](MESSAGE_LOSS_AND_VERIFICATION.md) for how it works, the over- and under-delivery defaults, and per-message TTL.

---

## Checking Status

List all migrations, or get per-queue detail for one. For the full response bodies, field definitions, and status values, see [Get Migration Status](HTTP_API.md#get-migration-status) and [Get Detailed Migration Status](HTTP_API.md#get-detailed-migration-status).

```bash
# All migrations, most recent first
curl -u guest:guest http://localhost:15672/api/queue-migration/status

# One migration, with per-queue detail
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>
```

---

## Interrupting a Migration

Stop a running migration gracefully. In-flight queues finish; queues not yet started are marked `skipped` with reason `interrupted`, and the migration ends with status `interrupted`. See [Interrupt Migration](HTTP_API.md#interrupt-migration).

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/interrupt/<migration_id>
```

---

## Common Workflows

### Workflow 1: Cautious Migration

Test with a small batch, then migrate the rest:

```bash
# Step 1: Check compatibility
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F

# Step 2: Migrate 10 smallest queues as a test
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true, "batch_size": 10, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start

# Step 3: Monitor and verify
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Step 4: If successful, migrate the rest
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

### Workflow 2: Incremental Migration

Migrate a fixed number of queues per maintenance window. Migration is idempotent, so already-migrated queues are skipped automatically:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 100, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

Repeat until all queues are migrated.

### Workflow 3: Resume After Interruption

Check what completed, then start a new migration; idempotency ensures completed queues are skipped:

```bash
# Step 1: Check what was completed
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Step 2: Start a new migration to pick up the rest
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

### Workflow 4: Skip and Fix

Migrate the suitable queues now, then fix and migrate the rest. See [Skip Unsuitable Queues](SKIP_UNSUITABLE_QUEUES.md) for the full walkthrough.

```bash
# Step 1: Migrate with skip mode
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start

# Step 2: Check which queues were skipped, and why
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Step 3: Fix the skipped queues (sync, change policies, reduce count, etc.)

# Step 4: Migrate the remaining queues
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

---

## Error Responses

Error bodies (400 validation failures, 404 not found, and the 503 plugin-initialization states) are documented in [Error Handling](HTTP_API.md#error-handling) and [Plugin Initialization States](HTTP_API.md#plugin-initialization-states).

---

## Related Documentation

- [HTTP API Reference](HTTP_API.md) - full request/response schemas and field definitions
- [Running a Migration](RUNNING_A_MIGRATION.md) - the end-to-end operator path
- [Skip Unsuitable Queues](SKIP_UNSUITABLE_QUEUES.md) - the skip feature and every skip reason
- [Troubleshooting](TROUBLESHOOTING.md) - errors, diagnostics, recovery
- [Configuration](CONFIGURATION.md) - configuration parameters and defaults
