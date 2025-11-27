<!-- vim:tw=125:
-->
# EC2 IAM Setup for RabbitMQ Queue Migration Plugin

This document describes how to configure IAM permissions for EC2 instances running RabbitMQ to enable the
`rabbitmq_queue_migration` plugin to create EBS snapshots during queue migration operations.

## Overview

The RabbitMQ queue migration plugin requires EC2 API access to:
- Query attached EBS volumes (`ec2:DescribeVolumes`)
- Create snapshots of those volumes (`ec2:CreateSnapshot`)
- Check snapshot status (`ec2:DescribeSnapshots`)
- Tag snapshots for identification (`ec2:CreateTags`)

When running on EC2 instances, the `rabbitmq_aws` SDK automatically retrieves temporary credentials (including session tokens) from the
EC2 instance metadata service. This requires an IAM instance profile to be attached to each RabbitMQ node.

## Prerequisites

- 3-node RabbitMQ cluster running on EC2 instances
- Instances tagged with identifiable names (e.g., `Name=RabbitMQ-Node-1`)
- AWS CLI configured with appropriate permissions to create IAM roles and modify EC2 instances
- Authenticated AWS session (`aws sts get-caller-identity` should succeed)

## Setup Steps

### Step 1: Identify Your RabbitMQ Instances

List your RabbitMQ instances by tag to get their instance IDs:

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=RabbitMQ-Node-*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name]' \
  --output table
```

**Note:** Adjust the tag filter (`Name=tag:Name,Values=...`) to match your instance naming convention.

### Step 2: Create IAM Role

Create an IAM role that EC2 instances can assume:

```bash
aws iam create-role \
  --role-name RabbitMQ-EC2-Snapshot-Role \
  --description "IAM role for RabbitMQ instances to create and manage EBS snapshots during queue migration" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'
```

**Note:** Role names can be customized to match your naming conventions.

### Step 3: Attach Permissions Policy

Create an inline policy granting EC2 snapshot permissions:

```bash
aws iam put-role-policy \
  --role-name RabbitMQ-EC2-Snapshot-Role \
  --policy-name EC2-Snapshot-Policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:CreateSnapshot",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    }]
  }'
```

**Security Note:** This policy grants permissions to all resources (`"Resource": "*"`). For production environments, consider
restricting permissions to specific volumes or using condition keys to limit scope:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeVolumes",
      "ec2:CreateSnapshot",
      "ec2:DescribeSnapshots",
      "ec2:CreateTags"
    ],
    "Resource": "*",
    "Condition": {
      "StringEquals": {
        "ec2:ResourceTag/Purpose": "RabbitMQ-Migration-Testing"
      }
    }
  }]
}
```

### Step 4: Create Instance Profile

Create an instance profile to attach the role to EC2 instances:

```bash
aws iam create-instance-profile \
  --instance-profile-name RabbitMQ-EC2-Snapshot-InstanceProfile
```

Add the role to the instance profile:

```bash
aws iam add-role-to-instance-profile \
  --role-name RabbitMQ-EC2-Snapshot-Role \
  --instance-profile-name RabbitMQ-EC2-Snapshot-InstanceProfile
```

### Step 5: Attach Instance Profile to EC2 Instances

#### Case A: Instances Without Existing Instance Profiles

If your instances don't have an instance profile attached, associate the new profile directly:

```bash
# For each RabbitMQ instance
aws ec2 associate-iam-instance-profile \
  --region us-east-1 \
  --instance-id i-0736c9abba774b7a0 \
  --iam-instance-profile Name=RabbitMQ-EC2-Snapshot-InstanceProfile
```

Repeat for all 3 nodes, replacing the instance ID each time.

#### Case B: Instances With Existing Instance Profiles

If your instances already have an instance profile (e.g., for SSM access), you need to replace it.

First, get the current association IDs:

```bash
aws ec2 describe-iam-instance-profile-associations \
  --region us-east-1 \
  --filters "Name=instance-id,Values=i-0736c9abba774b7a0,i-060a61b730577617f,i-005e054feac585e82"
```

Then replace each association:

```bash
# For each instance, use its association ID
aws ec2 replace-iam-instance-profile-association \
  --region us-east-1 \
  --association-id iip-assoc-03c37db4054d79661 \
  --iam-instance-profile Name=RabbitMQ-EC2-Snapshot-InstanceProfile
```

**Note:** If you need to preserve existing permissions (e.g., SSM access), you should add those permissions to the
`RabbitMQ-EC2-Snapshot-Role` instead of replacing the profile. Alternatively, attach multiple managed policies to the role.

### Step 6: Verify Setup

Verify that all instances have the correct instance profile:

```bash
aws ec2 describe-iam-instance-profile-associations \
  --region us-east-1 \
  --filters "Name=instance-id,Values=i-0736c9abba774b7a0,i-060a61b730577617f,i-005e054feac585e82" \
  --query 'IamInstanceProfileAssociations[].[InstanceId,IamInstanceProfile.Arn,State]' \
  --output table
```

Expected output should show all instances with `RabbitMQ-EC2-Snapshot-InstanceProfile` in "associated" state.

## Testing and Verification

### Test from EC2 Instance

SSH into one of your RabbitMQ nodes and test the EC2 API access:

```bash
# Test describe-volumes (should succeed without explicit credentials)
aws ec2 describe-volumes \
  --region us-east-1 \
  --filters "Name=attachment.instance-id,Values=$(ec2-metadata --instance-id | cut -d ' ' -f 2)"

# Verify credentials are being retrieved from instance metadata (IMDSv2)
# First, get a token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# List available roles
curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/iam/security-credentials/

# Get credentials for the role
ROLE_NAME=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME
```

