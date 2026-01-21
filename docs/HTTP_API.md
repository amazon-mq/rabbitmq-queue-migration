# RabbitMQ Queue Migration Plugin - HTTP API Reference

Complete reference for the Queue Migration Plugin HTTP API endpoints.

## Base URL

All endpoints are prefixed with `/api/queue-migration/` and require authentication.

**Example:**
```
http://localhost:15672/api/queue-migration/status
```

## Authentication

All endpoints require RabbitMQ user authentication. Use HTTP Basic Auth with management plugin credentials.

**Example:**
```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/status
```

## URL Encoding

Virtual host names and migration IDs must be URL-encoded when used in URL paths. This includes:

- `/` → `%2F`
- `&` → `%26`
- `#` → `%23`
- Unicode characters (e.g., `ü` → `%C3%BC`, `日本語` → `%E6%97%A5%E6%9C%AC%E8%AA%9E`)

**Examples:**
```bash
# Vhost "/" (default)
curl -u guest:guest http://localhost:15672/api/queue-migration/start/%2F

# Vhost "/test&foo"
curl -u guest:guest http://localhost:15672/api/queue-migration/start/%2Ftest%26foo

# Vhost "/test/über&co" (with unicode)
curl -u guest:guest http://localhost:15672/api/queue-migration/start/%2Ftest%2F%C3%BCber%26co

# Vhost "/test/日本語&queue" (with CJK characters)
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2Ftest%2F%E6%97%A5%E6%9C%AC%E8%AA%9E%26queue
```

---

## Endpoints

### Start Migration

Start migration for all eligible queues on a vhost.

**Endpoints:**
```
POST /api/queue-migration/start
POST /api/queue-migration/start/:vhost
```

**Parameters:**
- `:vhost` - Virtual host name (URL-encoded). **Must be specified in the URL path.**

> **Important:** The vhost must be specified in the URL, not in the request body. The `/api/queue-migration/start` endpoint (without a vhost path parameter) defaults to the `/` vhost. To migrate a different vhost, you must use `/api/queue-migration/start/:vhost` with the vhost name URL-encoded in the path.

**Request Body (optional):**
```json
{
  "skip_unsuitable_queues": true,
  "batch_size": 10,
  "batch_order": "smallest_first"
}
```

**Request Body Fields:**
- `skip_unsuitable_queues` (optional, boolean) - When `true`, skip queues that fail validation checks instead of blocking the entire migration. Defaults to `false`.
- `batch_size` (optional, integer or `"all"`) - Number of queues to migrate in this batch. Use `0` or `"all"` to migrate all eligible queues. Defaults to `all`. Ignored if `queue_names` is specified.
- `batch_order` (optional, string) - Order to select queues for batching: `"smallest_first"` or `"largest_first"`. Defaults to `"smallest_first"`. Ignored if `queue_names` is specified.
- `queue_names` (optional, array of strings) - Specific queue names to migrate. When provided, only these queues are migrated. Takes precedence over `batch_size` and `batch_order`. Non-existent or ineligible queues are logged and skipped.

**Request:**
```bash
# Default vhost (/)
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start

# Specific vhost - vhost MUST be in the URL path, not the body
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start/my-vhost

# Vhost with special characters (e.g., /production/app)
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start/%2Fproduction%2Fapp

# Skip unsuitable queues
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start/%2F

# Migrate only 10 queues, smallest first
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 10, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start/%2Fmy-vhost

# Migrate all remaining queues (batch_size=0 means "all")
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 0}' \
  http://localhost:15672/api/queue-migration/start/%2Fmy-vhost

# Migrate specific queues by name
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["queue1", "queue2", "queue3"]}' \
  http://localhost:15672/api/queue-migration/start/%2Fmy-vhost

# Migrate specific queues (queue_names takes precedence over batch_size)
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["queue1", "queue2"], "batch_size": 10}' \
  http://localhost:15672/api/queue-migration/start/%2Fmy-vhost
```

> **Common Mistake:** Do not pass `"vhost"` in the JSON body - it will be ignored. The vhost is always read from the URL path.

