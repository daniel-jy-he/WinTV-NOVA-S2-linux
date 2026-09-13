# Hauppauge WinTV-NOVA-S2 PCTV 461 (2013:0462) DVB-S2 on Raspberry Pi 5 — Problem, Investigation, and Fix

This documentation is for owners of the `WinTV-NOVA-S2` USB Tuner made by Hauppauge and are struggling to install on Linux.

TLDR: The more recent versions use a require a driver which not present in the Linux build. There is a script called `run.sh` which will load the required drivers from the main Github Linux repository.

If you're more interested, the steps below are used to identify the core issue. Look at step 3: `dmesg` and `lsusb` command outputs and `ls -l /dev/dvb/` throwing 'not found' are clear indicators that you have the problem.

Note: these instructions worked for my Raspberry Pi 5 running Debian 6.18.39.

## 0. The issue

2. Confirm That USB Detects the Tuner

Run:

`lsusb`

For the PCTV 461, look for:

`ID 2013:0462 PCTV Systems PCTV 461`

The critical identifiers are:

```
Vendor: 2013
Product: 0462
```

If the device does not appear in lsusb, this is a different class of problem.

At this stage Linux has only detected the USB device. It does not prove that the DVB subsystem has successfully initialised it.

3. Check the Kernel Log Immediately After Plugging It In

Unplug the tuner, wait a moment, plug it back in, then run:

`dmesg | tail -100`

A correctly recognised PCTV 461/461e v3 should contain lines similar to:

```
usb 1-1.4: New USB device found, idVendor=2013, idProduct=0462, bcdDevice=1.00
usb 1-1.4: Product: PCTV 461
usb 1-1.4: Manufacturer: PCTV
em28xx 1-1.4:1.0: New device PCTV PCTV 461 @ 480 Mbps (2013:0462, interface 0, class 0)
em28xx 1-1.4:1.0: DVB interface 0 found: bulk
em28xx 1-1.4:1.0: chip ID is em28178
```

These lines establish that:

USB sees the tuner.
The em28xx driver has attached.
The device's DVB interface has been detected.
The hardware is being identified as an em28178-based device.

Continue looking through the log for the device identification:

`em28xx 1-1.4:1.0: Identified as PCTV DVB-S2 Stick (461e v3) (card=112)`

If these lines appear, the USB and basic em28xx driver detection are working.

4. The Critical Test: Does /dev/dvb/ Exist?

Run:

`ls -l /dev/dvb/`

On a correctly initialised tuner, you should see something similar to:

`adapter0`

Then:

`ls -l /dev/dvb/adapter0/`

Normally this will contain devices such as:

```
demux0
dvr0
frontend0
net0
```

The most important device is:

`/dev/dvb/adapter0/frontend0`

This represents the actual DVB frontend.

Affected state

The key symptom in the affected setup was:

`ls: cannot access '/dev/dvb/': No such file or directory`

or otherwise no /dev/dvb directory at all.

This is significant when it occurs despite the kernel log showing that the PCTV device and em28xx driver were detected.

In other words:

```
USB detected
        ↓
em28xx attached
        ↓
PCTV 461 identified
        ↓
DVB device missing
```

That combination is the important diagnostic signature.

5. Check Whether DVB Kernel Modules Are Loaded

Run:

`lsmod | grep -E 'dvb|em28xx|m88ds3103|ts2020|a8293'`

A functioning setup will normally have relevant modules loaded after the device is initialised.

If this returns nothing relevant while the USB device is present, that is useful diagnostic information.

However, do not treat an empty lsmod result alone as proof of the problem. Modules can be loaded automatically when the device is accessed or through other mechanisms.

The kernel log and existence of /dev/dvb/ are more important.

6. Check the em28xx USB Driver Support

The PCTV 461 uses the `em28xx` driver.

Check the loaded aliases:

`modinfo em28xx | grep -i alias`

For the PCTV 461 USB ID, the relevant alias is:

`alias: usb:v2013p0462d*dc*dsc*dp*ic*isc*ip*in*`

This confirms that the installed em28xx driver knows about USB device:

2013:0462``

If this alias is absent, the kernel's installed em28xx driver may not contain support for the device.

7. Check the M88DS3103 Driver

The PCTV 461/461e v3 uses the Montage Technology M88DS3103 family of DVB-S/S2 demodulators.

Check:

`modinfo m88ds3103`

A relevant module should exist, for example:

filename: /lib/modules/<kernel>/kernel/drivers/media/dvb-frontends/m88ds3103.ko.xz
description: Montage Technology M88DS3103 DVB-S/S2 demodulator driver

