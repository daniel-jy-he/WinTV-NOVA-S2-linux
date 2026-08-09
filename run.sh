#!/usr/bin/env bash
#
# run.sh (v4) — Build/install updated em28xx + m88ds3103 DVB drivers for the
#               PCTV 461 (2013:0462) on Raspberry Pi OS / Debian 13 (trixie)
#
# BACKGROUND:
#
#   The required support - "m88ds3103: Implement 3103c chip support" and
#   "em28xx: Add Hauppauge 461e v3" (submitted by Bradford Love, 2026-03-17) -
#   has landed in the Linux MAINLINE development tree, but as of the time
#   this script was written it is NOT in any tagged/released kernel (not
#   6.18, not 7.0, nothing). That means no distro switch fixes this - every
#   distro's released kernel is equally missing it. The old LinuxTV
#   `media_build` / `media_tree` toolchain (used by earlier versions of
#   this script) is explicitly unsupported upstream and is not used here.
#
#   This script pulls ONLY the needed driver source directories straight
#   from the mainline linux git tree via a sparse partial clone, and
#   builds them as standalone out-of-tree kernel modules against your
#   CURRENTLY RUNNING kernel. Your installed kernel is never touched or
#   replaced.
#
#   Every cross-tree dependency discovered while getting this working
#   (missing generic headers, quoted includes of sibling driver headers,
#   a relocated struct causing a redefinition conflict) is now baked in
#   as a default - see FIXES.md for the full list. A genuinely NEW
#   missing-header error can be self-serviced by adding a line to
#   ~/em28xx-extra-paths.txt (created on first run) and re-running.
#
#   REPRODUCIBILITY: after a successful build, this script records the
#   exact mainline commit it used to ~/em28xx-known-good-commit.txt and
#   pins future runs to that commit instead of re-tracking a possibly-
#   changed master. Back up that file - restoring it on a clean install
#   reproduces this exact working build.
#
# Run this ON THE RASPBERRY PI ITSELF, as a normal user with sudo access
# (it calls sudo itself where needed). Re-running is safe/idempotent.
#
# Usage:
#   chmod +x run.sh
#   ./run.sh
#
set -euo pipefail

