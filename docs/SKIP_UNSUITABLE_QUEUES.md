# Skip Unsuitable Queues Feature Guide

**Last Updated:** January 21, 2026

This guide explains the skip unsuitable queues feature, when to use it, and how to handle skipped queues.

---

## Overview

The skip unsuitable queues feature allows migrations to proceed by skipping queues that fail validation checks, rather than blocking the entire migration. This enables incremental migrations where you can migrate suitable queues immediately and address problematic queues separately.

---

## When to Use

### Recommended Scenarios

1. **Large deployments with mixed queue types**
   - Some queues have unsuitable configurations
   - Want to migrate the majority without fixing every issue first

2. **Incremental migration approach**
   - Migrate what's possible now
   - Fix problematic queues later
   - Migrate remaining queues in subsequent runs

3. **Testing migrations**
   - Want to see which queues would be skipped
   - Validate migration works for suitable queues
   - Identify issues before full migration

### When NOT to Use

1. **Small deployments** - Better to fix all issues first
2. **Critical queues** - If skipped queues are business-critical, fix them first
3. **Strict requirements** - If all queues must migrate together

---

## How to Enable

### Via HTTP API

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/start
```

### Via Web UI

1. Navigate to Admin → Queue Migration
2. Check the "Skip unsuitable queues" checkbox
3. Click "Start Migration"

### Via Compatibility Check

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

This shows which queues would be unsuitable without starting migration.

---

## Skip Reasons

Queues can be skipped for the following reasons:

### 1. `unsynchronized`

**Cause:** Classic mirrored queue has unsynchronized mirrors

**Impact:** Queue data may not be fully replicated

**Resolution:**
```bash
# Wait for synchronization
rabbitmqctl list_queues name synchronised_slave_pids

# Force sync (may impact performance)
rabbitmqctl sync_queue <queue_name>

# Then migrate in subsequent run
```

---

### 2. `too_many_queues`

**Cause:** Too many queues in the vhost to migrate safely at once

**Resolution:**

**Option A:** Use batch migration
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"batch_size": 50, "batch_order": "smallest_first"}' \
  http://localhost:15672/api/queue-migration/start
```

**Option B:** Migration with skip mode automatically handles this
- Queues exceeding safe limit are skipped
- Can be migrated in subsequent runs

---

### 3. `unsuitable_overflow`

**Cause:** Queue has `overflow: reject-publish-dlx` argument

**Why Unsuitable:** This overflow policy is incompatible with quorum queues

**Resolution:**

**Option A:** Change overflow policy
```bash
# Delete and recreate queue with different policy
# Or use policy to override:
rabbitmqctl set_policy overflow-policy "^<queue_pattern>$" \
  '{"overflow":"drop-head"}' --apply-to queues
```

**Option B:** Accept that queue cannot be migrated to quorum type

---

### 4. `queue_expires`

**Cause:** Queue has `x-expires` argument or `expires` policy

**Why Unsuitable:** The queue could expire and be deleted during the migration process, causing migration failure

**Resolution:**

**Option A:** Remove the expires setting
```bash
# If set via policy, remove or modify the policy:
rabbitmqctl clear_policy <policy_name>

# If set via queue argument, delete and recreate queue without x-expires
```

**Option B:** Drain the queue and let it expire naturally before migration

**Option C:** Accept that queue cannot be migrated (it will expire eventually anyway)

---

### 5. `message_ttl`

**Cause:** Queue has `x-message-ttl` argument or `message-ttl` policy

**Why Unsuitable:** Messages could expire during the migration process, causing message count mismatches that fail verification

**Resolution:**

**Option A:** Remove the TTL setting temporarily
```bash
# If set via policy, remove or modify the policy:
rabbitmqctl clear_policy <policy_name>

# If set via queue argument, delete and recreate queue without x-message-ttl
# Then migrate, then reapply TTL to the quorum queue
```

**Option B:** Drain the queue before migration (let consumers process all messages)

**Option C:** Accept that queue cannot be migrated and handle separately

---

## ⚠️ Important: Per-Message TTL Limitation

**This plugin can only detect queue-level TTL settings (`x-message-ttl` argument or `message-ttl` policy). It CANNOT detect per-message TTL.**

Publishers can set TTL on individual messages using the `expiration` message property. See [Per-Message TTL in Publishers](https://www.rabbitmq.com/docs/3.13/ttl#per-message-ttl-in-publishers) in the RabbitMQ documentation.

**Why this matters:**

If your publishers set per-message TTL and messages expire during migration, the message count verification will detect a difference between source and destination queues.

### Solution: Message Count Tolerance

Use the `tolerance` parameter to allow migrations to succeed despite message count differences:

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"tolerance": 10.0}' \
  http://localhost:15672/api/queue-migration/start/%2F
```

The tolerance is a **per-queue percentage** (0.0-100.0). A queue passes verification if the message count difference is within the tolerance. For example, with `tolerance: 10.0`, a queue with 100 source messages passes if the destination has 90-100 messages.

**How to determine the right tolerance:**

1. Estimate what percentage of messages have per-message TTL
2. Add a safety margin (e.g., if 5% have TTL, use 10% tolerance)
3. Monitor migration logs for "within tolerance" warnings

**Alternative approaches:**

1. Drain queues before migration (let consumers process all messages)
2. Ensure per-message TTL values are long enough that messages won't expire during migration
3. Temporarily disable publishers that set per-message TTL

**Note:** There is no way for this plugin to detect per-message TTL - it is set by publishers on each message and is not visible at the queue level.

---

### 6. `interrupted`

**Cause:** Migration was manually interrupted

**Resolution:**
```bash
# Start new migration
# Already-completed queues will be skipped automatically
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

