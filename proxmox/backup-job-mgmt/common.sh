#!/bin/bash

# ==========================================
# COMMON CONFIGURATION
# ==========================================
# How many minutes BEFORE the backup schedule should we update the job?
PADDING_MINUTES=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/automation.log"
PVE_NOTIFY_CFG="/etc/pve/notifications.cfg"
PVE_PRIV_CFG="/etc/pve/priv/notifications.cfg"

# Create a temporary log file for THIS specific run (for email body)
RUN_LOG=$(mktemp)
chmod 600 "$RUN_LOG"

# Ensure temp log is removed on script exit
trap 'rm -f "$RUN_LOG"' EXIT

# ==========================================
# LOGGING FUNCTIONS
# ==========================================
log_msg() {
    local level="$1"   # INFO, ERROR, WARNING
    local context="$2" # [MANAGER], [UPDATER] [ID]
    local msg="$3"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local formatted_msg="${timestamp} ${context} [${level}] ${msg}"
    
    # Write to persistent log
    echo "$formatted_msg" >> "$LOG_FILE"
    
    # Write to current run log (for email)
    echo "$formatted_msg" >> "$RUN_LOG"
    
    # Echo to console ONLY if running interactively (Manual Run), NOT via Cron
    if [ -t 1 ]; then
        echo "$formatted_msg"
    fi
}

log_section() {
    echo "---------------------------------------------------" >> "$LOG_FILE"
    echo "---------------------------------------------------" >> "$RUN_LOG"
    log_msg "INFO" "$1" "$2"
}

# ==========================================
# EMAIL NOTIFICATION (Python SMTP)
# ==========================================
send_notification() {
    local subject="$1"
    local severity="$2" # "SUCCESS" or "ERROR"
    local context_tag="$3"
    
    local body_content=$(cat "$RUN_LOG")

    # Capture output into variable to prevent it from leaking to Cron email
    local output
    output=$(python3 -c "
import sys, re, smtplib, ssl, subprocess, json, socket
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

subject = sys.argv[1]
severity = sys.argv[2]
body_log = sys.argv[3]
public_cfg_path = '$PVE_NOTIFY_CFG'
priv_cfg_path = '$PVE_PRIV_CFG'
hostname = socket.gethostname()

def get_user_email(userid):
    try:
        cmd = ['pvesh', 'get', f'/access/users/{userid}', '--output-format', 'json']
        out = subprocess.check_output(cmd).decode('utf-8')
        data = json.loads(out)
        return data.get('email')
    except:
        return None

def parse_config(path):
    configs = {}
    current_section = None
    try:
        with open(path, 'r') as f:
            for line in f:
                line_raw = line.rstrip()
                if not line_raw or line_raw.startswith('#'): continue
                m_header = re.match(r'^(\w+):\s+(\S+)', line_raw)
                if m_header:
                    current_section = m_header.group(2)
                    configs[current_section] = {'_type': m_header.group(1)}
                    continue
                if current_section and (line_raw.startswith(' ') or line_raw.startswith('\t')):
                    parts = line_raw.strip().split(maxsplit=1)
                    if len(parts) == 2:
                        configs[current_section][parts[0]] = parts[1]
    except FileNotFoundError:
        pass
    return configs

def send_mail():
    public_conf = parse_config(public_cfg_path)
    priv_conf = parse_config(priv_cfg_path)

    smtp_conf = {}
    found = False
    for name, conf in public_conf.items():
        if conf.get('_type') == 'smtp':
            smtp_conf = conf
            if name in priv_conf and 'password' in priv_conf[name]:
                smtp_conf['password'] = priv_conf[name].get('password')
            found = True
            break
    
    if not found:
        print('LOG|No SMTP configuration found.')
        sys.exit(0) 

    from_addr = smtp_conf.get('from-address', 'root@proxmox')
    to_addr = smtp_conf.get('username')

    if 'mailto-user' in smtp_conf:
        for user in smtp_conf['mailto-user'].split(','):
            email = get_user_email(user.strip())
            if email:
                to_addr = email
                break
    
    if not to_addr:
        print('LOG|No recipient email found.')
        sys.exit(1)

    msg = MIMEMultipart()
    msg['From'] = from_addr
    msg['To'] = to_addr
    msg['Subject'] = f'[{severity}] Backup Automation: {subject} ({hostname})'
    msg.attach(MIMEText(f'Execution Report for {hostname}:\n\nSeverity: {severity}\n\nTrace Log:\n{body_log}', 'plain'))

    server_host = smtp_conf.get('server')
    port = int(smtp_conf.get('port', 465))
    mode = smtp_conf.get('mode', 'tls')
    username = smtp_conf.get('username')
    password = smtp_conf.get('password')

    try:
        context = ssl.create_default_context()
        if port == 465:
            with smtplib.SMTP_SSL(server_host, port, context=context) as server:
                if username and password: server.login(username, password)
                server.send_message(msg)
        else:
            with smtplib.SMTP(server_host, port) as server:
                if mode == 'starttls': server.starttls(context=context)
                if username and password: server.login(username, password)
                server.send_message(msg)
        print('SUCCESS')
    except Exception as e:
        print(f'FAIL|{e}')
        sys.exit(1)

send_mail()
" "$subject" "$severity" "$body_content" 2>&1)

    # Check the captured output to log internal status
    if [[ "$output" == "SUCCESS" ]]; then
        log_msg "INFO" "$context_tag" "Email notification sent successfully."
    elif [[ "$output" == FAIL* ]]; then
        log_msg "WARNING" "$context_tag" "Failed to send email: ${output#FAIL|}"
    fi
}