The module should also advertise firmware files such as:

```
firmware: dvb-demod-m88ds3103b.fw
firmware: dvb-demod-m88rs6000.fw
firmware: dvb-demod-m88ds3103.fw
```

This confirms that the kernel has the M88DS3103 frontend driver installed.

8. Check for the Required Firmware

Search the firmware directory:

`ls -lh /lib/firmware/ | grep m88ds3103`

For the particular tuner tested here, the important firmware file was:

`lib/firmware/dvb-demod-m88ds3103c.fw`

Check it directly:

`ls -lh /lib/firmware/dvb-demod-m88ds3103c.fw`

Example:

`-rw-r--r-- 1 root root 16K Jan 30 2025 /lib/firmware/dvb-demod-m88ds3103c.fw`

A missing firmware file is an important diagnostic finding.

However, the presence of firmware alone does not prove that the DVB frontend is successfully initialising.

9. Look for the DVB Initialisation Sequence in dmesg

For a correctly initialised PCTV 461, the kernel log should progress beyond basic USB detection.

A healthy sequence looks approximately like:

```
em28xx: Identified as PCTV DVB-S2 Stick (461e v3) (card=112)
em28xx: dvb set to bulk mode.
em28xx: Binding DVB extension
ts2020: Montage Technology TS2022 successfully identified
a8293: Allegro A8293 SEC successfully attached
dvbdev: DVB: registering new adapter
em28xx: DVB: registering adapter 0 frontend 0 (Montage Technology M88DS3103C)
em28xx: DVB extension successfully initialized
```

The crucial line is:

`DVB: registering adapter 0 frontend 0`

After this, /dev/dvb/adapter0/frontend0 should exist.

10. Distinguish Driver Detection From DVB Initialisation

This is the most important diagnostic point.

Seeing:

`Identified as PCTV DVB-S2 Stick (461e v3) (card=112)`

does not necessarily mean the tuner is ready for DVB use.

You need to see the later stages:

`Binding DVB extension`

followed by successful attachment of the tuner/demodulator components and:

```
DVB: registering new adapter
DVB: registering adapter 0 frontend 0
```

If the device is identified by em28xx but /dev/dvb/ never appears, investigate the later DVB initialisation stage rather than assuming the USB hardware is defective.

## 1. The problem

Hardware: **PCTV Systems PCTV 461** DVB-S/S2 USB tuner, USB ID `2013:0462`, on a
**Raspberry Pi 5** running **Debian 13 (trixie)**, kernel `6.18.39+rpt-rpi-v8`.

The device is detected fine at the USB level (`lsusb -d 2013:0462` shows it), but no
`/dev/dvb/adapter0` ever appears. Two separate pieces of driver support were missing
from the installed kernel:

1. **`em28xx`** (the USB bridge driver) had no board definition for this specific
   variant of the tuner — it only knew about the older `461e` and `461e v2` boards,
   not `461e v3`, which is what `2013:0462` identifies as.
2. **`m88ds3103`** (the DVB-S/S2 demodulator driver) had no support for the
   **M88DS3103C** chip revision used in this hardware — only the older `M88DS3103`
   and `M88DS3103B`.

Firmware (`dvb-demod-m88ds3103c.fw`) was already installed and not the issue.

## 2. Why a distro reinstall or different kernel does *not* fix this

This was the first thing worth ruling out, and it's tempting to reach for when a build
keeps failing. It doesn't help here, for a specific reason: the two required patches
(`em28xx: Add Hauppauge 461e v3` and `m88ds3103: Implement 3103c chip support`,
submitted upstream by Bradford Love on 2026-03-17) had, at the time of this work,
**landed in the Linux mainline development tree but not in any tagged/released
kernel** — not 6.18, not even the newer 7.0 tag. Every distro's shipped kernel was
equally missing this support. Reinstalling Ubuntu, Fedora, or anything else would
have produced the exact same gap.

## 3. Why the standard LinuxTV `media_build` tool didn't work

The traditional way to get newer DVB drivers on an older kernel is LinuxTV's
`media_build` out-of-tree build harness. Two attempts with it both failed:

- `git.linuxtv.org/media_tree.git` cloned as an **empty repository** — that
  infrastructure is effectively unsupported/inactive now (confirmed via a GitHub
  issue on the project).
- Even after routing around that, it needed `lsdiff` (from `patchutils`, not
  installed) and its "sync source" step (`build.sh`) turned out to be a no-op in an
  earlier version of the automation, masking the real problem.

