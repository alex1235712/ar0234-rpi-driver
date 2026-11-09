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

set -u

SENSOR=/sys/bus/i2c/devices/1-0010          # ar0234 on i2c1, address 0x10
DPHY_DRV=/sys/bus/platform/drivers/rockchip-csi2-dphy
DPHY_DEV=csi2-dphy1
ISP_DRV=/sys/bus/platform/drivers/rkisp
ISP_DEV=rkisp-vir0
WAIT_SENSOR=30                              # seconds to wait for ar0234
WAIT_LINK=10                                # seconds to wait after re-bind

log() { echo "ar0234-rebind: $*"; }

# Write a value to a sysfs file, report failures
wr() {
	if ! echo "$1" > "$2" 2>/dev/null; then
		log "failed: echo $1 > $2"
		return 1
	fi
	return 0
}

# 1. Make sure the sensor driver is loaded and bound (chip id read OK)
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

# 2. Nothing to do if the ISP already registered the sensor
if [ -d "$SENSOR/video4linux" ]; then
	log "sensor already registered as $(ls "$SENSOR/video4linux"), nothing to do"
	exit 0
fi

# 3. Unbind: ISP first, then D-PHY
if [ -e "$ISP_DRV/$ISP_DEV" ]; then
	wr "$ISP_DEV" "$ISP_DRV/unbind" || exit 1
fi
if [ -e "$DPHY_DRV/$DPHY_DEV" ]; then
	wr "$DPHY_DEV" "$DPHY_DRV/unbind" || exit 1
fi
sleep 1

# 4. Bind: D-PHY first (it finds the sensor), then ISP
wr "$DPHY_DEV" "$DPHY_DRV/bind" || exit 1
sleep 1
wr "$ISP_DEV" "$ISP_DRV/bind" || exit 1

# 5. Verify that the sensor got a V4L2 sub-device node
i=0
while [ ! -d "$SENSOR/video4linux" ]; do
	i=$((i + 1))
	if [ "$i" -gt "$WAIT_LINK" ]; then
		log "re-bind finished but sensor was not registered (check: dmesg | tail -40)"
		exit 1
	fi
	sleep 1
done

log "ok, sensor registered as $(ls "$SENSOR/video4linux")"
exit 0
