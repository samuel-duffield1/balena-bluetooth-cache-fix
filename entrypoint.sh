#!/bin/bash
set -euo pipefail

if [ -d "/usr/src/app/ble_interface/venv" ]; then
  . /usr/src/app/ble_interface/venv/bin/activate
fi

# ── Step 1: Take ownership of Bluetooth from the host ────────────────────────
# Mask and stop the host bluetoothd via the host D-Bus systemd API BEFORE
# starting the container's own D-Bus daemon. Doing this first avoids any
# ambiguity about which bus socket dbus-send connects to.
#
# io.balena.features.dbus mounts the host D-Bus at /host/run/dbus/system_bus_socket
# (supervisor v1.7.0+). A runtime mask writes to /run/systemd/system/ (tmpfs) on
# the host, which is writable even on balenaOS's read-only rootfs, and prevents
# the unit from restarting regardless of its Restart= policy. The mask is cleared
# on host reboot; this container re-applies it each time it starts.
HOST_DBUS_SOCKET=/host/run/dbus/system_bus_socket

# Wait up to 10 s for the supervisor to bind-mount the host D-Bus socket.
for _ in $(seq 1 10); do
  [ -S "${HOST_DBUS_SOCKET}" ] && break
  sleep 1
done

if [ -S "${HOST_DBUS_SOCKET}" ]; then
  echo "Masking host bluetooth.service (runtime)..."
  dbus-send \
    --bus=unix:path="${HOST_DBUS_SOCKET}" \
    --dest=org.freedesktop.systemd1 \
    --type=method_call \
    --print-reply \
    --reply-timeout=5000 \
    /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager.MaskUnitFiles \
    array:string:"bluetooth.service" boolean:true boolean:false >/dev/null \
    || echo "WARNING: MaskUnitFiles failed — host bluetoothd may not be masked" >&2

  echo "Stopping host bluetooth.service..."
  dbus-send \
    --bus=unix:path="${HOST_DBUS_SOCKET}" \
    --dest=org.freedesktop.systemd1 \
    --type=method_call \
    --print-reply \
    --reply-timeout=5000 \
    /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager.StopUnit \
    string:"bluetooth.service" string:"replace" >/dev/null \
    || echo "WARNING: StopUnit failed — host bluetoothd may still be running" >&2

  # StopUnit is async — wait until the unit is actually inactive before we
  # start our own bluetoothd, so the HCI management socket is free.
  echo "Waiting for host bluetooth.service to become inactive..."
  for _ in $(seq 1 15); do
    active_state=$(dbus-send \
      --bus=unix:path="${HOST_DBUS_SOCKET}" \
      --dest=org.freedesktop.systemd1 \
      --type=method_call \
      --print-reply \
      --reply-timeout=2000 \
      /org/freedesktop/systemd1/unit/bluetooth_2eservice \
      org.freedesktop.DBus.Properties.Get \
      string:"org.freedesktop.systemd1.Unit" \
      string:"ActiveState" 2>/dev/null \
      | awk '/variant/{print $NF}' | tr -d '"' || echo "unknown")
    echo "  ActiveState: ${active_state}"
    if [ "${active_state}" = "inactive" ] || [ "${active_state}" = "failed" ]; then
      echo "Host bluetooth.service stopped."
      break
    fi
    sleep 1
  done
else
  echo "WARNING: host D-Bus socket not found at ${HOST_DBUS_SOCKET} after 10s." >&2
  echo "         /run/dbus contents: $(ls -la /run/dbus/ 2>/dev/null || echo '(directory missing)')" >&2
  echo "         Ensure 'io.balena.features.dbus: \"1\"' is set in the service labels in docker-compose.yml." >&2
fi

# ── Step 2: Container D-Bus ──────────────────────────────────────────────────
# Start the container's own D-Bus system daemon at a dedicated socket path.
# /run/dbus/system_bus_socket is reserved for the host D-Bus socket mounted
# by io.balena.features.dbus, so the container bus runs at a separate path.
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --address=unix:path=/run/dbus/container_bus_socket --nofork &

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/container_bus_socket
DBUS_SOCKET=/run/dbus/container_bus_socket

for _ in $(seq 1 60); do
  if [ -S "${DBUS_SOCKET}" ] && dbus-send --system --dest=org.freedesktop.DBus \
    / org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! dbus-send --system --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
  echo "DBus not ready at ${DBUS_SOCKET}" >&2
  exit 1
fi

rfkill unblock bluetooth >/dev/null 2>&1 || true
hciconfig hci0 up >/dev/null 2>&1 || true

# Run bluetoothd and filter out noisy Adv Monitor messages
bluetoothd -n --experimental 2>&1 | grep -v "Adv Monitor app" &

for _ in $(seq 1 30); do
  if dbus-send --system --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames 2>/dev/null | grep -q "org.bluez"; then
    break
  fi
  sleep 1
done

# Remove cached BLE devices from BlueZ.
# If DEVICE_MAX_AGE_DAYS is set, only removes devices whose
# /var/lib/bluetooth/<adapter>/<device>/info file has not been modified within
# that many days. BlueZ updates this file on connection and when advertising
# data changes, so paired/recently-seen devices are preserved.
# Requires a persistent named volume on /var/lib/bluetooth to be meaningful
# across container restarts.
# If DEVICE_MAX_AGE_DAYS is unset, all cached devices are removed.
cleanup_ble_devices() {
  if [ -n "${DEVICE_MAX_AGE_DAYS:-}" ]; then
    find /var/lib/bluetooth -mindepth 3 -maxdepth 3 -name "info" \
        -mtime +"${DEVICE_MAX_AGE_DAYS}" 2>/dev/null \
      | while IFS= read -r info_file; do
          dev=$(basename "$(dirname "$info_file")")
          bluetoothctl remove "$dev" >/dev/null 2>&1 || true
        done
  else
    for dev in $(bluetoothctl devices 2>/dev/null | awk '{print $2}'); do
      bluetoothctl remove "$dev" >/dev/null 2>&1 || true
    done
  fi
}

# Clean up stale BLE devices from previous runs
echo "Cleaning up cached BLE devices..."
cleanup_ble_devices

# Periodically clean up stale BLE devices from BlueZ cache to prevent accumulation.
# Only runs when DEVICE_CLEANUP_INTERVAL is explicitly set (in seconds).
# Leave unset to clear devices only once at startup (above) and not during runtime.
if [ -n "${DEVICE_CLEANUP_INTERVAL:-}" ]; then
  (
    while true; do
      sleep "${DEVICE_CLEANUP_INTERVAL}"
      cleanup_ble_devices
    done
  ) &
fi

exec "$@"
