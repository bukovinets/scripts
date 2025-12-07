#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_ID="$1"
CONTEXT="[UPDATER] [$JOB_ID]"

if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    . "${SCRIPT_DIR}/common.sh"
else
    echo "CRITICAL: common.sh missing" && exit 1
fi

log_section "$CONTEXT" "Starting Job Update Process"

if [ -z "$JOB_ID" ]; then
    log_msg "ERROR" "$CONTEXT" "No Job ID provided."
    send_notification "Updater Missing ID" "ERROR" "$CONTEXT"
    exit 1
fi

# ==========================================
# PYTHON LOGIC: STRICT NODE MATCHING
# ==========================================
read -r -d '' PYTHON_LOGIC << EOM
import sys, json, subprocess

job_id = sys.argv[1]

def run_cmd(cmd):
    return subprocess.check_output(cmd, shell=True).decode('utf-8')

try:
    # 1. Get Job Config
    print(f"LOG|INFO|Fetching config for {job_id}...")
    raw_job = run_cmd(f"pvesh get /cluster/backup/{job_id} --output-format json")
    job_cfg = json.loads(raw_job)
    
    # Identify Backup Job's restricted node (if any)
    job_target_node = job_cfg.get('node') 
    current_vm_list_str = job_cfg.get('vmid', '')
    
    target_msg = f"Restricted to Node: {job_target_node}" if job_target_node else "Target: ALL NODES (Cluster-wide)"
    print(f"LOG|INFO|{target_msg}")
    print(f"LOG|INFO|Current Job VM List: [{current_vm_list_str}]")

    # 2. Load all resources (Cluster-wide)
    # We fetch ALL VMs to ensure we capture migrations (VMs that moved nodes)
    print(f"LOG|INFO|Fetching cluster-wide resource list...")
    raw_res = run_cmd("pvesh get /cluster/resources --type vm --output-format json")
    all_resources = json.loads(raw_res)

    # 3. Iterate through ALL VMs and Apply Filters
    final_vm_list = []
    
    for vm in all_resources:
        vmid = str(vm.get('vmid'))
        status = vm.get('status')
        current_node = vm.get('node')
        
        # Condition 1: Must be running
        if status != 'running':
            continue
            
        # Condition 2: Node matching
        # Include IF job has no restrictions OR VM is on the target node
        if (job_target_node is None) or (current_node == job_target_node):
            final_vm_list.append(vmid)
        # Else: VM is running but on a different node -> Exclude (Migration Handling)

    final_vm_list.sort()
    new_vm_list_str = ",".join(final_vm_list)

    print(f"LOG|INFO|Calculated Target VMs (Running & Node-Matched): [{new_vm_list_str}]")

    # 4. Compare with existing job definition
    curr_set = set(current_vm_list_str.split(',')) if current_vm_list_str else set()
    new_set = set(final_vm_list)

    if curr_set == new_set:
        print("NO_CHANGE")
    else:
        print(f"UPDATE|{new_vm_list_str}|{job_target_node if job_target_node else ''}")

except Exception as e:
    print(f"ERROR|{str(e)}")
    sys.exit(1)
EOM

# ==========================================
# EXECUTION
# ==========================================

output=$(python3 -c "$PYTHON_LOGIC" "$JOB_ID")
exit_code=$?

# Parse Output Stream
while read -r line; do
    if [[ "$line" == LOG* ]]; then
        IFS='|' read -r _ level msg <<< "$line"
        log_msg "$level" "$CONTEXT" "$msg"
    elif [[ "$line" == UPDATE* ]]; then
        status_line="$line"
    elif [[ "$line" == NO_CHANGE* ]]; then
        status_line="$line"
    elif [[ "$line" == ERROR* ]]; then
        status_line="$line"
    fi
done <<< "$output"

if [ $exit_code -ne 0 ]; then
    log_msg "ERROR" "$CONTEXT" "Python logic failed."
    send_notification "Updater Failed ($JOB_ID)" "ERROR" "$CONTEXT"
    exit 1
fi

# Decisions
if [[ "$status_line" == "NO_CHANGE" ]]; then
    log_msg "INFO" "$CONTEXT" "No changes needed."
    send_notification "Updater Success ($JOB_ID)" "SUCCESS" "$CONTEXT"

elif [[ "$status_line" == UPDATE* ]]; then
    IFS='|' read -r _ vmlist tnode <<< "$status_line"
    
    log_msg "INFO" "$CONTEXT" "Updating job $JOB_ID with new VM list..."
    
    # Construct pvesh command
    cmd="pvesh set /cluster/backup/$JOB_ID --all 0 --vmid $vmlist"
    if [ -n "$tnode" ]; then
        cmd="$cmd --node $tnode"
    fi
    
    update_out=$($cmd 2>&1)
    if [ $? -eq 0 ]; then
        log_msg "INFO" "$CONTEXT" "Job updated successfully."
        send_notification "Updater Updated Job ($JOB_ID)" "SUCCESS" "$CONTEXT"
    else
        log_msg "ERROR" "$CONTEXT" "pvesh failed: $update_out"
        send_notification "Updater API Fail ($JOB_ID)" "ERROR" "$CONTEXT"
    fi

elif [[ "$status_line" == ERROR* ]]; then
    err_msg="${status_line#ERROR|}"
    log_msg "ERROR" "$CONTEXT" "Script Error - $err_msg"
    send_notification "Updater Script Error ($JOB_ID)" "ERROR" "$CONTEXT"
fi