**Response (200 OK):**
```json
{
  "migration_id": "ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz",
  "status": "started"
}
```

**Response Fields:**
- `migration_id` - Base64url-encoded unique migration identifier. Use this ID to track the migration via the status endpoint.
- `status` - Request status (`started`)

> **Note:** The migration runs asynchronously. Use the returned `migration_id` with the `/api/queue-migration/status/:migration_id` endpoint to monitor progress.

**Error Responses:**

**400 Bad Request** - Validation failed or invalid parameters:

Shovel plugin not enabled:
```json
{
  "error": "bad_request",
  "reason": "rabbitmq_shovel plugin must be enabled for migration. Enable the plugin with: rabbitmq-plugins enable rabbitmq_shovel"
}
```

Unsuitable queues found (when skip mode not enabled):
```json
{
  "error": "bad_request",
  "reason": "Found 5 queue(s) with issues (too many messages, too many bytes, or unsuitable arguments)",
  "problematic_queue_count": 5
}
```

Insufficient disk space:
```json
{
  "error": "bad_request",
  "reason": "Insufficient disk space for migration. Required: 5000MB, Available: 2000MB"
}
```

Queue leaders imbalanced:
```json
{
  "error": "bad_request",
  "reason": "Queue leaders are imbalanced. Re-balance queue leaders before migration."
}
```

---

### Get Migration Status

Get overall migration status and list of all migrations.

**Endpoint:**
```
GET /api/queue-migration/status
```

**Request:**
```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/status
```

**Response (200 OK):**
```json
{
  "status": "in_progress",
  "migrations": [
    {
      "id": "ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz",
      "display_id": "/ (2025-12-21 10:30:00) on rabbit@node1",
      "vhost": "/",
      "started_at": "2025-12-21 10:30:00",
      "completed_at": null,
      "total_queues": 10,
      "completed_queues": 5,
      "skipped_queues": 0,
      "progress_percentage": 50,
      "status": "in_progress",
      "skip_unsuitable_queues": false,
      "error": null
    },
    {
      "id": "...",
      "display_id": "/ (2025-12-20 15:00:00) on rabbit@node1",
      "vhost": "/",
      "started_at": "2025-12-20 15:00:00",
      "completed_at": "2025-12-20 15:05:30",
      "total_queues": 20,
      "completed_queues": 20,
      "skipped_queues": 0,
      "progress_percentage": 100,
      "status": "completed",
      "skip_unsuitable_queues": false,
      "error": null
    }
  ]
}
```

**Response Fields:**
- `status` - Overall system status:
  - `not_running` - No active migration
  - `in_progress` - Migration currently running
- `migrations` - Array of migration records (most recent first)

**Migration Record Fields:**
- `id` - Base64url-encoded migration identifier
- `display_id` - Human-readable identifier with vhost, timestamp, and node
- `vhost` - Virtual host
- `started_at` - Start timestamp (YYYY-MM-DD HH:MM:SS format, UTC)
- `completed_at` - Completion timestamp (null if in progress)
- `total_queues` - Total queues to migrate
- `completed_queues` - Queues completed so far
- `skipped_queues` - Queues skipped
- `progress_percentage` - Progress (0-100)
- `status` - Migration status (see values below)
- `skip_unsuitable_queues` - Whether skip mode was enabled
- `error` - Error details (null if no error)
  - `pending` - Not started yet
  - `in_progress` - Currently migrating
  - `completed` - Successfully completed
  - `failed` - Migration failed
  - `interrupted` - Migration was interrupted
  - `rollback_pending` - Requires rollback
  - `rollback_completed` - Rollback completed

---

### Get Detailed Migration Status

Get detailed status for a specific migration including per-queue information.

**Endpoint:**
```
GET /api/queue-migration/status/:migration_id
```

**Parameters:**
- `:migration_id` - Base64url-encoded migration identifier (URL-encoded)

**Request:**
```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz
```

