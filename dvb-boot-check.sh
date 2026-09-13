#!/usr/bin/env bash
# dvb-boot-check.sh — boot-time self-check for the dvb-node on this Pi.
#
# Runs once shortly after every boot via dvb-boot-check.timer (before the
# 5-min first tick of dvb-restart.timer, so problems are caught and healed
# before the nightly-restart logic sees the node).
#
#  1. KERNEL/DRIVERS  - confirm the custom em28xx/m88ds3103 drivers are
#     installed for THIS running kernel (/lib/modules/$(uname -r)/updates).
#     If not (e.g. the kernel was upgraded since the last run.sh build), run
#     /home/daniel/WinTV-NOVA-S2-linux/run.sh to build/install them.
#  2. FIRMWARE/USB     - warn if the M88DS3103C firmware file is missing;
#     confirm the PCTV 461 (2013:0462) is on the USB bus and /dev/dvb nodes
#     exist (modprobe em28xx if the nodes have not appeared).
#  3. dvb-node         - start it if it is not running; restart it if it is
#     unhealthy (dvb-node has no other start-at-boot mechanism).
#  4. TUNE TEST        - tune a known Astra 28.2E transponder and require a
#     frontend lock, then always release the tuner back to IDLE.
#  5. OUTCOME          - on total failure, mark the tuner FIRMWARE_FAILED via
#     the dvb-node API so the tv-server dashboard shows the real state.
#
# This script NEVER reboots the Pi. It stamps the /var/lib/dvb-restart
# cool-down so the nightly-reboot logic cannot loop; a fresh "boot-checked"
# stamp also makes dvb-restart.sh defer its own reboot escalation.
#
# Run: /usr/local/sbin/dvb-boot-check.sh   (as root via the systemd unit)

set -u

ENV_FILE=/dvb/dvb-node/.env
API_PORT="${DVB_API_PORT:-8000}"
CURL_TIMEOUT=30
STAMP_DIR=/var/lib/dvb-restart
BOOT_CHECKED_STAMP="$STAMP_DIR/boot-checked"
BUILD_STAMP_DIR=/var/lock
BUILD_STAMP="$BUILD_STAMP_DIR/dvb-boot-check-build"
BUILD_STAMP_TTL=3600
RUNSH_USER=daniel
RUNSH=/home/daniel/WinTV-NOVA-S2-linux/run.sh

# api_post runs in a command-substitution subshell, so its HTTP code cannot be
# a shell variable; persist it to a file (set -u would make an unset read fatal).
TMP_DIR="$(mktemp -d /tmp/dvb-boot-check.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
CODE_FILE="$TMP_DIR/http_code"
printf '000' >"$CODE_FILE"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') dvb-boot-check: $*"; }

api_key() {
    [ -r "$ENV_FILE" ] || return 1
    sed -n 's/^API_WRITE_TOKEN=//p' "$ENV_FILE" | head -1
}

node_state() {
    local key body
    key="$(api_key)" || { echo "NO_TOKEN"; return; }
    body="$(curl -s -m 6 -H "X-API-Key: $key" \
        "http://127.0.0.1:${API_PORT}/api/v1/status" 2>/dev/null)" || { echo "UNREACHABLE"; return; }
    printf '%s' "$body" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin); print(d.get("state") or "UNKNOWN")
except Exception:
    print("GARBAGE")'
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
    su "$RUNSH_USER" -s /bin/bash -c \
        'cd /dvb/dvb-node && nohup ./.venv/bin/python -m dvbnode.main >> /tmp/dvbnode.log 2>&1 &'
    sleep 6
    return 0
}

api_post() {
    # api_post <path> <json-body>  -> echoes body, writes HTTP code to CODE_FILE
    local key body code
    key="$(api_key)" || { printf '0' >"$CODE_FILE"; echo "NO_TOKEN"; return 1; }
    body="$(curl -s -m "$CURL_TIMEOUT" -o - -w '\n%{http_code}' -X POST \
        -H "X-API-Key: $key" -H "Content-Type: application/json" \
        -d "$2" "http://127.0.0.1:${API_PORT}/api/v1$1" 2>/dev/null)"
    code="${body##*$'\n'}"
    [ -n "$code" ] || code=000
    printf '%s' "$code" >"$CODE_FILE"
    printf '%s' "${body%$'\n'*}"
}