Given `media_build`/`media_tree` is explicitly no longer maintained, continuing to
fight it wasn't worth it. The approach was abandoned entirely.

## 4. The approach that worked

Since the fix already exists in mainline Linux (just not in any release), the
solution is to:

1. Pull **only the specific driver source directories** that contain the fix —
   `drivers/media/usb/em28xx` and `drivers/media/dvb-frontends` — from
   `github.com/torvalds/linux`, using a **sparse, partial (`--filter=blob:none`)
   clone** so this doesn't require downloading the entire multi-gigabyte kernel
   history.
2. Build them as **standalone out-of-tree kernel modules** directly against the
   Pi's *currently running* kernel (`/lib/modules/$(uname -r)/build`), via the
   normal `make -C $KDIR M=<dir> modules` mechanism.
3. Install the resulting `.ko` files into `/lib/modules/$(uname -r)/updates/`,
   which takes precedence over the in-box modules once `depmod -a` runs.
4. `modprobe` the new modules in.

At no point is the installed kernel itself rebuilt, replaced, or touched — this is
purely adding/replacing a handful of driver modules.

## 5. Build errors hit along the way, and the fix for each

Building recent mainline driver source against a somewhat older, distro-patched
kernel surfaces a series of small cross-tree dependency mismatches. Each one below
is now handled automatically by `run.sh` — this table exists so the reasoning is
recorded, not because you need to redo any of it:

| Error | Cause | Fix baked into `run.sh` |
|---|---|---|
| `dvb-frontends` build tries to compile `au8522`, `af9013`, etc. and fails on missing headers | The full `dvb-frontends/` directory's Makefile builds *every* frontend the kernel's `.config` has enabled (Debian enables nearly all of them), not just the one needed | Only `m88ds3103*`, `ts2020*`, `a8293*` are copied into an isolated staging directory with a hand-written `Makefile` that lists just those three as build targets |
| `fatal error: linux/device-id/usb.h: No such file or directory` | `em28xx.h` references a newer **generic kernel core header** that didn't exist yet when `6.18.39` branched off mainline | That header's directory (`include/linux/device-id`) is fetched too, and its location is added to the compiler's include path via `KCPPFLAGS` |
| `error: redefinition of 'struct usb_device_id'` | The newer `device-id/usb.h` redefines a struct that the **older, installed** kernel headers already define in `mod_devicetable.h` (mainline relocated it; the layout itself is unchanged) | The script automatically strips duplicate `struct *_id { ... }` definitions out of any fetched `include/linux/device-id/*.h` file before building |
| `fatal error: xc2028.h: No such file or directory` | `em28xx.h` quote-includes a tuner header that lives in `drivers/media/tuners/`, a directory not originally fetched | `drivers/media/tuners` is fetched and added to the include path |
| `fatal error: lgdt330x.h: No such file or directory` | `em28xx-dvb.c` quote-includes various DVB frontend headers (for the many boards `em28xx` supports) that live in `drivers/media/dvb-frontends/`, which was fetched but not on the include path | `drivers/media/dvb-frontends` (the full fetched copy, not the 3-file staging copy) is added to the include path |

All of the above are now unconditional defaults in `run.sh` — a clean install
running the current script should reproduce this working result without hitting any
of these specific errors again.

## 6. Will this keep working on a clean install, going forward?

**Mostly yes, with one caveat.** `run.sh` fetches from mainline Linux's `master`
branch, which is a moving target — if those driver files change again upstream
before you next run this, a clean install could in principle hit a *new*,
previously-unseen missing-header error, the same class of issue as section 5.

To make this reliably reproducible, `run.sh` now:

- **Records the exact commit** it used on a successful build to
  `~/em28xx-known-good-commit.txt`.
- **Pins future runs to that commit** instead of re-tracking `master`, as long as
  that file exists.

**Back up `~/em28xx-known-good-commit.txt`.** If you ever do a clean install, copy
that file back to the same path on the new system *before* running `run.sh`, and it
will fetch the exact same source that worked here — fully bypassing any future
upstream drift.

If you don't have that file (first-ever run, or it was lost), `run.sh` falls back
to tracking `master` and will just re-discover/fix any new issue the same
self-service way described below.

## 7. Self-service for any future new error

If a future run hits a **new** `fatal error: some/path/header.h: No such file or
directory` that isn't already covered:

1. Open `~/em28xx-extra-paths.txt` on the Pi (created automatically on first run,
   with instructions inside).
