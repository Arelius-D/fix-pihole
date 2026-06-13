#!/bin/bash
set -u

# CONFIGURATION LOAD & DEFAULTS
SCRIPT_NAME="fix-pihole"
SCRIPT_TITLE="Pi-hole Upstream Watchdog Service"
CODE_VERSION="v3.0"
SCRIPT_DIR=${SCRIPT_DIR:-"$(dirname "$(realpath "$0")")"}
SCRIPT_FILE="$SCRIPT_DIR/$SCRIPT_NAME.sh"

# Dynamic Ownership Detection
SCRIPT_OWNER=$(stat -c '%U' "$SCRIPT_FILE")
SCRIPT_GROUP=$(stat -c '%G' "$SCRIPT_FILE")

CONFIG_FILE="$SCRIPT_DIR/$SCRIPT_NAME.cfg"

generate_default_config() {
    cat <<EOF > "$CONFIG_FILE"
# fix-pihole - Main Configuration
# WARNING: Do not remove the [Bracketed] headers! They are required.

[Search]
# The container name of Pi-hole.
TARGET_CONTAINER="pi-hole"

# The Docker Root directory (scanned recursively).
DOCKER_ROOT="/home/$SCRIPT_OWNER/Docker"

# The compose directory for Pi-hole.
COMPOSE_DIR="/home/$SCRIPT_OWNER/Docker/pi-hole"

# The connection error string to check in logs.
SEARCH_STRING="WARNING: Connection error"

# The network interface string to find and restart dependent stacks.
# Leave empty ("") if you do not use a macvlan or shared routing interface.
MACVLAN_STRING=""

[Connectivity]
# The external IP used for connection checking.
TEST_HOST="8.8.8.8"

# The external domain name used for resolution checking.
TEST_DOMAIN="google.com"

[Timings]
# Cooldown (in seconds) to wait for Pi-hole DNS to stabilize.
STABILIZE_COOLDOWN=5

# Cooldown (in seconds) to let network settle after recovery before unlocking.
RECOVERY_COOLDOWN=15

# Interval (in seconds) to poll if container is running or after log loop breaks.
CHECK_INTERVAL=5

# Window (in seconds) inside which back-to-back errors confirm a network drop.
CONFIRM_WINDOW_SEC=5

[Log Retention]
# Log retention for event logs (in hours).
LOG_RETENTION_EVENT_HOURS=168

# Log retention for info logs (in hours).
LOG_RETENTION_INFO_HOURS=24

[Service]
# Lock file path.
LOCK_FILE="/tmp/\$SCRIPT_NAME.lock"

# Log file path.
LOG_FILE="\$SCRIPT_DIR/\$SCRIPT_NAME.log"
EOF
    chown "$SCRIPT_OWNER:$SCRIPT_GROUP" "$CONFIG_FILE" 2>/dev/null || true
}

if [ ! -f "$CONFIG_FILE" ]; then
    generate_default_config
fi

if [ -f "$CONFIG_FILE" ]; then
    eval "$(grep -vE '^\s*\[' "$CONFIG_FILE")"
fi

REQUIRED_VARS=(
    TARGET_CONTAINER
    DOCKER_ROOT
    COMPOSE_DIR
    SEARCH_STRING
    TEST_HOST
    TEST_DOMAIN
    STABILIZE_COOLDOWN
    RECOVERY_COOLDOWN
    CHECK_INTERVAL
    CONFIRM_WINDOW_SEC
    LOG_RETENTION_EVENT_HOURS
    LOG_RETENTION_INFO_HOURS
    LOCK_FILE
    LOG_FILE
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ -z "${MACVLAN_STRING+set}" ]; then
    MISSING_VARS+=("MACVLAN_STRING")
fi

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo "[ERROR] Malformed or incomplete configuration file: $CONFIG_FILE" >&2
    echo "[ERROR] The following required variables are missing or empty:" >&2
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var" >&2
    done
    
    if [ -t 0 ]; then
        echo -n "Would you like to regenerate the configuration file now? [Y/n]: "
        read -r response
        case "$response" in
            [nN][oO]|[nN])
                echo "[INFO] Aborted, edit $CONFIG_FILE manually."
                exit 1
                ;;
            *)
                generate_default_config
                echo "[SUCCESS] Configuration file regenerated: $CONFIG_FILE"
                exit 0
                ;;
        esac
    else
        exit 1
    fi
