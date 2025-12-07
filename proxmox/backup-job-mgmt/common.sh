#!/bin/bash

# --- GLOBAL CONFIGURATION ---
LOG_FILE="/root/backup-mgmt/automation.log"
EMAIL_RECIPIENT="andrew.chv@gmail.com"
# ----------------------------

# Initialize variable to hold logs for the email body
RUN_LOG=""

# Shared Logging Function
# Expects LOG_CONTEXT to be set by the calling script
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local formatted_msg="$timestamp $LOG_CONTEXT [$level] $message"
    
    # Write to file
    echo "$formatted_msg" >> "$LOG_FILE"
    
    # Store for email
    RUN_LOG+="$formatted_msg"$'\n'
    
    # Output to console
    echo "$formatted_msg"
}

# Shared Email Notification Function
# Reads credentials directly from Proxmox config
send_notification() {
    local status="$1"
    local job_id_ref="$2" # Optional: Pass JOB_ID if available
    local subject=""
    
    # Determine Subject
    if [ "$status" == "success" ]; then
        if [ -n "$job_id_ref" ]; then
            subject="SUCCESS: Backup Automation ($job_id_ref)"
        else
            subject="SUCCESS: Backup Manager Run Completed"
        fi
    else
        if [ -n "$job_id_ref" ]; then
            subject="ERROR: Backup Automation Failed ($job_id_ref)"
        else
            subject="ERROR: Backup Manager Run Failed"
        fi
    fi

    log "INFO" "Reading Proxmox notification config and sending email..."

    # Python script to parse Proxmox config and send SMTP
    python3 -c "
import smtplib
import ssl
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

# --- CONFIG PARSING ---
def get_smtp_config():
    config = {'server': '', 'port': 587, 'user': '', 'from': '', 'password': ''}
    target_name = None

    try:
        # 1. Read Public Config
        with open('/etc/pve/notifications.cfg', 'r') as f:
            lines = f.readlines()
        
        in_smtp_block = False
        for line in lines:
            line = line.strip()
            if not line: continue
            if line.startswith('smtp:'):
                in_smtp_block = True
                target_name = line.split(':')[1].strip()
                continue
            elif line.startswith(('sendmail:', 'matcher:')):
                in_smtp_block = False
                continue

            if in_smtp_block:
                parts = line.split(maxsplit=1)
                if len(parts) == 2:
                    key, val = parts
                    if key == 'server': config['server'] = val
                    if key == 'username': config['user'] = val
                    if key == 'from-address': config['from'] = val

        # 2. Read Private Config
        if target_name:
            with open('/etc/pve/priv/notifications.cfg', 'r') as f:
                lines = f.readlines()
            
            in_smtp_block = False
            for line in lines:
                line = line.strip()
                if not line: continue
                if line.startswith(f'smtp: {target_name}'):
                    in_smtp_block = True
                    continue
                elif line.startswith(('sendmail:', 'matcher:')) or (line.startswith('smtp:') and target_name not in line):
                    in_smtp_block = False
                    continue

                if in_smtp_block and line.startswith('password'):
                    parts = line.split(maxsplit=1)
                    if len(parts) == 2:
                        config['password'] = parts[1]
    except Exception as e:
        print(f'Error reading config: {e}')
        exit(1)
            
    return config

# --- EXECUTION ---
cfg = get_smtp_config()

if not cfg['server'] or not cfg['password']:
    print('Error: Could not find valid SMTP configuration in Proxmox files.')
    exit(1)

sender_email = cfg['from'] if cfg['from'] else cfg['user']
receiver_email = '$EMAIL_RECIPIENT'
subject = '$subject'
body = '''$RUN_LOG'''

message = MIMEMultipart()
message['From'] = sender_email
message['To'] = receiver_email
message['Subject'] = subject
message.attach(MIMEText(body, 'plain'))

try:
    context = ssl.create_default_context()
    with smtplib.SMTP(cfg['server'], int(cfg['port'])) as server:
        server.starttls(context=context)
        server.login(cfg['user'], cfg['password'])
        server.sendmail(sender_email, receiver_email, message.as_string())
    print('Email sent successfully.')
except Exception as e:
    print(f'Error sending email: {e}')
    exit(1)
"
    if [ $? -eq 0 ]; then
        log "INFO" "SMTP delivery successful."
    else
        log "ERROR" "SMTP delivery failed."
    fi
}