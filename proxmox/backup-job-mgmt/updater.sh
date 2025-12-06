#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/automation.log"
JOB_ID="$1"

# ==========================================
# FUNCTIONS
# ==========================================
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UPDATER] [${JOB_ID}] $1" >> "$LOG_FILE"
}

send_notification() {
    local msg="$1"
    if command -v proxmox-notify-client >/dev/null 2>&1; then
        echo "$msg" | proxmox-notify-client --severity error --type custom --subject "Backup Update Failed: $JOB_ID"
    else
        echo "$msg" | mail -s "Backup Update Failed: $JOB_ID" root
    fi
}

# ==========================================
# MAIN LOGIC
# ==========================================
if [ -z "$JOB_ID" ]; then
    echo "Error: No Job ID provided."
    exit 1
fi

log_msg "Starting dynamic update."

# 1. Fetch Job Config
job_json=$(pvesh get "/cluster/backup/$JOB_ID" --output-format json)

# 2. Extract Target Node using Python
target_node=$(echo "$job_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('node', ''))")

if [ -z "$target_node" ]; then
    log_msg "ERROR: Job has no specific node assigned (or parsing failed)."
    send_notification "Job $JOB_ID has no target node or could not be parsed."
    exit 1
fi

# 3. Fetch Running VMs on that Node
# Use pvesh + python to get clean comma-separated list of running VMIDs
running_vms=$(pvesh get "/nodes/$target_node/qemu" --output-format json | python3 -c "import sys, json; print(','.join([x['vmid'] for x in json.load(sys.stdin) if x.get('status') == 'running']))")

log_msg "Node: $target_node | Running VMs: [${running_vms}]"

# 4. Apply Update
# Even if list is empty (no running VMs), we update the job to empty list so nothing gets backed up.
output=$(pvesh set "/cluster/backup/$JOB_ID" --node "$target_node" --all 0 --vmid "$running_vms" 2>&1)
exit_code=$?

if [ $exit_code -eq 0 ]; then
    log_msg "SUCCESS: Job definition updated."
else
    log_msg "ERROR: Proxmox API failed: $output"
    send_notification "Failed to update backup job. Error: $output"
    exit 1
fi