# Snapshot Support

**Last Updated:** January 21, 2026

This guide explains the snapshot functionality in the RabbitMQ Queue Migration Plugin, including the three supported modes and their configuration.

---

## Overview

The plugin creates snapshots before migration to enable rollback in case of failure. Snapshots capture the RabbitMQ data directory state, allowing recovery if migration encounters issues.

Three snapshot modes are supported:
- **EBS Mode** (default) - AWS EBS snapshots for production
- **Tar Mode** - Tar archives for development/testing
- **None Mode** - Disabled (snapshots handled externally or not needed)

---

## Tar Mode (Development/Testing)

Creates tar.gz archives of the RabbitMQ data directory. Use this mode for development and testing environments where EBS snapshots are not available.

### Configuration

**Using `rabbitmq.conf`:**
```ini
queue_migration.snapshot_mode = tar
```

**Using `advanced.config`:**
```erlang
{rabbitmq_queue_migration, [
  {snapshot_mode, tar}
]}
```

### Snapshot Location

Snapshots are stored in:
```
/tmp/rabbitmq_migration_snapshots/{ISO8601_timestamp}/{node_name}.tar.gz
```

**Example:**
```
/tmp/rabbitmq_migration_snapshots/2025-12-21T17:30:00Z/rabbit@node1.tar.gz
```

### Cleanup

Controlled by `cleanup_snapshots_on_success` setting (default: `true`).

When enabled, tar archives are automatically deleted after successful migration. When disabled, archives remain for manual cleanup or audit purposes.

---

## EBS Mode (Production - Default)

Creates AWS EBS snapshots using the EC2 API. This is the default mode for production deployments running on AWS EC2.

### Configuration

**Using `rabbitmq.conf` (optional, these are defaults):**
```ini
queue_migration.snapshot_mode = ebs
queue_migration.ebs_volume_device = /dev/sdh
```

**Using `advanced.config`:**
```erlang
{rabbitmq_queue_migration, [
  {snapshot_mode, ebs},
  {ebs_volume_device, "/dev/sdh"}
]}
```

### Requirements

1. **EBS Volume**
   - RabbitMQ data directory must be on an EBS volume
   - Volume must be attached at the configured device path (default: `/dev/sdh`)

2. **IAM Permissions**
   - `ec2:CreateSnapshot` - Create EBS snapshots
   - `ec2:DescribeVolumes` - Query attached volumes
   - `ec2:DescribeSnapshots` - Check snapshot status
   - `ec2:CreateTags` - Tag snapshots with metadata
   - `ec2:DeleteSnapshot` - Delete snapshots after successful migration

3. **AWS Credentials**
   - EC2 instance role (recommended)
   - Credentials automatically retrieved from instance metadata service

### Snapshot Naming

EBS snapshots are created with descriptive names:
```
Description: "RabbitMQ migration snapshot {ISO8601_timestamp} on {node_name}"
```

**Example:**
```
Description: "RabbitMQ migration snapshot 2025-12-21T17:30:00Z on rabbit@node1"
```

### Cleanup

Controlled by `cleanup_snapshots_on_success` setting (default: `true`).

When enabled, EBS snapshots are automatically deleted after successful migration. When disabled, snapshots remain in your AWS account for manual management.

**Cost Consideration:** EBS snapshots incur storage costs. If cleanup is disabled, implement a lifecycle policy or cleanup script to manage retention and costs.

### IAM Setup

See [EC2_SETUP](EC2_SETUP.md) for detailed IAM role configuration and setup instructions.

---

## None Mode (Disabled)

Disables snapshot creation entirely. Use this mode when:
- Snapshots are handled externally
- Rollback capability is not needed
- Testing in environments without snapshot support

### Configuration

**Using `rabbitmq.conf`:**
```ini
queue_migration.snapshot_mode = none
```

**Using `advanced.config`:**
```erlang
{rabbitmq_queue_migration, [
  {snapshot_mode, none}
]}
```

**Warning:** Without snapshots, rollback after migration failure requires manual intervention and may result in data loss.

---

## Snapshot Cleanup Configuration

### `cleanup_snapshots_on_success`

**Type:** Boolean  
**Default:** true  
**Description:** Whether to delete snapshots after successful migration

**Using `rabbitmq.conf`:**
```ini
queue_migration.cleanup_snapshots_on_success = false
```

**Using `advanced.config`:**
```erlang
{rabbitmq_queue_migration, [
  {cleanup_snapshots_on_success, false}
]}
```

**When to Disable:**
- Audit requirements mandate snapshot retention
- Want to keep snapshots for additional safety
- Testing rollback procedures

**When Disabled:**
- Tar mode: Archives remain in `/tmp/rabbitmq_migration_snapshots/`
- EBS mode: Snapshots remain in AWS account (incurs storage costs)
- Manual cleanup required

---

## Related Documentation

- **EC2 IAM Setup:** [EC2_SETUP](EC2_SETUP.md)
- **Configuration Reference:** [CONFIGURATION](CONFIGURATION.md)
- **Troubleshooting:** [TROUBLESHOOTING](TROUBLESHOOTING.md)
