# Future Work - RabbitMQ Queue Migration Plugin

**Last Updated:** January 8, 2026
**Status:** Planning for next development session

## Immediate Tasks

### 1. Per-Migration Tolerance Configuration

**Feature:** Allow users to specify message count tolerances when starting a migration

**API Design:**
```bash
PUT /api/queue-migration/start
Content-Type: application/json
{
  "over_tolerance": 10.0,
  "under_tolerance": 1.0
}
```

**Implementation:**
- Accept optional `over_tolerance` and `under_tolerance` in request body
- Validate range: 0.0-100.0 for both parameters
- Store in migration record for consistent use throughout migration
- Fall back to configured defaults if not specified
- Update Web UI to provide input fields for these parameters

**Benefits:**
- Per-migration control without changing global configuration
- Useful for testing different tolerance levels
- Allows stricter verification for critical migrations
- More lenient for development/testing migrations

### 2. Limit Number of Queues to Migrate

**Feature:** Allow users to specify maximum number of queues to migrate in a single migration run

**Current Behavior:**
- Migration processes ALL eligible queues in the vhost
- `max_queues_for_migration` (500) is a validation limit, not a migration limit
- No way to do incremental migrations

**API Design:**
```bash
PUT /api/queue-migration/start
Content-Type: application/json
{
  "max_queues": 50
}
```

**Implementation:**
- Accept optional `max_queues` parameter in request body
- Validate: must be positive integer, cannot exceed `max_queues_for_migration` config
- Limit queue selection to first N eligible queues
- Store in migration record for tracking
- Update Web UI to provide input field

**Benefits:**
- Incremental migrations for large deployments
- Test migrations with small batches
- Reduce resource pressure by migrating in waves
- Easier to pause/resume migration process
- Lower risk - migrate critical queues first, others later

**Use Cases:**
- "Migrate 10 queues to test the process"
- "Migrate 100 queues per day over a week"
- "Migrate high-priority queues first"

### 3. Skip Unsuitable Queues Instead of Blocking Migration

**Feature:** Allow migrations to proceed by skipping queues that fail validation

**Current Behavior:**
- Any unsuitable queue blocks the entire migration
- All queues must pass validation or none migrate
- User must fix all issues before any migration can proceed

**Proposed Behavior:**
- System-level checks still block (shovel plugin, Khepri, disk space, alarms, memory, snapshots, partitions, leader balance)
- Queue-level checks identify queues to skip (unsynchronized, too many messages/bytes, incompatible arguments)
- Migration proceeds with suitable queues, skips unsuitable ones
- Skipped queues tracked in migration record with skip reasons

**API Design:**
```bash
PUT /api/queue-migration/start
Content-Type: application/json
{
  "skip_unsuitable_queues": true
}

GET /api/queue-migration/compatibility?skip_unsuitable_queues=true
```

**Implementation Changes:**

1. **Migration Record**: Add `skipped_queues` field to track skipped queues with reasons
2. **Validation Chain**: 
   - `check_queue_synchronization` returns list of unsynchronized queues instead of error
   - `check_queue_suitability` returns list of unsuitable queues instead of error
3. **Migration Logic**: Filter out skipped queues before processing
4. **Status API**: Include skipped queues in response with skip reasons
5. **Compatibility API**: When `skip_unsuitable_queues=true`, show unsuitable queues as "will be skipped" instead of errors
6. **Web UI**: Display skipped queues separately from migrated/failed queues

**Skip Reasons:**
- `unsynchronized` - Queue mirrors not synchronized
- `too_many_messages` - Message count exceeds limit
- `too_many_bytes` - Byte count exceeds limit
- `incompatible_overflow` - Has `reject-publish-dlx` argument
- `too_many_queues` - Part of batch exceeding queue count limit

**Benefits:**
- Migrate what's possible without fixing every issue first
- Incremental approach - fix problematic queues and migrate them later
- Reduces migration friction for large deployments
- Better user experience - progress instead of all-or-nothing

**Considerations:**
- Need clear reporting of which queues were skipped and why
- Users must understand skipped queues still need attention
- May need separate API to "retry skipped queues"

