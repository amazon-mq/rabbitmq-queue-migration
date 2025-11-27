#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# vim:ft=sh:
# -*- mode: sh; -*-

# restore_snapshot_test.sh
# Restore a RabbitMQ snapshot archive for testing migration recovery

set -o errexit
set -o nounset
set -o pipefail

# Default values
declare data_dir="/tmp/rabbitmq-test-instances"
declare snapshot_file=""
declare -i force=0

show_usage() {
    cat << EOF
Usage: $0 --snapshot-file <path> [--data-dir <path>] [--force]

Restore a RabbitMQ snapshot archive for testing migration recovery.
This script assumes RabbitMQ is already stopped and will not start it.

Options:
  --snapshot-file <path>  Path to the snapshot tar.gz file (required)
  --data-dir <path>       RabbitMQ data directory (default: /tmp/rabbitmq-test-instances)
  --force                 Skip confirmation prompt
  -h, --help             Show this help message

Example:
  $0 --snapshot-file /tmp/rabbitmq_migration_snapshots/rabbit@node1-vhost1-1234567890.tar.gz

Testing workflow:
  1. Stop RabbitMQ manually
  2. Run this script to restore snapshot
  3. Start RabbitMQ manually to test restored state
EOF
}

log_info() {
    echo "[$(date '+%H:%M:%S')] $1" >&2
}

log_error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $1" >&2
}

# Parse arguments
while (( $# > 0 ))
do
    case $1 in
        --snapshot-file)
            if (( $# < 2 ))
            then
                log_error "--snapshot-file requires a value"
                exit 1
            fi
            snapshot_file="$2"
            shift 2
            ;;
        --data-dir)
            if (( $# < 2 ))
            then
                log_error "--data-dir requires a value"
                exit 1
            fi
            data_dir="$2"
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$snapshot_file" ]]
then
    log_error "--snapshot-file is required"
    echo "Use --help for usage information" >&2
    exit 1
fi

# Check if snapshot file exists
if [[ ! -f "$snapshot_file" ]]
then
    log_error "Snapshot file does not exist: $snapshot_file"
    exit 1
fi

# Check if data directory exists
if [[ ! -d "$data_dir" ]]
then
    log_error "Data directory does not exist: $data_dir"
    exit 1
fi

log_info "Snapshot restoration test"
log_info "========================="
log_info "Snapshot file: $snapshot_file"
log_info "Data directory: $data_dir"
echo "" >&2

# Confirmation prompt (unless --force is used)
if (( force == 0 ))
then
    echo "WARNING: This will completely wipe the data directory: $data_dir" >&2
    echo "Make sure RabbitMQ is stopped before proceeding." >&2
    echo "" >&2
    read -p "Are you sure you want to continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]
    then
        echo "Operation cancelled." >&2
        exit 0
    fi
fi

# Wipe data directory
log_info "Wiping data directory..."
rm -rf "${data_dir:?}"/*

# Create data directory if it doesn't exist
mkdir -p "$data_dir"

# Extract snapshot
log_info "Extracting snapshot archive..."
if tar -xzf "$snapshot_file" -C "$data_dir"
then
    log_info "Snapshot restoration complete!"
    log_info "You can now start RabbitMQ to test the restored state."
else
    log_error "Failed to extract snapshot archive"
    exit 1
fi