fi

SERVICE_NAME="${SCRIPT_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

# LOGGING & UTILS
log() {
    local msg="$1"
    printf "%s\n" "$msg" >> "$LOG_FILE"
    sudo chown "$SCRIPT_OWNER:$SCRIPT_GROUP" "$LOG_FILE"
    if [ -t 1 ]; then
        printf "%s\n" "$msg"
    fi
}

cleanup_log() {
    if [ ! -f "$LOG_FILE" ]; then return; fi

    CUTOFF_168H=$(LC_ALL=C date -d "$LOG_RETENTION_EVENT_HOURS hours ago" +%s 2>/dev/null)
    CUTOFF_24H=$(LC_ALL=C date -d "$LOG_RETENTION_INFO_HOURS hours ago" +%s 2>/dev/null)
    
    TEMP_FILE=$(mktemp)

    LC_ALL=C awk -v cutoff_168h="$CUTOFF_168H" -v cutoff_24h="$CUTOFF_24H" '
    {
        timestamp = substr($0, 1, 19)
        cmd = "LC_ALL=C date -d \"" timestamp "\" +%s 2>/dev/null"
        cmd | getline timestamp_secs
        close(cmd)

        if (timestamp_secs ~ /^[0-9]+$/) {
            if (index($0, "[EVENT]") > 0 || index($0, "[WARN]") > 0 || index($0, "[FIX]") > 0 || index($0, "[SUCCESS]") > 0 || index($0, "[ERROR]") > 0) {
                if (timestamp_secs >= cutoff_168h) print $0
            } 
            else {
                if (timestamp_secs >= cutoff_24h) print $0
            }
        }
    }' "$LOG_FILE" > "$TEMP_FILE"

    if [ -s "$TEMP_FILE" ]; then
        mv "$TEMP_FILE" "$LOG_FILE"
        sudo chown "$SCRIPT_OWNER:$SCRIPT_GROUP" "$LOG_FILE"
    else
        rm "$TEMP_FILE"
    fi
}

usage() {
    echo "Usage: $SCRIPT_NAME $CODE_VERSION [OPTIONS]"
    echo "Options:"
    echo "  --watch    : Run in foreground (Used by Systemd Service)"
    echo "  --install  : Install and enable the Systemd Service"
    echo "  --purge    : Stop and remove the Systemd Service"
    echo "  --check    : Check service status"
    exit 1
}

# CORE LOGIC
confirm_outage() {
    log "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Threshold met. Running active connectivity check inside $TARGET_CONTAINER..."

    if docker exec "$TARGET_CONTAINER" ping -c 2 -W 2 "$TEST_HOST" >/dev/null 2>&1; then
        log "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Ping to $TEST_HOST SUCCEEDED — likely a transient log blip. Skipping fix."
        return 1
    fi

    if docker exec "$TARGET_CONTAINER" nslookup "$TEST_DOMAIN" "$TEST_HOST" >/dev/null 2>&1; then
        log "$(date '+%Y-%m-%d %H:%M:%S') [INFO] nslookup for $TEST_DOMAIN SUCCEEDED — network is fine. Skipping fix."
        return 1
    fi

    log "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Connection check failed inside $TARGET_CONTAINER. Outage confirmed."
    return 0
}