The last command should return temporary credentials including:
- `AccessKeyId` (starts with `ASIA` for temporary credentials)
- `SecretAccessKey`
- `Token` (session token)
- `Expiration` (credentials auto-refresh before expiring)

**Note:** These commands use IMDSv2 (Instance Metadata Service Version 2), which requires a session token for security. Your
instances are configured with `HttpTokens: required`, which enforces IMDSv2.

### Test Snapshot Creation

Create a test snapshot to verify full permissions:

```bash
# Get the volume ID of the RabbitMQ data volume
VOLUME_ID=$(aws ec2 describe-volumes \
  --region us-east-1 \
  --filters "Name=attachment.instance-id,Values=$(ec2-metadata --instance-id | cut -d ' ' -f 2)" \
            "Name=attachment.device,Values=/dev/sdh" \
  --query 'Volumes[0].VolumeId' \
  --output text)

# Create a test snapshot
aws ec2 create-snapshot \
  --region us-east-1 \
  --volume-id "$VOLUME_ID" \
  --description "Test snapshot for RabbitMQ queue migration" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Purpose,Value=Test}]"
```

If successful, you'll receive a snapshot ID. Clean up the test snapshot:

```bash
aws ec2 delete-snapshot --region us-east-1 --snapshot-id snap-xxxxxxxxxxxxx
```

## Troubleshooting

### Error: "AWS was not able to validate the provided access credentials"

**Cause:** Instance profile not attached or credentials not yet available.

**Solution:**
1. Verify instance profile is attached (see Step 6)
2. Wait 30-60 seconds after attaching profile for credentials to propagate
3. Check instance metadata service is accessible:
   ```bash
   curl -s http://169.254.169.254/latest/meta-data/iam/info
   ```

### Error: "UnauthorizedOperation: You are not authorized to perform this operation"

**Cause:** IAM policy missing required permissions.

**Solution:**
1. Verify the policy is attached to the role:
   ```bash
   aws iam get-role-policy \
     --role-name RabbitMQ-EC2-Snapshot-Role \
     --policy-name EC2-Snapshot-Policy
   ```
2. Check the policy document includes all required actions
3. Ensure no deny policies are overriding the permissions

### Error: "An error occurred (IncorrectState) when calling the AssociateIamInstanceProfile operation"

**Cause:** Instance already has an instance profile attached.

**Solution:** Use `replace-iam-instance-profile-association` instead (see Case B in Step 5).

### Credentials Not Refreshing

**Cause:** Instance metadata service (IMDS) connectivity issues.

**Solution:**
1. Verify IMDSv2 is configured correctly:
   ```bash
   aws ec2 describe-instances \
     --instance-ids i-xxxxxxxxxxxxx \
     --query 'Reservations[0].Instances[0].MetadataOptions'
   ```
2. Ensure `HttpTokens` is set to `required` and `HttpEndpoint` is `enabled`
3. Check security groups allow outbound traffic to 169.254.169.254

### Testing Without Session Token Fails

**Cause:** Temporary credentials require session token.

**Explanation:** When using IAM roles on EC2, the AWS SDK retrieves temporary credentials that include:
- Access Key ID (starts with `ASIA`)
- Secret Access Key
- Session Token

All three values are required. The AWS SDK handles this automatically, but if you're manually setting environment variables, you must include `AWS_SESSION_TOKEN`.

## How the Plugin Uses These Permissions

The `rabbitmq_queue_migration` plugin performs the following operations during migration:

1. **Query Volumes**: Calls `ec2:DescribeVolumes` to find EBS volumes attached to the instance
2. **Create Snapshots**: Calls `ec2:CreateSnapshot` to create crash-consistent snapshots before migration
3. **Tag Snapshots**: Calls `ec2:CreateTags` to label snapshots with migration metadata
4. **Monitor Progress**: Calls `ec2:DescribeSnapshots` to check snapshot completion status

The plugin uses the AWS SDK's default credential provider chain, which automatically:
- Queries the EC2 instance metadata service at `http://169.254.169.254/latest/meta-data/iam/security-credentials/`
- Retrieves temporary credentials (access key, secret key, session token)
- Refreshes credentials automatically before expiration
- Handles all authentication transparently

No explicit credential configuration is needed in RabbitMQ or the plugin.

## Additional Considerations

### Multi-Region Deployments

If your RabbitMQ cluster spans multiple regions, ensure the IAM role has permissions in all relevant regions. The policy
shown above uses `"Resource": "*"` which applies globally, but you may want to add region-specific conditions.

### Snapshot Retention

By default, the plugin automatically deletes snapshots after successful migration
(`queue_migration.cleanup_snapshots_on_success = true`). This behavior can be disabled by setting the configuration option to
`false` if you want to retain snapshots for audit or rollback purposes. If cleanup is disabled, consider implementing a
lifecycle policy or cleanup script to manage snapshot retention and costs.

### Cost Implications

EBS snapshots incur storage costs. Monitor snapshot usage:

```bash
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Purpose,Values=RabbitMQ-Migration" \
  --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]' \
  --output table
```

## Summary

After completing these steps, your RabbitMQ EC2 instances will have the necessary IAM permissions to:
- Query attached EBS volumes
- Create snapshots during queue migration
- Tag and monitor snapshot progress

The `rabbitmq_aws` library used by this plugin will automatically retrieve temporary credentials from the instance metadata
service, including the required session token, without any explicit configuration.
