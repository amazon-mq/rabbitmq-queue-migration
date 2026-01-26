# API Examples - RabbitMQ Queue Migration Plugin

**Last Updated:** January 21, 2026

This document provides practical examples for all HTTP API endpoints with actual response structures verified against a running broker.

---

## Table of Contents

1. [Compatibility Check Examples](#compatibility-check-examples)
2. [Migration Start Examples](#migration-start-examples)
3. [Migration Status Examples](#migration-status-examples)
4. [Migration Control Examples](#migration-control-examples)
5. [Common Workflows](#common-workflows)

---

## Compatibility Check Examples

### Basic Compatibility Check

Check if default vhost is ready for migration:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2F
```

**Response:**
```json
{
  "vhost": "/",
  "skip_unsuitable_queues": false,
  "overall_ready": true,
  "system_checks": {
    "all_passed": true,
    "checks": [
      {
        "check_type": "relaxed_checks_setting",
        "status": "passed",
        "message": "Relaxed checks setting is enabled"
      },
      {
        "check_type": "leader_balance",
        "status": "passed",
        "message": "Queue leaders are balanced across cluster nodes"
      },
      {
        "check_type": "queue_synchronization",
        "status": "passed",
        "message": "All mirrored classic queues are fully synchronized"
      },
      {
        "check_type": "queue_suitability",
        "status": "passed",
        "message": "All queues are suitable for migration"
      },
      {
        "check_type": "disk_space",
        "status": "passed",
        "message": "Sufficient disk space available for migration"
      },
      {
        "check_type": "snapshot_not_in_progress",
        "status": "passed",
        "message": "No EBS snapshots in progress"
      }
    ]
  },
  "queue_checks": {
    "summary": {
      "total_queues": 50,
      "compatible_queues": 50,
      "unsuitable_queues": 0,
      "compatibility_percentage": 100
    },
    "results": []
  }
}
```

---

### Compatibility Check with Skip Mode

Check compatibility and see which queues would be unsuitable:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

**Response (with unsuitable queues):**
```json
{
  "vhost": "/",
  "skip_unsuitable_queues": true,
  "overall_ready": true,
  "system_checks": {
    "all_passed": true,
    "checks": [
      {
        "check_type": "relaxed_checks_setting",
        "status": "passed",
        "message": "Relaxed checks setting is enabled"
      }
    ]
  },
  "queue_checks": {
    "summary": {
      "total_queues": 50,
      "compatible_queues": 45,
      "unsuitable_queues": 5,
      "compatibility_percentage": 90
    },
    "results": [
      {
        "name": "unsync.queue.1",
        "vhost": "/",
        "compatible": false,
        "issues": [
          {
            "type": "unsynchronized",
            "reason": "Queue has unsynchronized mirrors"
          }
        ]
      },
      {
        "name": "reject.queue.1",
        "vhost": "/",
        "compatible": false,
        "issues": [
          {
            "type": "unsuitable_overflow",
            "reason": "Queue has overflow policy reject-publish-dlx"
          }
        ]
      },
      {
        "name": "too.many.queue.1",
        "vhost": "/",
        "compatible": false,
        "issues": [
          {
            "type": "too_many_queues",
            "reason": "Too many queues to migrate safely"
          }
        ]
      }
    ]
  }
}
```

---

### Compatibility Check for Specific Virtual Host

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2Fproduction
```

**Note:** Virtual host must be URL-encoded in the path (`/production` → `%2Fproduction`)

---

## Migration Start Examples

### Basic Migration

Migrate all eligible queues in default vhost:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

**Response:**
```json
{
  "migration_id": "g2gCbQAAAA5yYWJiaXRAcm1xMGIAAAPoAAAAAAA=",
  "status": "started"
}
```

---

### Migration with Skip Mode

Skip unsuitable queues and migrate the rest:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

---

### Batch Migration (Smallest First)

Migrate 50 smallest queues by message count:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

---

### Batch Migration (Largest First)

Migrate 50 largest queues by message count:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "largest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

---

### Combined: Skip Mode + Batch Migration

Migrate 100 smallest suitable queues:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "skip_unsuitable_queues": true,
    "batch_size": 100,
    "batch_order": "smallest_first"
  }' \
  http://localhost:15672/api/queue-migration/start
```

---

### Migration with Message Count Tolerance

Allow up to 10% message count difference per queue (useful when publishers set per-message TTL):

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"tolerance": 10.0}' \
  http://localhost:15672/api/queue-migration/start
```

**Note:** Tolerance is a per-queue percentage. A queue with 100 source messages passes verification if the destination has 90-100 messages.

---

### Migration for Specific Virtual Host

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start/%2Fproduction
```

**Note:** Virtual host must be in URL path, not request body.

---

### Migration with Specific Queues

Migrate only specific queues by name:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["queue1", "queue2", "queue3"]}' \
  http://localhost:15672/api/queue-migration/start
```

**Note:** `queue_names` takes precedence over `batch_size` and `batch_order`.

---

## Migration Status Examples

### Get All Migrations

List all migrations across all vhosts:

```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status
```

**Response:**
```json
{
  "status": "not_running",
  "migrations": [
    {
      "id": "g2gCbQAAAA5yYWJiaXRAcm1xMGIAAAPoAAAAAAA=",
      "display_id": "/ (2026-01-21 00:15:30) on rabbit-1@hostname",
      "vhost": "/",
      "status": "completed",
      "started_at": "2026-01-21 00:15:30",
      "completed_at": "2026-01-21 00:18:45",
      "total_queues": 50,
      "completed_queues": 45,
      "skipped_queues": 5,
      "progress_percentage": 100,
      "skip_unsuitable_queues": true,
      "tolerance": 10.0,
      "error": null
    }
  ]
}
```

**Response Fields:**
- `status` - Overall migration system status: `not_running` or `in_progress`
- `migrations` - Array of migration records (most recent first)

**Migration Record Fields:**
- `id` - Unique migration identifier (base64-encoded Erlang term)
- `display_id` - Human-readable identifier with vhost, timestamp, and node
- `vhost` - Virtual host
- `status` - Migration status (see status values below)
- `started_at` - Start timestamp (YYYY-MM-DD HH:MM:SS format, UTC)
- `completed_at` - Completion timestamp (null if in progress)
- `total_queues` - Total queues in migration
- `completed_queues` - Queues completed
- `skipped_queues` - Queues skipped
- `progress_percentage` - Progress (0-100)
- `skip_unsuitable_queues` - Whether skip mode was enabled
- `tolerance` - Message count tolerance percentage (null if not set)
- `error` - Error details (null if no error)

**Migration Status Values:**
- `pending` - Not started yet
- `in_progress` - Currently migrating
- `completed` - Successfully completed
- `failed` - Migration failed
- `interrupted` - Migration was interrupted
- `rollback_pending` - Requires rollback
- `rollback_completed` - Rollback completed

---

### Get Specific Migration Details

Get detailed status including per-queue information:

```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/g2gCbQAAAA5yYWJiaXRAcm1xMGIAAAPoAAAAAAA=
```

**Response:**
```json
{
  "migration": {
    "id": "g2gCbQAAAA5yYWJiaXRAcm1xMGIAAAPoAAAAAAA=",
    "display_id": "/ (2026-01-21 00:15:30) on rabbit-1@hostname",
    "vhost": "/",
    "status": "completed",
    "started_at": "2026-01-21 00:15:30",
    "completed_at": "2026-01-21 00:18:45",
    "total_queues": 50,
    "completed_queues": 45,
    "skipped_queues": 5,
    "progress_percentage": 100,
    "skip_unsuitable_queues": true,
    "error": null,
    "snapshots": [
      {
        "node": "rabbit-1@hostname",
        "volume_id": "vol-abc123",
        "snapshot_id": "snap-xyz789"
      }
    ]
  },
  "queues": [
    {
      "resource": {
        "name": "test.queue.0",
        "vhost": "/"
      },
      "status": "completed",
      "started_at": "2026-01-21 00:15:31",
      "completed_at": "2026-01-21 00:15:45",
      "total_messages": 1000,
      "migrated_messages": 1000,
      "progress_percentage": 100,
      "error": null
    },
    {
      "resource": {
        "name": "problem.queue.1",
        "vhost": "/"
      },
      "status": "skipped",
      "started_at": null,
      "completed_at": null,
      "total_messages": 0,
      "migrated_messages": 0,
      "progress_percentage": 0,
      "error": "too_many_queues"
    }
  ]
}
```

**Response Fields:**
- `migration` - Migration record (same fields as status list)
- `queues` - Array of per-queue status records

**Queue Status Fields:**
- `resource` - Queue resource object:
  - `name` - Queue name
  - `vhost` - Virtual host
- `status` - Queue migration status:
  - `pending` - Not started yet
  - `in_progress` - Currently migrating
  - `completed` - Successfully migrated
  - `failed` - Migration failed
  - `skipped` - Skipped (unsuitable or interrupted)
- `started_at` - Queue migration start timestamp (null if not started)
- `completed_at` - Queue migration completion timestamp (null if in progress)
- `total_messages` - Total messages in queue at start
- `migrated_messages` - Messages migrated so far
- `progress_percentage` - Queue progress (0-100)
- `error` - Error details (if failed) or skip reason (if skipped)

**Skip Reasons:**
- `unsynchronized` - Mirrored queue not synchronized
- `too_many_queues` - Too many queues to migrate safely
- `unsuitable_overflow` - Queue has reject-publish-dlx overflow policy
- `interrupted` - Migration was manually interrupted

---

## Migration Control Examples

### Interrupt Running Migration

Stop migration gracefully:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/interrupt/g2gCbQAAAA5yYWJiaXRAcm1xMGIAAAPoAAAAAAA=
```

**Response:**
```json
{
  "interrupted": true,
  "migration_id": "g2gCbQAAAA5yYWJiaXRAcm1xMGIAAAPoAAAAAAA="
}
```

**Effect:**
- Currently processing queues complete
- Remaining queues marked as skipped with reason "interrupted"
- Migration status changes to "interrupted"

---

## Common Workflows

### Workflow 1: Cautious Migration

**Goal:** Test with small batch, then migrate rest

```bash
# Step 1: Check compatibility
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F

# Step 2: Migrate 10 smallest queues as test
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true, "batch_size": 10, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start

# Step 3: Monitor and verify
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Step 4: If successful, migrate rest
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

---

### Workflow 2: Incremental Migration

**Goal:** Migrate 100 queues per day over a week

```bash
# Day 1: First 100
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 100, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start

# Day 2: Next 100
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 100, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start

# Continue until all queues migrated
```

---

### Workflow 3: Handle Interruption

**Goal:** Resume after interrupted migration

```bash
# Step 1: Check what was completed
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Step 2: Start new migration
# Idempotency ensures completed queues are skipped
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

---

### Workflow 4: Skip and Fix

**Goal:** Migrate suitable queues, then fix and migrate unsuitable ones

```bash
# Step 1: Migrate with skip mode
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start

# Step 2: Check which queues were skipped
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>

# Step 3: Fix issues with skipped queues
# (sync queues, reduce queue count, change policies, etc.)

# Step 4: Migrate remaining queues
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

---

## Error Response Examples

### Migration Already Running

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

**Response (400):**
```json
{
  "error": "bad_request",
  "reason": "A migration is already in progress"
}
```

---

### Compatibility Check Failed

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

**Response (400):**
```json
{
  "error": "bad_request",
  "reason": "rabbitmq_shovel plugin must be enabled for migration. Enable the plugin with: rabbitmq-plugins enable rabbitmq_shovel"
}
```

---

### Invalid Parameter

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": -10}' \
  http://localhost:15672/api/queue-migration/start
```

**Response (400):**
```json
{
  "error": "bad_request",
  "reason": "batch_size must be a positive integer or 'all'"
}
```

---

### Migration Not Found

```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/invalid-id
```

**Response (404):**
```json
{
  "error": "Object Not Found",
  "reason": "Not Found"
}
```

---

## Related Documentation

- **HTTP API Reference:** HTTP_API.md
- **Skip Unsuitable Queues Guide:** SKIP_UNSUITABLE_QUEUES.md
- **Troubleshooting Guide:** TROUBLESHOOTING.md
- **Configuration Reference:** CONFIGURATION.md
