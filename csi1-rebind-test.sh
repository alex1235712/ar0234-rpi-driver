#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# csi1-rebind-test.sh - MANUAL TEST ONLY, never run at boot.
#
# Re-binds the CSI1 camera pipeline of LubanCat-1IO so the ISP can pick up
# the AR0234 on i2c5 that was loaded too late:
#
#   ar0234 (5-0010) -> csi2_dphy2 -> mipi_csi2 -> rkcif_mipi_lvds
#                   -> rkcif_mipi_lvds_sditf -> rkisp-vir1
#
# WARNING: the Rockchip csi2-dphy driver does not unregister its async
# notifier on unbind (use-after-free). Re-binding it can crash the kernel,
# as seen on CSI0. Save your work and run "sync" first.
#
# Usage:
#   sudo sh csi1-rebind-test.sh          # only show what would be done
#   sudo sh csi1-rebind-test.sh unbind   # unbind the chain only
#   sudo sh csi1-rebind-test.sh bind     # bind the chain only
#   sudo sh csi1-rebind-test.sh go       # unbind, then bind

set -u

SENSOR=/sys/bus/i2c/devices/5-0010
PLAT=/sys/bus/platform/devices
STATE=/tmp/csi1-rebind.drivers      # remembers which driver owns each device
STEP_DELAY=2

# Upstream -> downstream, as device tree LABELS. They are resolved to the
# real platform device names at run time, so the script does not depend on
# how the kernel names the devices. Unbind runs in reverse order.
LABELS="csi2_dphy2 mipi_csi2 rkcif_mipi_lvds rkcif_mipi_lvds_sditf rkisp_vir1"

log() { echo "csi1-rebind: $*"; }

# Device tree label -> platform device name (empty if none)
resolve() {
	sym="/proc/device-tree/__symbols__/$1"
	[ -e "$sym" ] || return 0
	path=$(tr -d '\000' < "$sym")
	for dev in /sys/bus/platform/devices/*; do
		node=$(readlink -f "$dev/of_node" 2>/dev/null) || continue
		case "$node" in
		*/devicetree/base"$path")
			basename "$dev"
			return 0
			;;
		esac
	done
}

CHAIN=""
for l in $LABELS; do
	d=$(resolve "$l")
	if [ -z "$d" ]; then
		log "WARNING: no platform device for label '$l'"
		continue
	fi
	CHAIN="$CHAIN $d"
done

reverse() {
	out=""
	for x in "$@"; do out="$x $out"; done
	echo "$out"
}

driver_of() {
	if [ -e "$PLAT/$1/driver" ]; then
		basename "$(readlink "$PLAT/$1/driver")"
	fi
}

show() {
	log "sensor: $( [ -e "$SENSOR/driver" ] && echo bound || echo NOT bound )," \
	    "registered: $( [ -d "$SENSOR/video4linux" ] && ls "$SENSOR/video4linux" || echo no )"
	for d in $CHAIN; do
		if [ ! -e "$PLAT/$d" ]; then
			log "  $d: device not found"
		else
			drv=$(driver_of "$d")
			log "  $d: ${drv:-<unbound>}"
		fi
	done
}

do_unbind() {
	: > "$STATE"
	for d in $(reverse $CHAIN); do
		drv=$(driver_of "$d")
		if [ -z "$drv" ]; then
			log "skip $d (not bound)"
			continue
		fi
		echo "$d $drv" >> "$STATE"
		log "unbind $d from $drv"
		if ! echo "$d" > "/sys/bus/platform/drivers/$drv/unbind"; then
			log "FAILED to unbind $d, stopping"
			return 1
		fi
		sync
		sleep "$STEP_DELAY"
	done
}

do_bind() {
	if [ ! -s "$STATE" ]; then
		log "no saved driver list ($STATE), run 'unbind' first"
		return 1
	fi
	for d in $CHAIN; do
		drv=$(awk -v d="$d" '$1 == d { print $2 }' "$STATE")
		if [ -z "$drv" ]; then
			log "skip $d (was not bound before)"
			continue
		fi
		if [ -n "$(driver_of "$d")" ]; then
			log "skip $d (already bound)"
			continue
		fi
		log "bind $d to $drv"
		if ! echo "$d" > "/sys/bus/platform/drivers/$drv/bind"; then
			log "FAILED to bind $d, stopping (see: dmesg | tail -40)"
			return 1
		fi
		sync
		sleep "$STEP_DELAY"
	done
}

case "${1:-show}" in
show)
	show
	log "nothing changed; use 'unbind', 'bind' or 'go'"
	;;
unbind)
	show
	do_unbind
	show
	;;
bind)
	do_bind
	show
	;;
go)
	if [ ! -e "$SENSOR/driver" ]; then
		log "ar0234 on i2c5 is not bound (chip id not read?), aborting"
		exit 1
	fi
	show
	do_unbind || exit 1
	do_bind || exit 1
	sleep 2
	show
	;;
*)
	echo "usage: $0 [show|unbind|bind|go]"
	exit 1
	;;
esac
