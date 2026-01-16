# Validation Chain Documentation

## CRITICAL: Read This Before Modifying Validation Logic

The validation chain is complex and error-prone. Multiple bugs have been introduced by not understanding its structure. This document explains how it works and how to modify it safely.

## Current Validation Chain Structure

The validation chain is implemented as a series of recursive function calls. Each validation step calls the next step on success.

### Chain Order (Both Modes)

1. `shovel_plugin` - Check rabbitmq_shovel plugin enabled
2. `khepri_disabled` - Check Khepri database disabled
3. `relaxed_checks_setting` - Check quorum queue relaxed checks enabled
4. `balanced_queue_leaders` - Check queue leaders balanced across nodes
5. `queue_synchronization` - Check all mirrors synchronized
6. `queue_suitability` - Check queues suitable for migration (message count, size, arguments)
7. `disk_space` - Check sufficient disk space available
8. `active_alarms` - Check no active alarms
9. `memory_usage` - Check memory usage within limits
10. `snapshot_not_in_progress` - Check no EBS snapshots in progress
11. `cluster_partitions` - Check no cluster partitions
12. `eligible_queue_count` - Check at least one queue eligible for migration

### Terminal Behavior (Step 12)

The `eligible_queue_count` check is ONLY called by `cluster_partitions` at the end of the chain. It has different behavior based on mode:

**Validation Mode (`validation_only`):**
- Returns `ok` if eligible queues exist
- Returns `{error, no_eligible_queues}` or `{error, no_matching_queues}` if none
- Does NOT start migration

**Migration Mode (`migration`):**
- Calls `start_with_new_migration_id` to begin migration
- Returns result of migration

### Code Flow

```erlang
% Entry point
pre_migration_validation(shovel_plugin, Opts) ->
    handle_check_shovel_plugin(rqm_checks:check_shovel_plugin(), Opts).

% Each handler calls next step on success
handle_check_shovel_plugin(ok, Opts) ->
    pre_migration_validation(khepri_disabled, Opts).

% ... chain continues through all steps ...

% Terminal step
handle_check_cluster_partitions({ok, Nodes}, Opts) ->
    handle_check_eligible_queue_count(rqm_checks:check_eligible_queue_count(Opts), Nodes).

% Mode-dependent terminal behavior
handle_check_eligible_queue_count({ok, #migration_opts{mode = validation_only}}, _Nodes) ->
    ok;
handle_check_eligible_queue_count({ok, Opts}, Nodes) ->
    MigrationResult = start_with_new_migration_id(Nodes, Opts, generate_migration_id()),
    handle_migration_result(MigrationResult, Opts#migration_opts.vhost).
```

## Common Mistakes and How to Avoid Them

### Mistake 1: Creating Infinite Loops

**What happened:** Added `eligible_queue_count` as a regular validation step in the middle of the chain. Since `cluster_partitions` also calls `eligible_queue_count`, this created a loop:

```
cluster_partitions -> eligible_queue_count -> queue_suitability -> ... -> cluster_partitions
```

**How to avoid:** 
- `eligible_queue_count` is SPECIAL - it's only called at the end by `cluster_partitions`
- Never add it as a regular `pre_migration_validation` clause
- Never call it from any handler except `handle_check_cluster_partitions`

### Mistake 2: Starting Migration in Validation Mode

**What happened:** Removed the mode check from `handle_check_eligible_queue_count`, causing validation to start actual migrations.

**How to avoid:**
- `handle_check_eligible_queue_count` MUST check mode
- Validation mode returns `ok`
- Migration mode starts migration

### Mistake 3: Breaking the Chain

**What happened:** Handler returned wrong type or called wrong next step, breaking the chain flow.

**How to avoid:**
- Each handler must call `pre_migration_validation(next_step, Opts)` on success
- Handlers return `{error, ...}` on failure
- The chain is linear except for the terminal step

## Modifying the Validation Chain

### Adding a New Check (Non-Terminal)

1. Add check function to `rqm_checks` module
2. Add `pre_migration_validation(your_check, Opts)` clause
3. Add `handle_check_your_check` function
4. Insert into chain by modifying the PREVIOUS step's handler to call your check
5. Your handler calls the NEXT step on success

**Example: Adding a check between `disk_space` and `active_alarms`:**

```erlang
% Add clause
pre_migration_validation(your_new_check, Opts) ->
    handle_check_your_new_check(rqm_checks:check_your_new_check(Opts), Opts).

% Add handler
handle_check_your_new_check(ok, Opts) ->
    pre_migration_validation(active_alarms, Opts);
handle_check_your_new_check({error, Reason}, _Opts) ->
    {error, Reason}.

% Modify previous step
handle_check_disk_space({ok, sufficient}, Opts) ->
    pre_migration_validation(your_new_check, Opts);  % Changed from active_alarms
```

### Modifying the Terminal Check

**DO NOT** add `eligible_queue_count` to the middle of the chain. It's only called by `cluster_partitions`.

If you need to modify eligible queue logic:
1. Modify `rqm_checks:check_eligible_queue_count/1`
2. Modify `handle_check_eligible_queue_count/2` if needed
3. DO NOT add `pre_migration_validation(eligible_queue_count, ...)` clause