mark_firmware_failed() {
    local code
    api_post /tuner/firmware-failed "{\"reason\":\"$1\"}" >/dev/null
    code="$(cat "$CODE_FILE" 2>/dev/null)"
    log "tuner marked FIRMWARE_FAILED (reason: $1; http=${code})"
}

tune_test() {
    # tune_test <mux-json>  -> 0 on lock, 1 otherwise. Releases the tuner.
    local resp result code
    log "tune test: $1"
    resp="$(api_post /tuner/tune "$1")" || true
    code="$(cat "$CODE_FILE" 2>/dev/null)"
    if [ "$code" = "409" ]; then
        log "tune test skipped (tuner busy/conflict)"
        return 0
    fi
    result="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("result"))
except Exception:
    print(None)')"
    api_post /tuner/reset '{}' >/dev/null
    case "$result" in
        locked|already_locked)
            printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); s=(d.get("stats") or {}); print(" signal=%s%% snr=%s" % (s.get("signal_percent"), s.get("snr_db")))
except Exception:
    print("")' | sed 's/^/tune test: locked/'
            return 0
            ;;
        error)
            log "tune test FAILED: $(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("error") or "unknown")
except Exception:
    print("unparseable response")' 2>/dev/null)"
            return 1
            ;;
        *)
            log "tune test FAILED: unexpected result '${result:-<empty>}' (http=$code)"
            return 1
            ;;
    esac
}

MODULES_BUILT() {
    [ -f "/lib/modules/$1/updates/usb/em28xx/em28xx.ko" ] &&
    [ -f "/lib/modules/$1/updates/dvb-frontends/m88ds3103.ko" ]
}

build_stamp_fresh() {
    [ -f "$BUILD_STAMP" ] || return 1
    local ts now
    ts="$(cat "$BUILD_STAMP" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    [ $(( now - ts )) -lt "$BUILD_STAMP_TTL" ]
}

PASS=1
FAIL=0
FAILURES=""

KERNEL="$(uname -r)"
log "boot self-check start kernel=${KERNEL}"

# ---------------------------------------------------------------------------
# 1. Custom drivers for the RUNNING kernel (rebuild via run.sh when missing)
# ---------------------------------------------------------------------------
if MODULES_BUILT "$KERNEL"; then
    log "OK custom drivers present for ${KERNEL}"
else
    log "MISSING custom drivers for ${KERNEL}"
    if build_stamp_fresh; then
        log "build appears to already be in progress (stamp ${BUILD_STAMP}); deferring to that build"
    else
        log "running ${RUNSH} as ${RUNSH_USER} (this can take several minutes)..."
        mkdir -p "$BUILD_STAMP_DIR"
        date +%s > "$BUILD_STAMP"
        su "$RUNSH_USER" -s /bin/bash -c "$RUNSH" 2>&1 | while IFS= read -r line; do
            log "run.sh: ${line}"
        done
        rc=$?
        rm -f "$BUILD_STAMP"
        if [ "$rc" -ne 0 ]; then
            FAIL=1
            FAILURES="${FAILURES}; run.sh build failed (rc=${rc})"
            log "FAIL run.sh rebuild failed rc=${rc}"
            tail -n 40 /home/daniel/pctv461-media-build.log 2>/dev/null | while IFS= read -r line; do
                log "build.log: ${line}"
            done
        else
            if MODULES_BUILT "$KERNEL"; then
                log "OK custom drivers present for ${KERNEL} after build"
            else
                FAIL=1
                FAILURES="${FAILURES}; drivers still missing for ${KERNEL} after build"
                log "FAIL drivers still missing for ${KERNEL} even after a successful build"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Firmware, USB presence, /dev/dvb device nodes
# ---------------------------------------------------------------------------
if [ ! -f /lib/firmware/dvb-demod-m88ds3103c.fw ]; then
    log "WARN M88DS3103C firmware file /lib/firmware/dvb-demod-m88ds3103c.fw is missing (cannot auto-fix)"
fi
if command -v lsusb >/dev/null 2>&1 && ! lsusb -d 2013:0462 >/dev/null 2>&1; then
    FAIL=1
    FAILURES="${FAILURES}; PCTV 461 (2013:0462) not visible via lsusb"
    log "FAIL PCTV 461 (2013:0462) not visible via lsusb"