### 4. Investigate Message Count Discrepancies

**Issue:** Post-migration verification occasionally shows message count mismatches (e.g., 306 actual vs 300 expected).

**Observations:**
- Occurs with no active connections during migration
- Extra messages appear in destination queue
- Current workaround: Configurable tolerance (5% over, 2% under)

**Investigation needed:**
- Trace shovel message delivery to understand duplication
- Check if messages are counted during in-flight state
- Verify shovel `ack-mode: on-confirm` behavior
- Determine if this is timing, prefetch, or actual duplication

**Questions:**
- Could prefetch cause double-counting?
- Are messages acknowledged before being counted as delivered?
- Does shovel retry logic cause duplicates?

### 2. Optimize Shovel Prefetch for Different Workloads

**Current:** Default 1024, now configurable

**Testing needed:**
- Small messages (< 1KB): Test higher prefetch (2048, 4096)
- Large messages (> 100KB): Test lower prefetch (256, 512)
- Measure impact on migration speed and memory usage

### 3. Document Shovel Exception Patterns

**Observed exceptions:**
- `noproc` during shovel creation (handled with retry)
- `badmatch` during shovel cleanup (handled with case catch)

**Documentation needed:**
- Add to DEBUGGING_SESSIONS.md
- Explain when each occurs
- Document retry/handling strategies

## Testing Priorities

### 1. Large-Scale Testing

**Scenarios:**
- 5000+ queues
- Mixed message sizes (1KB to 1MB)
- High message volumes (100K+ per queue)
- Multi-region clusters

### 2. Failure Scenario Testing

**Cases:**
- Node failures during migration
- Network partitions mid-migration
- Disk space exhaustion
- Memory pressure conditions
- Concurrent migrations (should be prevented)

### 3. Performance Benchmarking

**Metrics:**
- Migration rate vs queue count
- Impact of message size on throughput
- Worker pool scaling efficiency
- Memory usage patterns

## Known Issues

### 1. Message Count Mismatches

**Status:** Mitigated with configurable tolerance

**Root cause:** Under investigation

**Workaround:** Set appropriate tolerance percentages

### 2. Shovel Supervisor Availability

**Status:** Mitigated with retry logic

**Symptom:** `noproc` errors during shovel creation

**Solution:** 10 retries with 1-second delays

### 3. Shovel Cleanup Race Condition

**Status:** Handled gracefully

**Symptom:** Badmatch in `mirrored_supervisor:child/2`

**Solution:** `case catch` in cleanup code

**Upstream:** PR submitted to RabbitMQ main branch to fix `mirrored_supervisor:child/2`

## Configuration Tuning Guide

### For Small Messages (< 1KB)

```erlang
{shovel_prefetch_count, 2048},  % Higher prefetch for throughput
{worker_pool_max, 16}            % More workers if you have cores
```

### For Large Messages (> 100KB)

```erlang
{shovel_prefetch_count, 256},              % Lower prefetch to reduce memory
{base_max_message_bytes_in_queue, 1073741824}  % 1 GiB limit
```

### For Strict Data Integrity

```erlang
{message_count_over_tolerance_percent, 0.0},   % No extra messages allowed
{message_count_under_tolerance_percent, 0.0}   % No missing messages allowed
```

### For Lenient Migration (Development)

```erlang
{message_count_over_tolerance_percent, 10.0},  % Allow 10% extra
{message_count_under_tolerance_percent, 5.0}   % Allow 5% missing
```

## Questions for Next Session

1. **Message count discrepancies** - What causes the extra messages?
2. **Shovel lifecycle** - When exactly does the badmatch race occur?
3. **Performance optimization** - Can we improve migration speed further?
4. **Rollback testing** - How to test rollback scenarios safely?

## Reference Documents

- **AGENTS.md** - Complete technical architecture and implementation details
- **DEBUGGING_SESSIONS.md** - Detailed debugging sessions and Erlang deep dives
- **HTTP_API.md** - Complete HTTP API reference
- **INTEGRATION_TESTING.md** - Integration testing guide
- **EC2_SETUP.md** - AWS EC2 and IAM configuration guide