## Proposed Refactor

The current pattern is error-prone. A better approach:

### List-Based Validation Chain

```erlang
validation_checks() ->
    [
        {shovel_plugin, fun rqm_checks:check_shovel_plugin/0},
        {khepri_disabled, fun rqm_checks:check_khepri_disabled/0},
        {relaxed_checks, fun rqm_checks:check_relaxed_checks_setting/0},
        {leader_balance, fun(Opts) -> 
            rqm_checks:check_leader_balance(Opts#migration_opts.vhost) end},
        {queue_sync, fun(Opts) -> 
            rqm_checks:check_queue_synchronization(Opts#migration_opts.vhost) end},
        {queue_suitability, fun(Opts) -> 
            rqm_checks:check_queue_suitability(Opts#migration_opts.vhost) end},
        {disk_space, fun(Opts) -> 
            rqm_checks:check_disk_space(Opts#migration_opts.vhost, 
                                        Opts#migration_opts.unsuitable_queues) end},
        {active_alarms, fun rqm_checks:check_active_alarms/0},
        {memory_usage, fun rqm_checks:check_memory_usage/0},
        {snapshot, fun rqm_checks:check_snapshot_not_in_progress/0},
        {cluster_partitions, fun rqm_checks:check_cluster_partitions/0},
        {eligible_queue_count, fun rqm_checks:check_eligible_queue_count/1}
    ].

run_validation_chain(Opts) ->
    run_validation_chain(validation_checks(), Opts, []).

run_validation_chain([], Opts, _Nodes) ->
    {ok, Opts};
run_validation_chain([{CheckName, CheckFun} | Rest], Opts, Nodes) ->
    case apply_check(CheckFun, Opts) of
        ok -> 
            run_validation_chain(Rest, Opts, Nodes);
        {ok, UpdatedOpts} -> 
            run_validation_chain(Rest, UpdatedOpts, Nodes);
        {ok, Nodes} when CheckName =:= cluster_partitions ->
            % Terminal: cluster_partitions returns nodes, proceed to final check
            run_validation_chain(Rest, Opts, Nodes);
        {error, _} = Error -> 
            Error
    end.

% After chain completes, check mode and start migration if appropriate
finalize_validation({ok, Opts}, Nodes) ->
    case Opts#migration_opts.mode of
        validation_only -> ok;
        migration -> start_with_new_migration_id(Nodes, Opts, generate_migration_id())
    end.
```

### Benefits of Refactor

1. **Clear ordering** - All checks listed in one place
2. **No manual chaining** - Can't forget to call next step
3. **Can't create loops** - Linear list prevents cycles
4. **Easy to modify** - Add/remove/reorder checks in the list
5. **Testable** - Can test chain execution independently
6. **Mode handling** - Centralized in `finalize_validation`

### Implementation Plan

1. Create new module `rqm_validation_chain.erl`
2. Implement list-based chain execution
3. Keep old chain as fallback during transition
4. Add feature flag to switch between old/new
5. Test thoroughly with both implementations
6. Remove old chain once new one is proven stable

## Rules for Future Modifications

1. **NEVER add `eligible_queue_count` to the middle of the chain**
2. **ALWAYS check mode in terminal handler**
3. **DRAW the chain on paper before modifying**
4. **TEST both validation and migration modes after changes**
5. **When in doubt, ask before implementing**

## Testing Checklist

After modifying the validation chain, test:

- [ ] Validation mode returns ok without starting migration
- [ ] Migration mode starts migration after validation
- [ ] Each check can fail and stop the chain
- [ ] skip_unsuitable_queues updates Opts correctly
- [ ] No infinite loops (validation completes in reasonable time)
- [ ] No crashes or exceptions

## Historical Bugs

### Bug 1: Infinite Loop (2026-01-16)
- **Cause:** Added `eligible_queue_count` as regular validation step
- **Symptom:** Validation hung, never returned
- **Fix:** Remove from middle of chain, only call from `cluster_partitions`

### Bug 2: Migration Started in Validation Mode (2026-01-16)
- **Cause:** Removed mode check from `handle_check_eligible_queue_count`
- **Symptom:** Validation started actual migration, hung at 100%
- **Fix:** Add mode check to return ok in validation_only mode

**Detailed explanation of Bug 2:**

1. Java client calls start API with 30-second timeout
2. API runs validation (validation_only mode) to check if migration is safe
3. Validation reaches the end and calls `eligible_queue_count` check
4. BUG: `eligible_queue_count` starts a migration even though we're in validation mode
5. Migration spawns and begins running in the background
6. But the validation never returns - it's stuck waiting for this wrongly-started migration
7. Java client times out after 30 seconds because the API never responds
8. Meanwhile, the migration keeps running and completes all queues (10/10 or 20/20)
9. But the migration is in the wrong context - started by validation, not normal flow
10. The migration process exits or hangs without finalizing the status
11. Status stays "in_progress" forever because finalization code never runs

**Why it hung:** The migration was started in validation mode context, which doesn't have proper setup to finalize. Like starting a car in neutral - engine runs but you don't go anywhere.

**The fix:** Check mode before starting migration. Validation mode returns ok, migration mode starts migration.