**Response (200 OK):**
```json
{
  "migration": {
    "id": "ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz",
    "display_id": "/ (2025-12-21 10:30:00) on rabbit@node1",
    "vhost": "/",
    "started_at": "2025-12-21 10:30:00",
    "completed_at": null,
    "total_queues": 10,
    "completed_queues": 5,
    "skipped_queues": 0,
    "progress_percentage": 50,
    "status": "in_progress",
    "skip_unsuitable_queues": false,
    "error": null,
    "snapshots": []
  },
  "queues": [
    {
      "resource": {
        "name": "my-queue",
        "vhost": "/"
      },
      "status": "completed",
      "started_at": "2025-12-21 10:30:05",
      "completed_at": "2025-12-21 10:30:15",
      "total_messages": 1000,
      "migrated_messages": 1000,
      "progress_percentage": 100,
      "error": null
    },
    {
      "resource": {
        "name": "another-queue",
        "vhost": "/"
      },
      "status": "in_progress",
      "started_at": "2025-12-21 10:30:20",
      "completed_at": null,
      "total_messages": 5000,
      "migrated_messages": 2500,
      "progress_percentage": 50,
      "error": null
    }
  ]
}
```

**Response Fields:**
- `migration` - Migration record (same as status list)
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
  - `skipped` - Skipped due to validation issues (when `skip_unsuitable_queues` is enabled)
  - `rollback_completed` - Rollback completed
- `started_at` - Queue migration start timestamp
- `completed_at` - Queue migration completion timestamp (null if in progress)
- `total_messages` - Total messages in queue at start
- `migrated_messages` - Messages migrated so far
- `progress_percentage` - Queue progress (0-100)
- `error` - Error details (if status is `failed`) or skip reason (if status is `skipped`)

**Error Response (404 Not Found):**

Returned when the migration ID is invalid (cannot be decoded) or the migration does not exist.

```json
{
  "error": "Object Not Found",
  "reason": "Not Found"
}
```

---

### Interrupt Migration

Interrupt a running migration. In-flight queue migrations complete gracefully while remaining queues are skipped.

**Endpoint:**
```
POST /api/queue-migration/interrupt/:migration_id
```

**Parameters:**
- `:migration_id` - Migration ID (URL-encoded)

**Request:**
```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/interrupt/1768576931281
```

**Success Response (200 OK):**
```json
{
  "interrupted": true,
  "migration_id": "1768576931281"
}
```

**Behavior:**
- Sets migration status to `interrupted`
- Workers check status before processing each queue
- Queues already being migrated complete normally
- Remaining queues are skipped and marked with status `skipped`
- Post-migration restore runs normally (listeners resumed, snapshots cleaned up)
- Migration completes with status `interrupted` and partial queue count

**Error Response (404 Not Found):**

Returned when the migration ID is invalid or the migration does not exist.

```json
{
  "error": "Object Not Found",
  "reason": "Not Found"
}
```

---

### Check Compatibility

Check if queues are eligible for migration and validate system readiness.

**Endpoint:**
```
POST /api/queue-migration/check/:vhost
```

**Parameters:**
- `:vhost` - Virtual host name (URL-encoded). **Must be specified in the URL path.** Use `all` to check all vhosts.

> **Important:** Unlike the start endpoint, there is no default vhost for the check endpoint. You must always specify the vhost in the URL path.

**Request Body (optional):**
```json
{
  "skip_unsuitable_queues": true
}
```

**Request Body Fields:**
- `skip_unsuitable_queues` (optional, boolean) - When `true`, unsuitable queues are shown as informational and don't affect overall readiness. Defaults to `false`.

