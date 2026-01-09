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

## Endpoints

### Start Migration

Start migration for all eligible queues on a vhost.

**Endpoints:**
```
PUT /api/queue-migration/start
PUT /api/queue-migration/start/:vhost
```

**Parameters:**
- `:vhost` (optional) - Virtual host name (URL-encoded). Defaults to `/` if not specified.

**Request Body (optional):**
```json
{
  "skip_unsuitable_queues": true
}
```

**Request Body Fields:**
- `skip_unsuitable_queues` (optional, boolean) - When `true`, skip queues that fail validation checks instead of blocking the entire migration. Defaults to `false`.

**Request:**
```bash
# Default vhost (/) with default behavior
curl -u guest:guest -X PUT http://localhost:15672/api/queue-migration/start

# Specific vhost
curl -u guest:guest -X PUT http://localhost:15672/api/queue-migration/start/my-vhost

# Skip unsuitable queues
curl -u guest:guest -X PUT \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

**Response (200 OK):**
```json
{
  "status": "cmq_qq_migration_in_progress",
  "migration_id": "ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz",
  "vhost": "/",
  "total_queues": 10,
  "started_at": "2025-12-21 10:30:00"
}
```

**Response Fields:**
- `status` - Current migration status (`cmq_qq_migration_in_progress`)
- `migration_id` - Base64url-encoded unique migration identifier
- `vhost` - Virtual host being migrated
- `total_queues` - Number of queues to migrate
- `started_at` - Migration start timestamp

**Error Responses:**

**409 Conflict** - Migration already in progress:
```json
{
  "error": "Migration already in progress",
  "current_migration_id": "..."
}
```

**400 Bad Request** - Validation failed:
```json
{
  "error": "Pre-migration validation failed",
  "details": {
    "check": "disk_space",
    "reason": "Insufficient disk space"
  }
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
  "status": "cmq_qq_migration_in_progress",
  "migrations": [
    {
      "id": "ZzJnQ2JnWUE4VTJOS0pzQmR4aHlZV0pwYVhRdE1VQlRSVUV0TTB4SE5VaFdTbFZYU2tz",
      "display_id": "/ (2025-12-21 10:30:00) on rabbit@node1",
      "vhost": "/",
      "started_at": "2025-12-21 10:30:00",
      "completed_at": null,
      "total_queues": 10,
      "completed_queues": 5,
      "progress_percentage": 50,
      "status": "in_progress"
    },
    {
      "id": "...",
      "display_id": "/ (2025-12-20 15:00:00) on rabbit@node1",
      "vhost": "/",
      "started_at": "2025-12-20 15:00:00",
      "completed_at": "2025-12-20 15:05:30",
      "total_queues": 20,
      "completed_queues": 20,
      "progress_percentage": 100,
      "status": "completed"
    }
  ]
}
```

**Response Fields:**
- `status` - Overall system status:
  - `cmq_qq_migration_not_running` - No active migration
  - `cmq_qq_migration_in_progress` - Migration currently running
- `migrations` - Array of migration records (most recent first)

**Migration Record Fields:**
- `id` - Base64url-encoded migration identifier
- `display_id` - Human-readable identifier with vhost, timestamp, and node
- `vhost` - Virtual host
- `started_at` - Start timestamp
- `completed_at` - Completion timestamp (null if in progress)
- `total_queues` - Total queues to migrate
- `completed_queues` - Queues completed so far
- `progress_percentage` - Progress (0-100)
- `status` - Migration status:
  - `in_progress` - Currently migrating
  - `completed` - Successfully completed
  - `failed` - Migration failed
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
    "progress_percentage": 50,
    "status": "in_progress"
  },
  "queues": [
    {
      "name": "my-queue",
      "vhost": "/",
      "status": "completed",
      "started_at": "2025-12-21 10:30:05",
      "completed_at": "2025-12-21 10:30:15",
      "total_messages": 1000,
      "migrated_messages": 1000,
      "progress_percentage": 100
    },
    {
      "name": "another-queue",
      "vhost": "/",
      "status": "in_progress",
      "started_at": "2025-12-21 10:30:20",
      "completed_at": null,
      "total_messages": 5000,
      "migrated_messages": 2500,
      "progress_percentage": 50
    }
  ]
}
```

**Response Fields:**
- `migration` - Migration record (same as status list)
- `queues` - Array of per-queue status records

**Queue Status Fields:**
- `name` - Queue name
- `vhost` - Virtual host
- `status` - Queue migration status:
  - `pending` - Not started yet
  - `in_progress` - Currently migrating
  - `completed` - Successfully migrated
  - `failed` - Migration failed
  - `skipped` - Skipped due to validation issues (when `skip_unsuitable_queues` is enabled)
  - `rollback_completed` - Rollback completed
  - `rollback_failed` - Rollback failed
- `started_at` - Queue migration start timestamp
- `completed_at` - Queue migration completion timestamp (null if in progress)
- `total_messages` - Total messages in queue at start
- `migrated_messages` - Messages migrated so far
- `progress_percentage` - Queue progress (0-100)
- `error` - Error details (if status is `failed`) or skip reason (if status is `skipped`)

**Error Response (404 Not Found):**
```json
{
  "error": "Migration not found"
}
```

---

### Check Compatibility

Check if queues are eligible for migration and validate system readiness.

**Endpoints:**
```
GET /api/queue-migration/compatibility
GET /api/queue-migration/compatibility/:vhost
```

**Parameters:**
- `:vhost` (optional) - Virtual host name (URL-encoded). Defaults to `/` if not specified.

**Request:**
```bash
# Default vhost (/)
curl -u guest:guest http://localhost:15672/api/queue-migration/compatibility

# Specific vhost
curl -u guest:guest http://localhost:15672/api/queue-migration/compatibility/my-vhost
```

**Response (200 OK):**
```json
{
  "ready_for_migration": true,
  "system_checks": {
    "shovel_plugin_enabled": {
      "status": "pass",
      "message": "rabbitmq_shovel plugin is enabled"
    },
    "khepri_disabled": {
      "status": "pass",
      "message": "Khepri database is disabled"
    },
    "relaxed_checks_enabled": {
      "status": "pass",
      "message": "Relaxed argument checks enabled"
    },
    "disk_space": {
      "status": "pass",
      "message": "Sufficient disk space available",
      "details": {
        "required_bytes": 1073741824,
        "available_bytes": 10737418240
      }
    }
  },
  "queue_checks": {
    "total_queues": 10,
    "eligible_queues": 10,
    "ineligible_queues": 0,
    "queues": [
      {
        "name": "my-queue",
        "vhost": "/",
        "eligible": true,
        "checks": {
          "is_classic_queue": true,
          "has_ha_policy": true,
          "is_synchronized": true,
          "message_count_ok": true
        }
      }
    ]
  }
}
```

**Response Fields:**
- `ready_for_migration` - Boolean indicating if migration can proceed
- `system_checks` - System-level validation results
- `queue_checks` - Per-queue eligibility information

**System Check Statuses:**
- `pass` - Check passed
- `fail` - Check failed (blocks migration)
- `warn` - Warning (migration may proceed)

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

### Common Error Scenarios

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
curl -s -u guest:guest http://localhost:15672/api/queue-migration/compatibility | jq

# 2. Start migration
echo "Starting migration..."
RESPONSE=$(curl -s -u guest:guest -X PUT http://localhost:15672/api/queue-migration/start)
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

- [README.md](README.md) - Plugin overview and quick start
- [AGENTS.md](AGENTS.md) - Technical architecture and implementation details
- [test/integration/README.md](test/integration/README.md) - Integration testing guide