SRC_DIR="${HOME}/linux-src"
LOG_FILE="${HOME}/pctv461-media-build.log"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
die()  { printf '\n\033[1;31m[fail]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; exit 1; }

# ---------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    die "Do not run this script as root. Run as a normal user with sudo access."
fi
command -v sudo >/dev/null 2>&1 || die "sudo is required but not found."

RUNNING_KERNEL="$(uname -r)"
log "Detected running kernel: ${RUNNING_KERNEL}"

log "USB device check (expect PCTV 461 / 2013:0462):"
if command -v lsusb >/dev/null 2>&1; then
    lsusb -d 2013:0462 | tee -a "$LOG_FILE" || warn "Device 2013:0462 not currently visible via lsusb. Plug it in before continuing."
fi

# ---------------------------------------------------------------------
# 1. Install build dependencies
# ---------------------------------------------------------------------
log "Installing build dependencies..."
sudo apt update
sudo apt install -y \
    git \
    build-essential \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    pkg-config \
    raspberrypi-kernel-headers 2>/dev/null || true

KDIR="/lib/modules/${RUNNING_KERNEL}/build"
if [ ! -d "$KDIR" ]; then
    die "Kernel headers not found at ${KDIR}. Install matching headers for ${RUNNING_KERNEL} and re-run."
fi
if [ ! -e "${KDIR}/.config" ] && [ ! -e "${KDIR}/Module.symvers" ]; then
    warn "${KDIR} has neither .config nor Module.symvers — module build may fail with unresolved symbols."
fi
log "Using kernel headers at: ${KDIR}"

# ---------------------------------------------------------------------
# 2. Sparse partial clone of mainline linux — ONLY the two driver dirs
#    that contain the merged 461e v3 / M88DS3103C support
# ---------------------------------------------------------------------
# NOTE: this path list has grown as build errors revealed more cross-tree
# dependencies (e.g. em28xx.h now pulling in a newer generic USB device-id
# header). It's safe/idempotent to re-run sparse-checkout set with the
# current full list every time, even against an already-cloned repo.
DEFAULT_SPARSE_PATHS="drivers/media/usb/em28xx drivers/media/dvb-frontends drivers/media/tuners include/linux/device-id"

# ---------------------------------------------------------------------
# Self-service extra paths: if a build fails with something like
#     fatal error: some/header.h: No such file or directory
# add the DIRECTORY containing that header (not the file itself) as its
# own line in this file, then just re-run ./run.sh — no script edits
# needed. Directories are fetched from https://github.com/torvalds/linux
# and automatically added to the compiler's include search path.
# ---------------------------------------------------------------------
EXTRA_PATHS_FILE="${HOME}/em28xx-extra-paths.txt"
if [ ! -f "$EXTRA_PATHS_FILE" ]; then
    cat > "$EXTRA_PATHS_FILE" <<'EXTRA_EOF'
# One path per line, relative to the root of https://github.com/torvalds/linux
# Use the DIRECTORY containing the missing file, not the file itself.
#
# Example: if a build error says
#     fatal error: linux/usb/quirks.h: No such file or directory
# add the line:
#     include/linux/usb
#
# Lines starting with # are ignored. After editing, just re-run ./run.sh —
# it re-fetches with the new path(s) included and retries automatically.
#
# NOTE: this only helps with "No such file or directory" errors. If you
# instead hit a "redefinition of ..." error (a type/struct defined in two
# places), that needs a different fix — send me that log rather than
# adding a path here.
EXTRA_EOF
    log "Created ${EXTRA_PATHS_FILE} — add paths there yourself if future builds hit more missing headers, then just re-run ./run.sh."
fi
EXTRA_PATHS=$(grep -v '^\s*#' "$EXTRA_PATHS_FILE" 2>/dev/null | grep -v '^\s*$' || true)
if [ -n "$EXTRA_PATHS" ]; then
    log "Extra paths from ${EXTRA_PATHS_FILE}:"
    echo "$EXTRA_PATHS" | tee -a "$LOG_FILE"
fi
SPARSE_PATHS="$DEFAULT_SPARSE_PATHS $EXTRA_PATHS"

# ---------------------------------------------------------------------
# Reproducibility: track mainline master by default, but once a build
# has succeeded, pin future runs to that EXACT commit instead of
# re-tracking master (which is a moving target and can reintroduce new,
# unrelated breakage as mainline keeps changing these files). This file
# is what makes a clean-install re-run reliable — keep a copy of it if
# you reinstall.
# ---------------------------------------------------------------------
KNOWN_GOOD_COMMIT_FILE="${HOME}/em28xx-known-good-commit.txt"
PIN_REF="master"
if [ -s "$KNOWN_GOOD_COMMIT_FILE" ]; then
    PIN_REF="$(head -n1 "$KNOWN_GOOD_COMMIT_FILE" | tr -d '[:space:]')"
    log "Using previously-recorded known-good mainline commit: ${PIN_REF}"
else
    warn "No known-good commit recorded yet — tracking mainline master (a moving target)."
fi

log "Fetching ${SPARSE_PATHS} from mainline linux @ ${PIN_REF}..."
if [ ! -d "$SRC_DIR/.git" ]; then
    mkdir -p "$SRC_DIR"
    ( cd "$SRC_DIR" \
      && git init -q \
      && git remote add origin https://github.com/torvalds/linux.git \
      && git sparse-checkout init --cone ) \
        || die "Failed to initialize source tree."
fi
(
    cd "$SRC_DIR"
    git sparse-checkout set $SPARSE_PATHS \
        && git fetch --filter=blob:none --depth 1 origin "$PIN_REF" \
        && git checkout -q --detach FETCH_HEAD
) || die "Fetch/checkout of ${PIN_REF} failed."

# Build the include-path flags used by later `make` invocations: always
# include $SRC_DIR/include (covers anything under include/), plus one
# -I per fetched directory that ISN'T under include/ (those are found via
# quoted #include "foo.h" which searches -I paths).
BUILD_INCLUDE_FLAGS="-I${SRC_DIR}/include"
for p in drivers/media/tuners drivers/media/dvb-frontends $EXTRA_PATHS; do
    case "$p" in
        include/*) : ;;  # already covered by -I$SRC_DIR/include
        *) BUILD_INCLUDE_FLAGS="$BUILD_INCLUDE_FLAGS -I${SRC_DIR}/${p}" ;;
    esac
done
log "Using include flags: ${BUILD_INCLUDE_FLAGS}"

# Headers under include/linux/device-id/ may redefine structs that your
# OLDER installed headers already define elsewhere (mainline relocated
# them after your kernel branched off; layouts are unchanged). Strip any
# such duplicate struct definitions from our fetched copies — this keeps
# working automatically even as more device-id/*.h files get pulled in
# via extra-paths.txt.
if [ -d "${SRC_DIR}/include/linux/device-id" ]; then
    for hdr in "${SRC_DIR}"/include/linux/device-id/*.h; do
        [ -f "$hdr" ] || continue
        if grep -qE '^struct [a-z_]+_id \{' "$hdr"; then
            log "Stripping duplicate struct definition(s) from $(basename "$hdr")..."
            awk '/^struct [a-z_]+_id \{/{skip=1} skip && /^\};/{skip=0; next} !skip{print}' \
                "$hdr" > "${hdr}.tmp" && mv "${hdr}.tmp" "$hdr"
        fi
    done
fi

EM28XX_DIR="${SRC_DIR}/drivers/media/usb/em28xx"
DVBFE_DIR="${SRC_DIR}/drivers/media/dvb-frontends"
[ -d "$EM28XX_DIR" ] || die "em28xx source directory missing after checkout."
[ -d "$DVBFE_DIR" ] || die "dvb-frontends source directory missing after checkout."

log "Confirming the fetched source actually contains the 461e v3 / M88DS3103C support..."
HAVE_461E_V3=0
HAVE_3103C=0
grep -qi '461e v3\|EM28178_BOARD_PCTV_461E_V3' "$EM28XX_DIR"/em28xx*.c "$EM28XX_DIR"/em28xx*.h 2>/dev/null && HAVE_461E_V3=1
grep -qi 'm88ds3103c\|is_3103c\|chiptype.*3103c' "$DVBFE_DIR"/m88ds3103*.c "$DVBFE_DIR"/m88ds3103*.h 2>/dev/null && HAVE_3103C=1

[ "$HAVE_461E_V3" -eq 1 ] && log "Confirmed: 461e v3 board support present." \
    || die "461e v3 board support NOT found in fetched source — mainline may have changed. Stopping rather than building something useless."
[ "$HAVE_3103C" -eq 1 ] && log "Confirmed: M88DS3103C demodulator support present." \
    || die "M88DS3103C support NOT found in fetched source — mainline may have changed. Stopping rather than building something useless."

# ---------------------------------------------------------------------
# 3. Build both directories as standalone out-of-tree modules against
#    the RUNNING kernel (no kernel rebuild, no media_build harness)
# ---------------------------------------------------------------------
#
# IMPORTANT: we do NOT build the whole dvb-frontends/ directory. Its
# Makefile builds every frontend driver enabled in the running kernel's
# .config (Debian/RPi kernels enable nearly all of them), and several of
# those (au8522, af9013, etc.) need headers from drivers/media/tuners/,
# which we deliberately never fetched. We only need m88ds3103, ts2020,
# and a8293, so we copy just those files into an isolated staging dir
# with our own minimal Makefile.
log "Staging only m88ds3103 + ts2020 + a8293 (avoids unrelated frontends and their missing tuner headers)..."
STAGE_DVBFE="${HOME}/dvb-frontends-stage"
rm -rf "$STAGE_DVBFE"
mkdir -p "$STAGE_DVBFE"
cp "$DVBFE_DIR"/m88ds3103*.[ch] "$STAGE_DVBFE"/ 2>/dev/null
cp "$DVBFE_DIR"/ts2020*.[ch]    "$STAGE_DVBFE"/ 2>/dev/null
cp "$DVBFE_DIR"/a8293*.[ch]     "$STAGE_DVBFE"/ 2>/dev/null

ls "$STAGE_DVBFE"/m88ds3103*.c >/dev/null 2>&1 || die "m88ds3103 source missing from fetched tree."
ls "$STAGE_DVBFE"/ts2020*.c    >/dev/null 2>&1 || die "ts2020 source missing from fetched tree."
ls "$STAGE_DVBFE"/a8293*.c     >/dev/null 2>&1 || die "a8293 source missing from fetched tree."

cat > "$STAGE_DVBFE/Makefile" <<'MAKEFILE_EOF'
obj-m += m88ds3103.o
obj-m += ts2020.o
obj-m += a8293.o
MAKEFILE_EOF

log "Building m88ds3103 + ts2020 + a8293 against ${RUNNING_KERNEL}..."
make -C "$KDIR" M="$STAGE_DVBFE" modules \
    KCPPFLAGS="${BUILD_INCLUDE_FLAGS}" 2>&1 | tee -a "$LOG_FILE" \
    || die "dvb-frontends (staged) build failed — see ${LOG_FILE}."
DVBFE_DIR="$STAGE_DVBFE"   # downstream steps read .ko files from here now

log "Building em28xx (core + dvb extension) against ${RUNNING_KERNEL}..."
# em28xx.h / em28xx-dvb.c reference several headers outside their own
# directory (newer generic kernel headers, and quoted includes of various
# DVB frontend/tuner headers for the many boards em28xx supports). All
# fetched directories are on the include path via BUILD_INCLUDE_FLAGS.
make -C "$KDIR" M="$EM28XX_DIR" modules \
    KCPPFLAGS="${BUILD_INCLUDE_FLAGS}" 2>&1 | tee -a "$LOG_FILE" \
    || die "em28xx build failed — see ${LOG_FILE}. If the error is 'fatal error: <path>: No such file or directory', add that file's DIRECTORY as a line in ${EXTRA_PATHS_FILE} and re-run ./run.sh — no need to ask me. If it's a 'redefinition of ...' error instead, send me the log."

# ---------------------------------------------------------------------
# 4. Install into the "updates" tree (takes precedence over the
#    in-box modules on depmod resolution) and reload
# ---------------------------------------------------------------------
UPDATES_DVBFE="/lib/modules/${RUNNING_KERNEL}/updates/dvb-frontends"
UPDATES_EM28XX="/lib/modules/${RUNNING_KERNEL}/updates/usb/em28xx"

log "Installing built modules into ${UPDATES_DVBFE} and ${UPDATES_EM28XX}..."
sudo mkdir -p "$UPDATES_DVBFE" "$UPDATES_EM28XX"

DVBFE_KOS=$(find "$DVBFE_DIR" -maxdepth 1 -name '*.ko')
EM28XX_KOS=$(find "$EM28XX_DIR" -maxdepth 1 -name '*.ko')

[ -n "$DVBFE_KOS" ] || die "No .ko files produced in ${DVBFE_DIR} — build likely produced nothing (check CONFIG_DVB_M88DS3103 etc. were enabled)."
[ -n "$EM28XX_KOS" ] || die "No .ko files produced in ${EM28XX_DIR} — build likely produced nothing (check CONFIG_VIDEO_EM28XX etc. were enabled)."

sudo cp -v $DVBFE_KOS "$UPDATES_DVBFE"/ | tee -a "$LOG_FILE"
sudo cp -v $EM28XX_KOS "$UPDATES_EM28XX"/ | tee -a "$LOG_FILE"

log "Running depmod -a..."
sudo depmod -a

log "Unloading any currently-loaded em28xx/dvb modules (ignore 'not loaded' errors)..."
sudo modprobe -r em28xx_dvb em28xx_alsa em28xx_rc em28xx m88ds3103 ts2020 a8293 2>/dev/null || true

log "Loading em28xx (should pull in the new m88ds3103/ts2020/a8293/em28xx_dvb via depmod)..."
sudo modprobe em28xx || die "modprobe em28xx failed — check dmesg for symbol/version errors. See rollback note below."

CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$(cat "$KNOWN_GOOD_COMMIT_FILE" 2>/dev/null)" != "$CURRENT_COMMIT" ]; then
    echo "$CURRENT_COMMIT" > "$KNOWN_GOOD_COMMIT_FILE"
    log "Recorded known-good mainline commit ${CURRENT_COMMIT} to ${KNOWN_GOOD_COMMIT_FILE}."
    log "Keep a copy of this file if you ever reinstall — it makes future builds reproduce this exact working result instead of re-fetching a possibly-changed master."
fi

# ---------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------
log "Loaded modules:"
lsmod | grep -E 'em28xx|m88ds3103|ts2020|a8293' | tee -a "$LOG_FILE" \
    || warn "None of em28xx/m88ds3103/ts2020/a8293 currently loaded."

log "DVB device nodes:"
if [ -d /dev/dvb ]; then
    ls -l /dev/dvb/adapter0/ 2>/dev/null | tee -a "$LOG_FILE" \
        || warn "/dev/dvb exists but adapter0 not present yet."
else
    warn "/dev/dvb does not exist yet."
fi

log "Relevant recent kernel log lines:"
dmesg | grep -Ei 'em28xx|PCTV|0462|461e|m88ds3103|ts2020|ts2022|a8293|firmware|dvb' | tail -n 60 | tee -a "$LOG_FILE"

log "Firmware file check:"
ls -l /lib/firmware/dvb-demod-m88ds3103c.fw 2>/dev/null | tee -a "$LOG_FILE" \
    || warn "dvb-demod-m88ds3103c.fw not found in /lib/firmware."

echo
log "Done. Success criteria:"
echo "  - dmesg shows: em28xx ...: Identified as PCTV DVB-S2 Stick (461e v3)"
echo "  - dmesg shows: DVB: registering adapter 0 frontend 0 (Montage Technology M88DS3103C)"
echo "  - /dev/dvb/adapter0/frontend0 exists"
echo
echo "If modprobe failed with 'Invalid module format' or similar, the new .ko"
echo "vermagic didn't match your running kernel exactly. Roll back with:"
echo "  sudo rm -rf ${UPDATES_DVBFE} ${UPDATES_EM28XX}"
echo "  sudo depmod -a && sudo modprobe -r em28xx m88ds3103 && sudo modprobe em28xx"
echo
echo "Full log saved to: ${LOG_FILE}"
echo "Known-good mainline commit pinned at: ${KNOWN_GOOD_COMMIT_FILE}"
echo "  (back this file up — copying it to a fresh Pi and re-running ./run.sh"
echo "   reproduces this exact working build, unaffected by future mainline changes)"