---

## Checking Skipped Queues

### Via HTTP API

```bash
curl -u guest:guest \
  http://localhost:15672/api/queue-migration/status/<migration_id>
```

Response includes:
```json
{
  "migration": {
    "status": "completed",
    "completed_queues": 45,
    "skipped_queues": 5,
    "total_queues": 50
  },
  "queues": [
    {
      "resource": {
        "name": "problem.queue.1",
        "vhost": "/"
      },
      "status": "skipped",
      "error": "too_many_queues"
    },
    {
      "resource": {
        "name": "problem.queue.2",
        "vhost": "/"
      },
      "status": "skipped",
      "error": "unsuitable_overflow"
    }
  ]
}
```

### Via Web UI

1. Navigate to Admin → Queue Migration
2. Click on migration ID in history table
3. View queue details table
4. Filter by status "skipped"
5. Check error column for skip reason

---

## Migrating Skipped Queues

After addressing the issues that caused queues to be skipped:

### Step 1: Fix the Issues

Address each skip reason as documented above.

### Step 2: Verify Fixes

```bash
# Check compatibility
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/check/%2F

# Or with skip mode to see remaining unsuitable queues
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

### Step 3: Start New Migration

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
{
  "skip_unsuitable_queues": true  # Optional, if some issues remain
}
```

**Idempotency:** Already-migrated queues are automatically skipped, so you can safely run migration again.

---

## Best Practices

### 1. Run Compatibility Check First

Always check compatibility before migration:
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

This shows:
- Which queues would be unsuitable
- Why they would be unsuitable
- How many queues would migrate successfully

### 2. Address Critical Queues First

If business-critical queues would be skipped:
1. Fix those queues first
2. Run migration without skip mode
3. Ensures critical queues migrate successfully

### 3. Use Batch Migration with Skip Mode

For large deployments:
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "skip_unsuitable_queues": true,
    "batch_size": 50,
    "batch_order": "smallest_first"
  }' \
  http://localhost:15672/api/queue-migration/start
```

This provides:
- Incremental progress
- Reduced resource pressure
- Ability to fix issues between batches

### 4. Monitor Skipped Queue Count

After migration:
1. Check how many queues were skipped
2. Review skip reasons
3. Plan remediation for skipped queues
4. Schedule follow-up migration

### 5. Document Skipped Queues

Keep track of:
- Which queues were skipped
- Why they were skipped
- When issues will be addressed
- Who is responsible for fixes

---

## Example Workflow

### Scenario: 1000-queue vhost with mixed configurations

#### Step 1: Initial Compatibility Check

```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"skip_unsuitable_queues": true}' \
  http://localhost:15672/api/queue-migration/check/%2F
```

**Result:** 950 suitable, 50 unsuitable
- 30 unsynchronized
- 15 too many queues
- 5 unsuitable overflow

#### Step 2: First Migration (Suitable Queues)

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

**Result:** 100 queues migrated, 900 remaining (850 suitable + 50 unsuitable)

#### Step 3: Continue Batch Migrations

Repeat until all suitable queues migrated (850 total).

#### Step 4: Address Unsuitable Queues

- Sync the 30 unsynchronized queues
- Reduce queue count or use batch migration for the 15 queues flagged as too many
- Change overflow policy on 5 queues

#### Step 5: Final Migration

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/queue-migration/start
```

**Result:** All 1000 queues now quorum type

---

## Limitations

### System-Level Checks Still Block

Skip mode only applies to queue-level checks. These system-level checks still block migration:

- Shovel plugin not enabled
- Khepri enabled (must be disabled for migration)
- Insufficient disk space
- Cluster alarms active
- Memory pressure
- Network partitions
- Unbalanced queue leaders
- EBS snapshots in progress

**Reason:** These issues affect the entire migration process, not individual queues.

### Skipped Queues Require Attention

Skipped queues remain as classic queues and still need to be addressed:
- They don't automatically migrate later
- Issues must be fixed manually
- Subsequent migration required

---

## FAQ

**Q: Can I migrate only specific queues?**  
A: Yes - use the `queue_names` parameter:
```bash
curl -u guest:guest -X POST \
  -H "Content-Type: application/json" \
  -d '{"queue_names": ["queue1", "queue2", "queue3"]}' \
  http://localhost:15672/api/queue-migration/start
```

**Q: What happens to messages in skipped queues?**  
A: Nothing - they remain in the classic queue unchanged.

**Q: Can I retry skipped queues automatically?**  
A: Not currently - you must fix issues and start a new migration.

**Q: Does skip mode affect performance?**  
A: No - skipped queues are filtered out early in the process.

**Q: Can I see which queues would be skipped before migrating?**  
A: Yes - use the compatibility check with `skip_unsuitable_queues=true`.

---

## Related Documentation

- **HTTP API Reference:** HTTP_API.md
- **Troubleshooting Guide:** TROUBLESHOOTING.md
- **Integration Tests:** INTEGRATION_TESTS.md (see SkipUnsuitableTest)
