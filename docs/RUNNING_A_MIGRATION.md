# Running a Migration

This is the end-to-end operator path for running a migration: check readiness, start, monitor, and (if needed) interrupt. It covers every `start` option in one place. For how the migration works internally and what makes a queue eligible, see the [Migration Guide](MIGRATION_GUIDE.md); for the full request and response schemas, see the [HTTP API Reference](HTTP_API.md).

All examples use the default vhost (`/`, URL-encoded `%2F`) and `guest:guest`. The vhost is always taken from the URL path, never the request body.

---

## Before you start

Two things bite operators most often. Read these before your first run:

- **Migration closes all client connections broker-wide.** Non-HTTP listeners (AMQP, MQTT, STOMP) are suspended for the whole broker, not just the vhost being migrated, and are restored when the migration ends. Plan a maintenance window. See [Connection Handling](MIGRATION_GUIDE.md#connection-handling-during-migration).
- **Per-message TTL can cause a `message_count_mismatch` failure.** If your publishers set the `expiration` property (common on dead-letter and `_error` queues), messages can expire mid-migration and fail the count check. Decide up front whether to set a `tolerance` or drain first. See [Message Count Verification and Message Loss](MESSAGE_LOSS_AND_VERIFICATION.md).

---

## Step 1: Check readiness

The compatibility check runs the pre-migration validations without changing anything, and reports which queues are eligible and which are unsuitable:

```bash
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/check/%2F
```

Add `skip_unsuitable_queues` to see what a skip-mode migration would migrate versus skip:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

Resolve any system-level blockers (disk space, alarms, partitions, unbalanced leaders, plugin not `ready` on all nodes) before starting; these always block and cannot be skipped. See [TROUBLESHOOTING](TROUBLESHOOTING.md#pre-migration-issues).

---

## Step 2: Start the migration

The simplest run migrates all eligible queues on the vhost:

```bash
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start
```

For any other vhost, put it in the URL path (URL-encoded); it cannot go in the body:

```bash
# Migrate vhost "/production"
curl -u guest:guest -X POST http://localhost:15672/api/queue-migration/start/%2Fproduction
```

The response returns a `migration_id` used to monitor progress:

```json
{
  "migration_id": "ZzJnQ2Jn...",
  "status": "started"
}
```

### Start options

All options go in the JSON request body and are optional. Any option that is present but has an invalid value is rejected with HTTP 400, never silently ignored.

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `skip_unsuitable_queues` | boolean | `false` | Skip queues that fail queue-level checks instead of blocking the whole migration. See [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md). |
| `batch_size` | integer or `"all"` | `all` | Migrate at most this many queues this run. `0` or `"all"` means all eligible. Ignored if `queue_names` is set. |
| `batch_order` | string | `"smallest_first"` | Selection order for batching: `"smallest_first"` or `"largest_first"`. Ignored if `queue_names` is set. |
| `queue_names` | array of strings | (unset) | Migrate only these queues. Takes precedence over `batch_size`/`batch_order`. Non-existent or ineligible names are logged and skipped. |
| `tolerance` | number 0.0-100.0 | (config defaults) | Per-queue message-count tolerance, applied to both under- and over-delivery. See [Message loss and verification](MESSAGE_LOSS_AND_VERIFICATION.md#the-tolerance-migration-option). |
| `allow_message_ttl` | boolean | `false` | Allow queues with a queue-level TTL to migrate. Forces `tolerance` to 100% for the entire run. See the `message_ttl` reason in [SKIP_UNSUITABLE_QUEUES](SKIP_UNSUITABLE_QUEUES.md). |
| `set_default_queue_type` | string | (unset) | After a successful migration, set the vhost default queue type to `"quorum"` or `"classic"`. See [Client Redeclaration](MIGRATION_GUIDE.md#client-redeclaration-after-migration). |

### Common invocations

Skip unsuitable queues and migrate the rest:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

Migrate in batches (useful for large vhosts), smallest queues first:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 10, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start/%2Fmy-vhost
```

Migrate specific queues by name:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["orders", "payments", "notifications"]}' \
  http://localhost:15672/api/queue-migration/start/%2Fproduction
```

Set a tolerance for queues whose publishers use per-message TTL, and set the vhost default so clients that omit `x-queue-type` keep working after migration:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"tolerance": 10.0, "set_default_queue_type": "quorum"}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

---

## Step 3: Monitor progress

List all migrations (most recent first):

```bash
curl -u guest:guest http://localhost:15672/api/queue-migration/status
```

Get per-queue detail for one migration:

```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>
```

A migration ends in one of: `completed`, `interrupted`, `failed`, or `rollback_pending`. For `failed`/`rollback_pending`, see [Migration Failures](TROUBLESHOOTING.md#migration-failures). The full status schema and all status values are in the [HTTP API Reference](HTTP_API.md#get-migration-status).

---

## Step 4: Interrupt (optional)

Gracefully stop a running migration:

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/interrupt/<migration_id>
```

Queues actively migrating finish; queues not yet started are marked `skipped` with reason `interrupted`, and the migration ends with status `interrupted`.

---

## Re-running and idempotency

Migration is idempotent: already-migrated (quorum) queues are filtered out, so you can safely start a new migration to pick up queues that were skipped, interrupted, or failed on a previous run, after addressing whatever blocked them. This is the normal way to work through a large vhost incrementally or to retry after fixing an issue.

---

## Related documentation

- [Migration Guide](MIGRATION_GUIDE.md) - how migration works, eligibility, argument conversion
- [Skip Unsuitable Queues](SKIP_UNSUITABLE_QUEUES.md) - the skip feature and every skip reason
- [Message Loss and Verification](MESSAGE_LOSS_AND_VERIFICATION.md) - tolerance, per-message TTL, `message_count_mismatch`
- [HTTP API Reference](HTTP_API.md) - full request/response schemas
- [Troubleshooting](TROUBLESHOOTING.md) - errors, diagnostics, recovery