verify_and_fix() {
    if [ -f "$LOCK_FILE" ]; then return; fi
    touch "$LOCK_FILE"

    log "$(date '+%Y-%m-%d %H:%M:%S') [EVENT] Confirmed upstream connection failure in $TARGET_CONTAINER. Macvlan routing appears broken!"
    
    if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
        log "$(date '+%Y-%m-%d %H:%M:%S') [FIX] Rebuilding stack in: $COMPOSE_DIR"
        
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" rm -f 2>/dev/null
        
        if docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d >/dev/null 2>&1; then
            log "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $TARGET_CONTAINER network state restored."
            
            log "$(date '+%Y-%m-%d %H:%M:%S') [WAIT] Waiting ${STABILIZE_COOLDOWN}s for Pi-hole DNS to stabilize..."
            sleep "$STABILIZE_COOLDOWN"
            
            if [ -n "${MACVLAN_STRING:-}" ]; then
                DEPENDENT_FILES=$(grep -r -l "$MACVLAN_STRING" "$DOCKER_ROOT" | grep "\.yml$")
                
                if [ -n "$DEPENDENT_FILES" ]; then
                    for file in $DEPENDENT_FILES; do
                        if [ "$file" = "$COMPOSE_DIR/docker-compose.yml" ]; then
                            continue
                        fi
                        
                        STACK_NAME=$(basename "$(dirname "$file")")
                        log "$(date '+%Y-%m-%d %H:%M:%S') [FIX] Rebuilding dependent stack: $STACK_NAME ($file)"
                        
                        docker compose -f "$file" down 2>/dev/null
                        docker compose -f "$file" rm -f 2>/dev/null
                        
                        if docker compose -f "$file" up -d >/dev/null 2>&1; then
                            log "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $STACK_NAME restarted successfully."
                        else
                            log "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to restart $STACK_NAME."
                        fi
                    done
                fi
            fi
            
        else
            log "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to rebuild stack in $COMPOSE_DIR."
        fi
    else
        log "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Compose file not found at $COMPOSE_DIR."
    fi

    cleanup_log

    sleep "$RECOVERY_COOLDOWN"
    rm -f "$LOCK_FILE"
}

run_watchdog() {
    touch "$LOG_FILE"
    sudo chown "$SCRIPT_OWNER:$SCRIPT_GROUP" "$LOG_FILE"
    
    log "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Service Started. Owner: $SCRIPT_OWNER. Tailing $TARGET_CONTAINER logs for connection drops..."
    
    cleanup_log

    rm -f "$LOCK_FILE"
    trap 'rm -f $LOCK_FILE' EXIT

    while true; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$TARGET_CONTAINER" 2>/dev/null)" != "true" ]; then
            sleep "$CHECK_INTERVAL"
            continue
        fi

        docker logs --tail 0 -f "$TARGET_CONTAINER" 2>&1 | {
            last_warn_time=0

            while read -r line; do
                if [[ "$line" == *"$SEARCH_STRING"* ]]; then
                    now=$(LC_ALL=C date +%s)
                    
                    if [ "$last_warn_time" -eq 0 ]; then
                        last_warn_time=$now
                        log "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Warning detected. Watching for recurrence within ${CONFIRM_WINDOW_SEC}s to confirm network drop..."
                    else
                        diff=$((now - last_warn_time))
                        if [ "$diff" -le "$CONFIRM_WINDOW_SEC" ]; then
                            if confirm_outage; then
                                verify_and_fix
                            fi
                            last_warn_time=0
                        else
                            last_warn_time=$now
                            log "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Warning detected (previous was ${diff}s ago, outside ${CONFIRM_WINDOW_SEC}s window). Watching..."
                        fi
                    fi
                fi
            done
        }
        
        sleep "$CHECK_INTERVAL"
    done
}

# SERVICE MANAGEMENT
install_service() {
    echo "[INFO] Installing $SERVICE_NAME..."
    if [ "$EUID" -ne 0 ]; then echo "[ERROR] Run with sudo."; exit 1; fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=$SCRIPT_TITLE
After=docker.service network.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_FILE --watch
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    echo "[SUCCESS] Service installed and started."
}

purge_service() {
    echo "[INFO] Purging $SERVICE_NAME..."
    if [ "$EUID" -ne 0 ]; then echo "[ERROR] Run with sudo."; exit 1; fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "[SUCCESS] Service removed."
}

check_status() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl status "$SERVICE_NAME"
    else
        echo "[WARN] Service file not found."
    fi
}

# MAIN
if [ $# -eq 0 ]; then usage; fi

case "$1" in
    --watch) run_watchdog ;;
    --install) install_service ;;
    --purge) purge_service ;;
    --check) check_status ;;
    *) usage ;;
esac