**Request:**
```bash
# Check the default vhost (/)
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2F

# Check a specific vhost (e.g., /production/app)
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2Fproduction%2Fapp

# With skip mode enabled
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

**Response (200 OK):**
```json
{
  "vhost": "/",
  "skip_unsuitable_queues": false,
  "overall_ready": true,
  "queue_checks": {
    "summary": {
      "total_queues": 10,
      "unsuitable_queues": 0,
      "compatibility_percentage": 100,
      "compatible_queues": 10
    },
    "results": []
  },
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
  }
}
```

**Response Fields:**
- `vhost` - Virtual host being checked
- `skip_unsuitable_queues` - Whether skip mode was requested
- `overall_ready` - Boolean indicating if migration can proceed
- `queue_checks` - Queue-level validation results
  - `summary` - Aggregate queue statistics
  - `results` - Array of individual queue issues (empty when all compatible)
- `system_checks` - System-level validation results
  - `all_passed` - Boolean indicating all system checks passed
  - `checks` - Array of individual check results

**System Check Types:**
- `relaxed_checks_setting` - Relaxed argument checks enabled
- `leader_balance` - Queue leaders balanced across nodes
- `queue_synchronization` - All mirrored queues synchronized
- `queue_suitability` - All queues suitable for migration
- `disk_space` - Sufficient disk space available
- `snapshot_not_in_progress` - No EBS snapshots currently in progress

---

### Get Rollback Pending Migration

Get the most recent migration in `rollback_pending` state.

**Endpoint:**
```
GET /api/queue-migration/rollback-pending
```

**Request:**
```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/rollback-pending
```

**Response (200 OK):**
```json
{
  "id": "ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz",
  "display_id": "/ (2025-12-21 10:30:00) on rabbit@node1",
  "vhost": "/",
  "status": "rollback_pending",
  "started_at": "2025-12-21 10:30:00",
  "completed_at": "2025-12-21 10:35:00",
  "total_queues": 10,
  "completed_queues": 8,
  "progress_percentage": 80,
  "snapshots": [
    {
      "node": "rabbit@node1",
      "snapshot_id": "snap-0abc123",
      "volume_id": "vol-0def456"
    },
    {
      "node": "rabbit@node2",
      "snapshot_id": "snap-0ghi789",
      "volume_id": "vol-0jkl012"
    },
    {
      "node": "rabbit@node3",
      "snapshot_id": "snap-0mno345",
      "volume_id": "vol-0pqr678"
    }
  ]
}
```

**Response Fields:**
- Standard migration fields (id, vhost, status, etc.)
- `snapshots` - Array of snapshot information for rollback:
  - `node` - RabbitMQ node name
  - `snapshot_id` - EBS snapshot ID or tar file path
  - `volume_id` - EBS volume ID or tar file path

**Error Response (404 Not Found):**
```json
{
  "error": "No rollback pending migration found"
}
```

**Use Case:** This endpoint is used by automated rollback systems to retrieve snapshot information for restoring the cluster after a failed migration.

---

## Status Codes

| Code | Meaning | Description |
|------|---------|-------------|
| 200 | OK | Request successful |
| 400 | Bad Request | Invalid parameters or validation failed |
| 401 | Unauthorized | Authentication required |
| 404 | Not Found | Resource not found (migration ID or vhost) |
| 409 | Conflict | Migration already in progress |
| 500 | Internal Server Error | Server error during processing |

## Migration ID Format

Migration IDs are base64url-encoded Erlang terms containing:
- Timestamp
- Node name
- Unique identifier

**Example:**
```
ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz
```

**URL Encoding:** When using migration IDs in URLs, ensure proper URL encoding of special characters.

## Polling Recommendations

When monitoring migration progress:
- **Poll interval**: 5-10 seconds recommended
- **Timeout**: Set based on queue count and message volume
- **Exponential backoff**: Consider for long-running migrations

**Example monitoring script:**
```bash
#!/bin/bash

MIGRATION_ID="$1"
INTERVAL=5

while true; do
  STATUS=$(curl -s -u guest:guest \
    "http://localhost:15672/api/queue-migration/status/$MIGRATION_ID" \
    | jq -r '.migration.status')
  
  if [ "$STATUS" = "completed" ]; then
    echo "Migration completed successfully"
    exit 0
  elif [ "$STATUS" = "failed" ] || [ "$STATUS" = "rollback_pending" ]; then
    echo "Migration failed: $STATUS"
    exit 1
  fi
  
  PROGRESS=$(curl -s -u guest:guest \
    "http://localhost:15672/api/queue-migration/status/$MIGRATION_ID" \
    | jq -r '.migration.progress_percentage')
  
  echo "Progress: $PROGRESS%"
  sleep $INTERVAL
