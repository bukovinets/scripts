#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/automation.log"
JOB_ID="$1" # Passed from Cron

# ==========================================
# MAIN LOGIC
# ==========================================

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UPDATER] [${JOB_ID}] $1" >> "$LOG_FILE"
}

# 1. Validation
if [ -z "$JOB_ID" ]; then
    echo "Error: No Job ID provided."
    exit 1
fi

log_msg "Starting dynamic update for Job: $JOB_ID"

# 2. Get Job Details (Find which Node it runs on)
# We fetch the specific job config
job_config=$(pvesh get "/cluster/backup/$JOB_ID" --output-format json)

# Extract the Node name. If "node" is missing/null, it means "All Nodes" (bad for this logic) or check fails.
target_node=$(echo "$job_config" | grep -oP '"node":\s*"\K[^"]+')

if [ -z "$target_node" ]; then
    log_msg "ERROR: Could not find an assigned node for this backup job. Is it set to 'All Nodes'? This script requires jobs assigned to specific nodes."
    exit 1
fi

log_msg "Identified target node: $target_node"

# 3. Get Running VMs on that specific node
# We use pvesh to query the specific node's QEMU list
# Filter: status == running
running_vms=$(pvesh get "/nodes/$target_node/qemu" --output-format json | grep -B 2 '"status": "running"' | grep -oP '"vmid":\s*"\K[^"]+' | tr '\n' ',' | sed 's/,$//')

# (Optional) If you use LXC containers, uncomment this to include them too:
# running_lxc=$(pvesh get "/nodes/$target_node/lxc" --output-format json | grep -B 2 '"status": "running"' | grep -oP '"vmid":\s*"\K[^"]+' | tr '\n' ',' | sed 's/,$//')
# if [ ! -z "$running_lxc" ]; then running_vms="${running_vms},${running_lxc}"; fi

if [ -z "$running_vms" ]; then
    log_msg "WARNING: No running VMs found on node $target_node. Clearing backup selection."
    # We set vmid to empty (or you could skip update to be safe, but empty is correct for 'skip stopped')
else
    log_msg "Found running VMs: $running_vms"
fi

# 4. Update the Backup Job
# We disable 'all' mode and set the specific vmid list
# Capture output to check for errors
output=$(pvesh set "/cluster/backup/$JOB_ID" --node "$target_node" --all 0 --vmid "$running_vms" 2>&1)

if [ $? -eq 0 ]; then
    log_msg "SUCCESS: Updated job definition."
else
    log_msg "ERROR: Failed to update job. Proxmox returned: $output"
fi