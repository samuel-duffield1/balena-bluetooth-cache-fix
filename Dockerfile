FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bluez \
    dbus \
    rfkill \
    python3-venv \
 && rm -rf /var/lib/apt/lists/*

# dbus needs /run/dbus to exist for the system bus socket
RUN mkdir -p /run/dbus

# Set the container D-Bus address so that all processes (including
# `docker exec` / `balena-engine exec` sessions) connect to the container
# bus rather than the host bus mounted at /run/dbus/system_bus_socket.
ENV DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/container_bus_socket

WORKDIR /usr/src/app

COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# TODO: Add your ble_service binary/script to PATH (or copy it here) and your
# ble_interface/ application directory before deploying. The default CMD is
# ["ble_service"], which runs after the entrypoint completes setup. Override
# CMD in a derived image or in docker-compose.yml to run your own application.

ENTRYPOINT ["/bin/bash", "/usr/src/app/entrypoint.sh"]
CMD ["ble_service"]
