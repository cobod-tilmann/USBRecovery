#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RECOVERY.sh
# Main wrapper executed by the USB recovery mechanism.
# Calls module scripts and appends structured logs.
# ============================================================

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

MODULE_DIR="$BASE_DIR/modules"

LOG_DIR="$BASE_DIR/output"

LOG_FILE="$LOG_DIR/recovery_wrapper.log"

mkdir -p "$LOG_DIR"

# timestamp helper in iso format
ts() {
    
    date -Is; 
}

{
echo ""
echo "============================================================"
echo "RECOVERY RUN START : $(ts)"
echo "============================================================"
} >> "$LOG_FILE"


# ------------------------------------------------------------
# run_step <name> <script_path> <required:true|false>
#
# Executes one recovery module and logs:
#   - step start + timestamp
#   - module output
#   - step end + exit code
#
# If required=true and the module fails, recovery stops.
# Optional steps log failure but allow continuation.
# ------------------------------------------------------------
run_step () {

    local name="$1"           # Human-readable step name
    local script="$MODULE_DIR/$2"         # Full path to module script
    local required="${3:-true}"  # Default: required
    local script_tag="$(basename "$script")" # prefix for logger

    # Log step start marker
    {
    echo ""
    echo "------------------------------------------------------------"
    echo "STEP START : $name"
    echo "Timestamp  : $(ts)"
    echo "Script     : $script"
    echo "------------------------------------------------------------"
    } >> "$LOG_FILE"

    # Ensure the module script exists before execution
    if [[ ! -f "$script" ]]; then
        echo "ERROR: Script not found: $script" >> "$LOG_FILE"
        [[ "$required" == "true" ]] && exit 1
        return 0
    fi

    # Execute module via bash (Windows/FAT-safe) and prefix each output line
    # with module filename + timestamp before appending to wrapper log.
    set +e
    /bin/bash "$script" 2>&1 | while IFS= read -r line; do
        printf '[%s] %s %s\n' "$script_tag" "$(ts)": "$line"
    done >> "$LOG_FILE"
    RC=${PIPESTATUS[0]}
    set -e

    # Log step completion and exit code
    {
    echo "------------------------------------------------------------"
    echo "STEP END   : $name"
    echo "Timestamp  : $(ts)"
    echo "Exit Code  : $RC"
    echo "------------------------------------------------------------"
    } >> "$LOG_FILE"

    # Abort recovery if required step failed
    [[ "$RC" -ne 0 && "$required" == "true" ]] && exit "$RC"

    return 0
}


# Recovery execution order

# 1. configure static IP
run_step "Configure eth0 static IP" "netconfig_eth0_static.sh" true

# 2. collect general system info
run_step "Write system status report" "systemstatus.sh" false

# 3. set up new wifi connection
# run_step "add wifi connection" "netconfig_wlan0_new.sh" true

# 4. dump interface info
run_step "display interface info" "list_interfaces.sh" false




{
echo ""
echo "============================================================"
echo "RECOVERY RUN END   : $(ts)"
echo "============================================================"
echo ""
} >> "$LOG_FILE"

exit 0
