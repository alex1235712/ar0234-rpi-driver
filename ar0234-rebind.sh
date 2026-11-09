#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# ar0234-rebind.sh - connect the AR0234 sensor to the Rockchip ISP at boot.
#
# Why: rkisp is built into the kernel and drops sensors that are not ready
# at late_initcall_sync (before any user-space program runs). The ar0234
# driver is a loadable module, so it always arrives too late. Re-binding
# csi2-dphy1 and rkisp-vir0 after ar0234 has probed makes the ISP pick the
# sensor up again.
#
# Order matters: unbind downstream first (ISP, then D-PHY),
#                bind upstream first   (D-PHY, then ISP).
#
# v2: waits for udev to settle, uses longer delays and retries, because at
#     boot the system is busier than during a manual run.

set -u

SENSOR=/sys/bus/i2c/devices/1-0010          # ar0234 on i2c1, address 0x10
DPHY_DRV=/sys/bus/platform/drivers/rockchip-csi2-dphy
DPHY_DEV=csi2-dphy1
ISP_DRV=/sys/bus/platform/drivers/rkisp
ISP_DEV=rkisp-vir0
AIQ=rkaiq_3A.service

WAIT_SENSOR=30      # seconds to wait for ar0234 to bind
START_DELAY=5       # extra seconds before touching the ISP
STEP_DELAY=2        # seconds between unbind/bind steps
WAIT_LINK=10        # seconds to wait for the sensor node after bind
RETRIES=3

log() { echo "ar0234-rebind: $*"; }

wr() {
	if ! echo "$1" > "$2" 2>/dev/null; then
		log "failed: echo $1 > $2"
		return 1
	fi
	return 0
}

settle() { udevadm settle --timeout=30 2>/dev/null || true; }

linked() { [ -d "$SENSOR/video4linux" ]; }

# 1. Wait for the sensor driver (chip id read OK)
modprobe ar0234 2>/dev/null || true
i=0
while [ ! -e "$SENSOR/driver" ]; do
	i=$((i + 1))
	if [ "$i" -gt "$WAIT_SENSOR" ]; then
		log "ar0234 not bound after ${WAIT_SENSOR}s (check: dmesg | grep ar0234), giving up"
		exit 1
	fi
	sleep 1
done
log "ar0234 is bound"

if linked; then
	log "sensor already registered as $(ls "$SENSOR/video4linux"), nothing to do"
	exit 0
fi

# 2. Let boot-time udev work on the video nodes finish first
settle
sleep "$START_DELAY"

# 3. Nothing may hold the ISP nodes while it is unbound
aiq_was_active=0
if systemctl is-active --quiet "$AIQ" 2>/dev/null; then
	aiq_was_active=1
	log "stopping $AIQ"
	systemctl stop "$AIQ" || true
fi

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
	log "attempt $attempt/$RETRIES"

	# Unbind: ISP first, then D-PHY (skip what is already unbound)
	[ -e "$ISP_DRV/$ISP_DEV" ] && wr "$ISP_DEV" "$ISP_DRV/unbind"
	[ -e "$DPHY_DRV/$DPHY_DEV" ] && wr "$DPHY_DEV" "$DPHY_DRV/unbind"
	settle
	sleep "$STEP_DELAY"

	# Bind: D-PHY first (it finds the sensor), then ISP
	if wr "$DPHY_DEV" "$DPHY_DRV/bind"; then
		settle
		sleep "$STEP_DELAY"
		wr "$ISP_DEV" "$ISP_DRV/bind"
	fi

	i=0
	while [ "$i" -lt "$WAIT_LINK" ] && ! linked; do
		i=$((i + 1))
		sleep 1
	done

	if linked; then
		log "ok, sensor registered as $(ls "$SENSOR/video4linux")"
		if [ "$aiq_was_active" -eq 1 ]; then
			systemctl start "$AIQ" || true
		fi
		exit 0
	fi

	log "attempt $attempt failed"
	attempt=$((attempt + 1))
	sleep "$STEP_DELAY"
done

log "giving up after $RETRIES attempts (check: dmesg | tail -60)"
exit 1