done
```

## Error Handling

### Error Scenarios

**Migration Already Running:**
```json
{
  "error": "Migration already in progress",
  "current_migration_id": "..."
}
```
**Action:** Wait for current migration to complete or check its status.

**Validation Failed:**
```json
{
  "error": "Pre-migration validation failed",
  "details": {
    "check": "shovel_plugin",
    "reason": "rabbitmq_shovel plugin is not enabled"
  }
}
```
**Action:** Fix the validation issue and retry. Use the compatibility endpoint for detailed validation results.

**No Eligible Queues:**
```json
{
  "error": "No eligible queues found for migration",
  "vhost": "/"
}
```
**Action:** Verify queues are mirrored classic queues with HA policies applied.

**Insufficient Disk Space:**
```json
{
  "error": "Pre-migration validation failed",
  "details": {
    "check": "disk_space",
    "reason": "Insufficient disk space",
    "required_bytes": 10737418240,
    "available_bytes": 5368709120
  }
}
```
**Action:** Free up disk space or reduce queue message counts before migrating.

## Best Practices

### Before Migration
1. **Run compatibility check** - Validate system readiness
2. **Review eligible queues** - Confirm expected queues will migrate
3. **Check disk space** - Ensure sufficient space available
4. **Backup data** - Create manual backups if needed

### During Migration
1. **Monitor progress** - Poll status endpoint regularly
2. **Check logs** - Watch RabbitMQ logs for errors
3. **Avoid changes** - Don't modify queues during migration
4. **Be patient** - Large migrations can take hours

### After Migration
1. **Validate results** - Check all queues converted to quorum type
2. **Verify messages** - Confirm message counts match
3. **Test applications** - Ensure applications work with quorum queues
4. **Update configuration** - Set default queue type to quorum

## Rate Limiting

The API does not implement rate limiting, but be considerate:
- **Status polling**: 5-10 second intervals recommended
- **Concurrent requests**: Avoid excessive parallel requests
- **Migration starts**: Only one migration per vhost at a time

## Security Considerations

- **Authentication required**: All endpoints require valid RabbitMQ credentials
- **Authorization**: User must have monitoring permissions (or higher)
- **Sensitive data**: Migration IDs and snapshots may contain sensitive information
- **Network security**: Use HTTPS in production environments

## Examples

### Complete Migration Workflow

```bash
#!/bin/bash

# 1. Check compatibility
echo "Checking compatibility..."
curl -s -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2F | jq

# 2. Start migration
echo "Starting migration..."
RESPONSE=$(curl -s -u guest:guest -X POST http://localhost:15672/api/queue-migration/start)
MIGRATION_ID=$(echo "$RESPONSE" | jq -r '.migration_id')
echo "Migration started: $MIGRATION_ID"

# 3. Monitor progress
echo "Monitoring progress..."
while true; do
  STATUS=$(curl -s -u guest:guest \
    "http://localhost:15672/api/queue-migration/status/$MIGRATION_ID" \
    | jq -r '.migration.status')
  
  if [ "$STATUS" = "completed" ]; then
    echo "✅ Migration completed successfully"
    break
  elif [ "$STATUS" = "failed" ] || [ "$STATUS" = "rollback_pending" ]; then
    echo "❌ Migration failed: $STATUS"
    exit 1
  fi
  
  PROGRESS=$(curl -s -u guest:guest \
    "http://localhost:15672/api/queue-migration/status/$MIGRATION_ID" \
    | jq -r '.migration.progress_percentage')
  
  echo "Progress: $PROGRESS%"
  sleep 5
done

# 4. Get detailed results
echo "Getting detailed results..."
curl -s -u guest:guest \
  "http://localhost:15672/api/queue-migration/status/$MIGRATION_ID" | jq
```

## See Also

- [README](README.md) - Plugin overview and quick start
- [AGENTS](AGENTS.md) - Technical architecture and implementation details
- [test/integration/README](test/integration/README.md) - Integration testing guide