fi
if [ ! -e /dev/dvb/adapter0/frontend0 ]; then
    log "device nodes missing; try modprobe em28xx + udevadm settle"
    modprobe em28xx 2>/dev/null || true
    sleep 2
    udevadm settle 2>/dev/null || true
fi
if [ ! -e /dev/dvb/adapter0/frontend0 ]; then
    FAIL=1
    FAILURES="${FAILURES}; /dev/dvb/adapter0/frontend0 still absent"
    log "FAIL /dev/dvb/adapter0/frontend0 still absent after modprobe"
fi

# ---------------------------------------------------------------------------
# 3. dvb-node process running and healthy (restart when not)
# ---------------------------------------------------------------------------
if [ -z "$(dvb_pid)" ]; then
    log "dvb-node not running; starting it"
    restart_dvbnode || { FAIL=1; FAILURES="${FAILURES}; dvb-node could not be started"; }
    sleep 6
fi
state="$(node_state)"
case "$state" in
    IDLE|LOCKED|STREAMING|TUNING|SCANNING|RECOVERING)
        log "dvb-node up (state=${state})"
        ;;
    FIRMWARE_FAILED|ERROR|UNREACHABLE|GARBAGE|NO_TOKEN)
        log "dvb-node unhealthy (state=${state}); restarting it"
        if restart_dvbnode; then
            sleep 6
            state="$(node_state)"
            log "dvb-node after restart (state=${state})"
        else
            FAIL=1
            FAILURES="${FAILURES}; dvb-node restart failed"
        fi
        ;;
    *)
        log "dvb-node state unknown (${state}); leaving for dvb-restart"
        ;;
esac

# ---------------------------------------------------------------------------
# 4. Real tune test on Astra 28.2E (only when the tuner is IDLE)
# ---------------------------------------------------------------------------
if [ "$state" != "IDLE" ]; then
    log "tune test skipped (state=${state}); tuner must be IDLE"
elif [ "$FAIL" -ne 0 ] && ! MODULES_BUILT "$KERNEL"; then
    # Drivers are gone and could not be restored; a tune test cannot succeed.
    log "skipping tune test (custom drivers unavailable for ${KERNEL})"
elif [ ! -e /dev/dvb/adapter0/frontend0 ]; then
    log "skipping tune test (no /dev/dvb device)"
else
    if tune_test '{"controller":"bootcheck","frequency":12129.0,"polarization":"V","symbol_rate":27500,"fec":"2/3","modulation":"8PSK","delivery_system":"DVB-S2"}'; then
        log "PASS tune lock on 12129 V"
    elif tune_test '{"controller":"bootcheck","frequency":10906.0,"polarization":"V","symbol_rate":22000,"fec":"5/6","modulation":"QPSK","delivery_system":"DVB-S"}'; then
        log "PASS tune lock on 10906 V (fallback)"
    else
        FAIL=1
        FAILURES="${FAILURES}; tune test failed on 12129 V and 10906 V"
        log "FAIL tune test failed on both test transponders"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Outcome: surface FIRMWARE_FAILED to the dashboard on total failure
# ---------------------------------------------------------------------------
mkdir -p "$STAMP_DIR"
date +%s > "$BOOT_CHECKED_STAMP"
# Suppress the dvb-restart nightly-reboot cool-down for 6h: this boot already
# consumed a recovery attempt (builds/tune tests may still be unstable).
date +%s > "$STAMP_DIR/last-reboot"

if [ "$FAIL" -eq 0 ]; then
    log "RESULT PASS (kernel=${KERNEL})"
    state="$(node_state)"
    if [ "$state" = "FIRMWARE_FAILED" ]; then
        log "clearing stale FIRMWARE_FAILED back to IDLE"
        api_post /tuner/reset '{}' >/dev/null 2>&1 || true
    fi
else
    reason="$(printf '%s' "boot-check FAIL kernel=${KERNEL}${FAILURES}" | tr -d '"' | head -c 380)"
    log "RESULT FAIL (kernel=${KERNEL})${FAILURES}"
    mark_firmware_failed "$reason"
fi

log "boot self-check done"
exit 0