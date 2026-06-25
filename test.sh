#!/bin/bash
# Usage: ./test.sh <device-uuid> [local-port]
#
# Verifies the bluetooth BLE cache fix service on a running balena device.
# Requires balena CLI to be installed and authenticated.
#
# Connects via `balena tunnel` (SSH port forward) and runs checks against
# both the host OS and the bluetooth container.
set -euo pipefail

# Colors (disabled when not writing to a terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

FAILURES=0

pass()    { printf "  ${GREEN}✓ PASS${NC}  %s\n" "$1"; }
fail()    { printf "  ${RED}✗ FAIL${NC}  %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
info()    { printf "  ${YELLOW}  INFO${NC}  %s\n" "$1"; }
section() { printf "\n${BOLD}=== %s ===${NC}\n" "$1"; }

# ── Tunnel ───────────────────────────────────────────────────────────────────
for i in $(seq 1 20); do
  if ssh -p 4321 sam_duffield@localhost true 2>/dev/null; then
    printf "  Connected after %ss.\n" "$((i * 2))"
    break
  fi
  if [ "$i" -eq 20 ]; then
    printf "  ERROR: SSH not reachable after 40s.\n" >&2
    exit 1
  fi
  sleep 2
done

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run a command on the host OS
h() { ssh -p 4321 sam_duffield@localhost "$1" 2>/dev/null; }

# Run a command inside the bluetooth container (uses cached $CID)
cx() { ssh -p 4321 sam_duffield@localhost "balena-engine exec $CID sh -c '$1'" 2>/dev/null; }

# ── Test 1: Host bluetoothd ──────────────────────────────────────────────────

section "1. Host bluetoothd"

bt_active=$(h "systemctl is-active bluetooth" || true)
bt_enabled=$(h "systemctl is-enabled bluetooth" || true)
info "is-active:  $bt_active"
info "is-enabled: $bt_enabled"

if [ "$bt_active" != "active" ]; then
  pass "bluetooth.service is not active"
else
  fail "bluetooth.service is still active — MaskUnitFiles/StopUnit may not have reached the host D-Bus"
fi

if [ "$bt_enabled" = "masked" ] || [ "$bt_enabled" = "masked-runtime" ]; then
  pass "bluetooth.service is masked (got: $bt_enabled)"
else
  fail "bluetooth.service is not masked (got: $bt_enabled) — check io.balena.features.dbus label is set"
fi

# ── Test 2: Container running ────────────────────────────────────────────────

section "2. Bluetooth container"

CID=$(h "balena-engine ps -q --filter label=io.balena.service-name=bluetooth" | head -1 | tr -d '[:space:]')

if [ -n "$CID" ]; then
  pass "bluetooth container is running (id: ${CID:0:12})"
else
  fail "bluetooth container not found — is the service named 'bluetooth' in docker-compose.yml?"
  printf "\n${RED}Cannot continue container tests.${NC}\n\n" >&2
  exit "$FAILURES"
fi

# ── Test 3: Container D-Bus ──────────────────────────────────────────────────

section "3. Container D-Bus"

if cx "dbus-send --bus=unix:path=/run/dbus/container_bus_socket --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >/dev/null 2>&1"; then
  pass "Container D-Bus is responding at /run/dbus/container_bus_socket"
else
  fail "Container D-Bus did not respond — dbus-daemon may not have started"
fi

# ── Test 4: org.bluez registered ─────────────────────────────────────────────

section "4. BlueZ on container D-Bus"

bus_names=$(cx "dbus-send --print-reply --bus=unix:path=/run/dbus/container_bus_socket --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames 2>/dev/null" || true)

if echo "$bus_names" | grep -q "org.bluez"; then
  pass "org.bluez is registered on the container D-Bus"
else
  fail "org.bluez not found — container bluetoothd may not have started or failed to acquire the bus"
fi

# ── Test 5: Adapter state ────────────────────────────────────────────────────

section "5. Bluetooth adapter"

hciout=$(cx "hciconfig hci0 2>&1" || true)
info "$(echo "$hciout" | head -2 | tr '\n' ' ')"

if echo "$hciout" | grep -q "UP RUNNING"; then
  pass "hci0 is UP RUNNING"
else
  fail "hci0 is not UP RUNNING — adapter may be blocked or bluetoothd did not bring it up"
fi

# ── Test 6: BLE scan ─────────────────────────────────────────────────────────

section "6. BLE scan"

# Root cause of previous failures: dbus-send exits immediately after
# StartDiscovery returns, and BlueZ cancels discovery the instant its only
# requesting D-Bus client disconnects. The sleep 10 ran locally while
# discovery was already stopped, so GetManagedObjects saw no devices.
#
# Fix: run `bluetoothctl --timeout 12 scan on` in the background INSIDE the
# container so its D-Bus connection (and therefore discovery) stays alive for
# 12 s. We call GetManagedObjects after 10 s while it is still active.
# Device1 entries with an RSSI property were seen in the current session —
# RSSI is not persisted to disk so stale cache entries never carry it.

SCAN_SCRIPT=$(cat << 'ENDSCAN'
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/container_bus_socket
bluetoothctl --timeout 12 scan on >/dev/null 2>&1 &
BTPID=$!
sleep 10
dbus-send \
  --bus=unix:path=/run/dbus/container_bus_socket \
  --print-reply --reply-timeout=10000 \
  --dest=org.bluez / \
  org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>&1
wait $BTPID 2>/dev/null
ENDSCAN
)

info "Running 12 s LE scan inside container (bluetoothctl holds discovery open)..."
objects_reply=$(ssh -p 4321 sam_duffield@localhost \
  "balena-engine exec -i $CID sh" <<< "$SCAN_SCRIPT" 2>/dev/null || true)

if [ -z "$objects_reply" ]; then
  fail "GetManagedObjects returned no output — bluetoothctl may have failed without a TTY or exec failed"
else
  dev_count=$(echo  "$objects_reply" | grep -c '"org.bluez.Device1"' || true)
  rssi_count=$(echo "$objects_reply" | grep -c '"RSSI"' || true)
  info "Device1 entries in BlueZ: $dev_count  (with live RSSI: $rssi_count)"

  # Print names of live devices (those with an RSSI value). Walks the
  # GetManagedObjects reply tracking the current device path; when a new
  # device path line is seen, emits the previous device's name if it had RSSI.
  live_names=$(echo "$objects_reply" | awk '
    /object path "\/org\/bluez\/hci[0-9]+\/dev_/ {
      if (cur_path != "" && has_rssi && cur_name != "") print "    " cur_name
      cur_path = $0; cur_name = ""; has_rssi = 0; want_name = 0
    }
    /"Name"/ { want_name = 1; next }
    want_name && /string "/ {
      sub(/.*string "/, ""); sub(/".*/, ""); cur_name = $0; want_name = 0
    }
    /"RSSI"/ { has_rssi = 1 }
    END { if (cur_path != "" && has_rssi && cur_name != "") print "    " cur_name }
  ' || true)

  if [ -n "$live_names" ]; then
    info "Live device names:"
    echo "$live_names"
  fi

  if [ "$rssi_count" -gt 0 ]; then
    pass "BLE advertisements detected ($rssi_count device(s) with live RSSI)"
  else
    fail "No BLE advertisements seen in 12 s — verify a peripheral is advertising nearby"
    info "Reply head: $(echo "$objects_reply" | head -3 | tr '\n' ' ')"
  fi
fi


# ── Test 7: Host D-Bus socket is not the container D-Bus ─────────────────────
# Sanity-check that the two buses are not the same (i.e. the container is not
# accidentally talking to the host bus via org.bluez from the host bluetoothd).

section "7. Bus isolation"

host_bus_names=$(cx "dbus-send --print-reply --bus=unix:path=/run/dbus/system_bus_socket --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames 2>/dev/null" || true)

if echo "$host_bus_names" | grep -q "org.bluez"; then
  fail "org.bluez is registered on the HOST D-Bus — the host bluetoothd may still be running"
else
  pass "org.bluez is NOT on the host D-Bus (host bluetoothd is inactive as expected)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

section "Summary"
if [ "$FAILURES" -eq 0 ]; then
  printf "  ${GREEN}All tests passed.${NC}\n\n"
else
  printf "  ${RED}%d test(s) failed.${NC}\n\n" "$FAILURES"
fi

exit "$FAILURES"
