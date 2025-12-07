#!/bin/bash

JOB_ID="$1"
COMMON_LIB="/root/backup-mgmt/common.sh"

# Define Context for Logging BEFORE sourcing
LOG_CONTEXT="[UPDATER] [$JOB_ID]"

if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
else
    echo "ERROR: Could not find $COMMON_LIB"
    exit 1
fi

if [ -z "$JOB_ID" ]; then
    log "ERROR" "No Job ID provided."
    send_notification "error"
    exit 1
fi

log "INFO" "Starting update for Job ID: $JOB_ID"

# 1. Get Job Configuration (To check Node restrictions)
log "INFO" "Fetching Job Configuration..."
JOB_CONFIG=$(pvesh get "/cluster/backup/$JOB_ID" --output-format json)
if [ $? -ne 0 ]; then
    log "ERROR" "Could not fetch job config."
    send_notification "error" "$JOB_ID"
    exit 1
fi

TARGET_NODES=$(echo "$JOB_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('node', ''))")

if [ -n "$TARGET_NODES" ]; then
    log "INFO" "Job is restricted to nodes: [$TARGET_NODES]"
else
    log "INFO" "Job applies to ALL nodes."
fi

# 2. Get Running VMs (Filtered by Node)
log "INFO" "Fetching running VMs and applying node filters..."

RUNNING_VMS=$(pvesh get /cluster/resources --type vm --output-format json | python3 -c "
import sys, json
data = json.load(sys.stdin)
target_nodes_str = '$TARGET_NODES'
target_nodes = target_nodes_str.split(',') if target_nodes_str else []

running_vms = []
for vm in data:
    if vm.get('status') == 'running':
        if target_nodes:
            if vm.get('node') in target_nodes:
                running_vms.append(str(vm['vmid']))
        else:
            running_vms.append(str(vm['vmid']))

print(','.join(running_vms))
")

if [ $? -ne 0 ]; then
    log "ERROR" "Python parsing failed."
    send_notification "error" "$JOB_ID"
    exit 1
fi

log "INFO" "Calculated Target VMs: [$RUNNING_VMS]"

if [ -z "$RUNNING_VMS" ]; then
    log "WARN" "No matching running VMs found. Skipping update."
    send_notification "success" "$JOB_ID"
    exit 0
fi

# 3. Compare with Current Config
CURRENT_VMS=$(echo "$JOB_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('vmid', ''))")

log "INFO" "Current Job VMs: [$CURRENT_VMS]"

SORTED_NEW=$(echo "$RUNNING_VMS" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
SORTED_OLD=$(echo "$CURRENT_VMS" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')

if [ "$SORTED_NEW" == "$SORTED_OLD" ]; then
    log "INFO" "No changes needed."
    send_notification "success" "$JOB_ID"
    exit 0
fi

# 4. Update the Job
log "INFO" "Updating job $JOB_ID with VM list: $RUNNING_VMS"
pvesh set "/cluster/backup/$JOB_ID" --vmid "$RUNNING_VMS"

if [ $? -eq 0 ]; then
    log "INFO" "Job updated successfully."
    send_notification "success" "$JOB_ID"
else
    log "ERROR" "Failed to update backup job via pvesh."
    send_notification "error" "$JOB_ID"
    exit 1
fi