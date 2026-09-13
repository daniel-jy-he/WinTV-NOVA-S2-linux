#!/usr/bin/env bash
# dvb-restart.sh — health check + nightly restart for the dvb-node on this Pi.
#
# Runs every ~10 minutes via dvb-restart.timer.
#
#  1. ROUTINE  once/day in the quiet window (default 00:00-03:00, configurable
#     via RESTART_WINDOW_START/END): reboot the Pi when the tuner is IDLE and no
#     stream is active, giving the flaky USB DVB hardware a clean bus/driver
#     reset every 24 h.
#  2. REACTIVE always: if the dvb-node is unreachable/wedged (status hangs or
#     returns garbage), try a graceful dvb-node process restart first and
#     escalate to a full Pi reboot if that does not recover it.
#
# A recent-reboot stamp prevents reboot loops. A "stream or scan active" tuner
# (STREAMING/TUNING/SCANNING/RECOVERING) always defers the restart.

set -u

ENV_FILE=/dvb/dvb-node/.env
API_PORT="${DVB_API_PORT:-8000}"
CURL_TIMEOUT=6
WINDOW_START="${RESTART_WINDOW_START:-0}"   # reboot window start hour (00-23)
WINDOW_END="${RESTART_WINDOW_END:-3}"       # reboot window end hour (exclusive)
STAMP_DIR=/var/lib/dvb-restart
STAMP_FILE="$STAMP_DIR/last-reboot"
REBOOT_COOLDOWN=21600                       # never reboot more than once per 6 h

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') dvb-restart: $*"; }

api_key() {
    [ -r "$ENV_FILE" ] || return 1
    sed -n 's/^API_READ_TOKEN=//p' "$ENV_FILE" | head -1
}

node_state() {
    local key body
    key="$(api_key)" || { echo "NO_TOKEN"; return; }
    body="$(curl -s -m "$CURL_TIMEOUT" -H "X-API-Key: $key" \
        "http://127.0.0.1:${API_PORT}/api/v1/status" 2>/dev/null)" || { echo "UNREACHABLE"; return; }
    printf '%s' "$body" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin); print(d.get("state") or "UNKNOWN")
except Exception:
    print("GARBAGE")'
}

in_window() {
    local h
    h="$(date +%-H)"
    [ "$h" -ge "$WINDOW_START" ] && [ "$h" -lt "$WINDOW_END" ]
}

recently_rebooted() {
    [ -f "$STAMP_FILE" ] || return 1
    local last now
    last="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    [ $(( now - last )) -lt "$REBOOT_COOLDOWN" ]
}

boot_check_recent() {
    # Let dvb-boot-check.sh own recovery in the first 30 min after a boot
    # (it may be mid-build or still probing the tuner). Defer reboots then.
    [ -f "$STAMP_DIR/boot-checked" ] || return 1
    local last now
    last="$(cat "$STAMP_DIR/boot-checked" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    [ $(( now - last )) -lt 1800 ]
}

stamp_reboot() {
    mkdir -p "$STAMP_DIR"
    date +%s > "$STAMP_FILE"
}

dvb_pid() { pgrep -f 'dvbnode\.main$' | head -1; }

restart_dvbnode() {
    local pid
    pid="$(dvb_pid)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        for _ in 1 2 3 4 5; do
            [ -z "$(dvb_pid)" ] && break
            sleep 2
        done
        if [ -n "$(dvb_pid)" ]; then
            kill -9 "$pid" 2>/dev/null
            sleep 2
        fi
    fi
    if [ -n "$(dvb_pid)" ]; then
        log "dvb-node process stuck in kernel (D-state); cannot terminate"
        return 1
    fi
    su daniel -s /bin/bash -c \
        'cd /dvb/dvb-node && nohup ./.venv/bin/python -m dvbnode.main >> /tmp/dvbnode.log 2>&1 &'
    sleep 6
    return 0
}

reboot_pi() {
    if boot_check_recent; then
        log "deferring reboot: dvb-boot-check ran recently (recovery in progress)"
        return 1
    fi
    log "rebooting Pi"
    stamp_reboot
    systemctl reboot 2>/dev/null || /sbin/reboot 2>/dev/null || reboot
}

node_state="$(node_state)"
if [ "$node_state" = "NO_TOKEN" ]; then
    log "cannot read API token from $ENV_FILE; skipping"
    exit 0
fi
log "node state: ${node_state:-<empty>}"

case "$node_state" in
    IDLE)
        if in_window && ! recently_rebooted; then
            log "IDLE and inside reboot window ${WINDOW_START}-${WINDOW_END}; rebooting Pi"
            reboot_pi
        else
            log "IDLE; nothing to do (window=${WINDOW_START}-${WINDOW_END}, rebooted_recently=$(recently_rebooted && echo yes || echo no))"
        fi
        ;;
    STREAMING|TUNING|SCANNING|RECOVERING)
        log "deferring: tuner is $node_state (stream or scan active)"
        ;;
    *)
        # Unreachable / garbage / unknown. Re-check once before escalating to
        # avoid acting on a transient blip.
        log "unhealthy (state='${node_state:-}'); re-checking in 5s"
        sleep 5
        node_state="$(node_state)"
        if [ "$node_state" = "NO_TOKEN" ]; then
            exit 0
        fi
        case "$node_state" in
            IDLE|STREAMING|TUNING|SCANNING|RECOVERING)
                log "transient; recovered on re-check (state=$node_state)"
                ;;
            *)
                log "confirmed unhealthy (state='${node_state:-}'); escalating"
                if restart_dvbnode; then
                    node_state="$(node_state)"
                    case "$node_state" in
                        IDLE|STREAMING|TUNING|SCANNING|RECOVERING)
                            log "recovered via dvb-node restart (state=$node_state)"
                            ;;
                        *)
                            log "still unhealthy after restart (state='${node_state:-}'); rebooting Pi"
                            reboot_pi
                            ;;
                    esac
                else
                    log "dvb-node restart failed; rebooting Pi"
                    reboot_pi
                fi
                ;;
        esac
        ;;
esac