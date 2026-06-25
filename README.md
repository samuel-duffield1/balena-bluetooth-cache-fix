# balena Bluetooth BLE Cache Fix

A balena service that takes ownership of Bluetooth from the balenaOS host, runs a container-managed `bluetoothd`, and actively prevents stale BLE device accumulation in the BlueZ cache.

## Problem

On balenaOS, the host `bluetoothd` runs alongside any container that also wants to manage Bluetooth. This causes two issues:

1. **Ownership conflict** — two `bluetoothd` instances compete for the same adapter.
2. **Cache accumulation** — BlueZ accumulates every BLE device it has ever seen in `/var/lib/bluetooth`. Over time this grows unbounded, which can degrade scan performance and connection reliability.

## What this service does

The service is structured as a Docker `ENTRYPOINT` (`entrypoint.sh`) that handles all Bluetooth setup, then hands off to whatever application is set as `CMD`. The default `CMD` is `ble_service`, but this can be overridden in a derived image or in `docker-compose.yml`.

1. **Takes ownership of Bluetooth from the host** — runtime-masks and stops the host `bluetoothd` via the host D-Bus systemd API (`MaskUnitFiles` + `StopUnit`). The host D-Bus socket is mounted at `/host/run/dbus/system_bus_socket` by `io.balena.features.dbus` (supervisor v1.7.0+). A runtime mask writes to `/run/systemd/system/` (tmpfs), which is writable even on balenaOS's read-only rootfs, and prevents the host service from restarting regardless of its `Restart=` policy. The mask is cleared on host reboot; the container re-applies it each time it starts.
2. **Starts a container-managed `bluetoothd`** — runs `bluetoothd --experimental` inside the container, connected to the container's own D-Bus instance, giving full control over BlueZ configuration.
3. **Clears the BLE device cache on startup** — removes cached devices left over from previous runs. Optionally age-aware: when `DEVICE_MAX_AGE_DAYS` is set, only devices not seen within that window are removed, preserving recently paired devices.
4. **Optionally clears the cache periodically at runtime** — when `DEVICE_CLEANUP_INTERVAL` is set, the same age-aware cleanup runs on a repeating interval to prevent accumulation during long-running deployments.

## Setup

### Prerequisites

Add your application code to the project before deploying:

- The image uses Docker's `ENTRYPOINT`/`CMD` split. `entrypoint.sh` handles all Bluetooth setup and then runs `exec "$@"`, passing control to whatever `CMD` is set to. The default `CMD` is `["ble_service"]`.
- To use your own application, either copy your binary into the image (so it is on `PATH` and reachable as the default `CMD`), or override `CMD` in a derived image or in `docker-compose.yml`.
- If your application uses a Python virtual environment, place it at `/usr/src/app/ble_interface/venv`. The entrypoint will activate it automatically if present.

### Deploy

```bash
balena push <fleet-name>
```

## Environment Variables

All variables are optional. Set them on the balenaCloud dashboard or via the CLI (`balena env set <VAR> <value> --fleet <fleet>`).

| Variable                  | Default   | Description                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DEVICE_CLEANUP_INTERVAL` | _(unset)_ | When set, the BLE device cache is cleaned on this interval (in seconds) during runtime. When unset, the cache is only cleared once at container startup.                                                                                                                                                                                                                             |
| `DEVICE_MAX_AGE_DAYS`     | _(unset)_ | When set, cleanup only removes devices whose BlueZ `info` file has not been updated in more than this many days. Devices seen or connected within the window are preserved. When unset, **all** cached devices are removed on each cleanup. Requires the `bluetooth-data` named volume (included in `docker-compose.yml`) so that file timestamps persist across container restarts. |

### Common configurations

**Clear everything on startup only (default — no variables needed):**  
All cached devices are wiped at startup. No periodic cleanup during runtime.

**Clear everything on startup, and also periodically during runtime:**
```
DEVICE_CLEANUP_INTERVAL=3600
```

**Preserve recently-seen devices; clear old ones on startup only:**
```
DEVICE_MAX_AGE_DAYS=7
```

**Preserve recently-seen devices; clear old ones on startup and every hour:**
```
DEVICE_MAX_AGE_DAYS=7
DEVICE_CLEANUP_INTERVAL=3600
```

## Testing

A test script is included that verifies the service is working correctly on a live device. It opens a `balena tunnel` to the device, then runs checks against both the host OS and the `bluetooth` container over SSH.

**Requirements:** balena CLI installed and authenticated (`balena login`).

```bash
./test.sh <device-uuid>
```

An optional second argument overrides the local tunnel port (default: `22222`):

```bash
./test.sh <device-uuid> 12345
```

The script runs seven checks:

| # | Check | What it verifies |
|---|---|---|
| 1 | Host `bluetooth.service` is inactive and masked | `MaskUnitFiles` + `StopUnit` reached the host D-Bus |
| 2 | `bluetooth` container is running | The service started and is present in `balena-engine ps` |
| 3 | Container D-Bus is responding | `dbus-daemon` started at `/run/dbus/container_bus_socket` |
| 4 | `org.bluez` is on the container bus | Container `bluetoothd` acquired the bus name |
| 5 | `hci0` is `UP RUNNING` | Adapter was unblocked and brought up |
| 6 | BLE scan starts | `bluetoothctl scan on` returns "Discovery started" |
| 7 | `org.bluez` is **not** on the host D-Bus | Host `bluetoothd` did not re-acquire the adapter |

Test 7 is the key isolation check: it catches the case where the runtime mask failed and the host `bluetoothd` silently reclaimed the adapter before the container's `bluetoothd` started.

The script exits with code `0` if all checks pass, or the number of failures otherwise — suitable for use in CI.

## Security note

This service uses three specific privilege grants in place of `privileged: true`:

| Grant                          | Why                                                                                                                                                                                                    |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `cap_add: NET_ADMIN`           | Required by `bluetoothd`, `hciconfig`, and `rfkill` for Bluetooth socket and adapter management.                                                                                                       |
| `cap_add: NET_RAW`             | Required by `bluetoothd` for raw HCI socket access.                                                                                                                                                    |
| `devices: /dev/rfkill`         | Required by `rfkill unblock bluetooth` to unblock the adapter.                                                                                                                                         |
| `io.balena.features.dbus: "1"` | Mounts the host D-Bus socket so the container can call `MaskUnitFiles` and `StopUnit` on the host systemd to disable the host `bluetoothd` for the current boot. **Exposes the full host system bus.** |

The container's own D-Bus daemon (used by `bluetoothd` and `bluetoothctl`) runs at `/run/dbus/container_bus_socket` to avoid conflicting with the host socket at `/run/dbus/system_bus_socket`.