2. Add the **directory** containing the missing header (not the filename) as a new
   line, relative to the root of `github.com/torvalds/linux`. Example: if the error
   says `linux/usb/quirks.h`, add the line `include/linux/usb`.
3. Re-run `./run.sh`. It re-fetches with that path included and automatically adds
   it to the compiler's include search path. No script edits needed.

This only helps with **missing-file** errors. If you instead see something like
`error: redefinition of 'struct foo'` (a type defined in two places) in a location
outside `include/linux/device-id/` — which is already handled automatically — that
needs a different, more careful fix; share that log rather than guessing at it,
since blindly deleting struct definitions elsewhere risks silently breaking
correctness rather than just failing to compile.

## 8. Using `run.sh`

Run **on the Raspberry Pi itself**, as your normal user (it calls `sudo` itself
where needed — do not run it as root directly):

```bash
chmod +x run.sh
./run.sh
```

It is safe to re-run after any failure or after editing
`~/em28xx-extra-paths.txt` — every step is idempotent.

What it does, in order:
1. Installs build dependencies (`build-essential`, `raspberrypi-kernel-headers`,
   etc.).
2. Fetches the required mainline source directories (pinned to a known-good commit
   once one exists).
3. Verifies the fetched source actually contains `461e v3` and `M88DS3103C` support
   before building anything — if a future mainline change ever removes or renames
   this support, the script stops cleanly here rather than building something
   useless.
4. Builds `m88ds3103` + `ts2020` + `a8293`, then `em28xx`, against the running
   kernel.
5. Installs the modules, runs `depmod -a`, reloads `em28xx`.
6. Verifies: `lsmod`, `/dev/dvb/adapter0/` listing, relevant `dmesg` lines, and the
   firmware file check.

## 9. Success criteria

- `dmesg` shows the board identified as (or equivalent to) **PCTV DVB-S2 Stick
  (461e v3)**.
- `dmesg` shows the frontend identified as **M88DS3103C**.
- `dvb-demod-m88ds3103c.fw` loads without error.
- `/dev/dvb/adapter0/frontend0` exists.

Once all four are true, the kernel/hardware problem is solved, and the system is
ready to move on to configuring TVHeadend / satellite scanning — which was
explicitly out of scope for this stage of the work.

## 10. Rollback

If the newly built modules fail to load (e.g. `modprobe: ERROR ... Invalid module
format`, meaning the module's version signature doesn't match the running kernel
exactly), revert to the stock in-box modules with:

```bash
sudo rm -rf /lib/modules/$(uname -r)/updates/dvb-frontends \
            /lib/modules/$(uname -r)/updates/usb/em28xx
sudo depmod -a
sudo modprobe -r em28xx m88ds3103
sudo modprobe em28xx
```

This removes only the locally-built replacement modules; the installed kernel and
its original modules are untouched throughout this entire process, so this rollback
is always safe.

## 11. Automatic re-build at boot (dvb-boot-check)

On this machine the build is re-run automatically when it is needed, not by
hand. A systemd timer (`dvb-boot-check.timer`) runs
`/usr/local/sbin/dvb-boot-check.sh` ~30 seconds after every boot; step 1 of
that check tests whether the custom `em28xx`/`m88ds3103` modules are installed
for the *currently running* kernel:

```sh
MODULES_BUILT() {
    [ -f "/lib/modules/$1/updates/usb/em28xx/em28xx.ko" ] &&
    [ -f "/lib/modules/$1/updates/dvb-frontends/m88ds3103.ko" ]
}
```

If they are missing (i.e. the kernel was upgraded since the last build — a
situation that *silently* drops the PCTV 461e v3 support, see section 0), the
check runs `run.sh` as the normal `daniel` user. It then re-checks the
firmware, USB ID `2013:0462`, `/dev/dvb` nodes, starts `dvb-node`, and requires
a real Astra 28.2E tune lock. On total failure it marks the tuner
`FIRMWARE_FAILED` so the tv-server dashboard shows the real state instead of a
misleading blank/IDLE.

Notes:

- `run.sh` still needs a *clean* environment to succeed (e.g. no half-finished
  build from a previous interrupted run). The boot check treats a failed build
  + failed tune as FAIL and records the reason in `journalctl -u dvb-boot-check`.
- `run.sh` pins to the known-good commit recorded in
  `~/em28xx-known-good-commit.txt` (section 6). A new kernel does not change
  that pin — it just triggers a rebuild of the *same* pinned source against the
  *new* kernel headers.
- Run the check manually at any time:
  `sudo systemctl start dvb-boot-check.service`, then
  `journalctl -u dvb-boot-check -e` to see the result.