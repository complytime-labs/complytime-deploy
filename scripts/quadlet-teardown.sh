#!/bin/bash
# quadlet-teardown.sh — Remove all ComplyTime quadlet services, data, and network.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
RUNTIME_DIR="$REPO_ROOT/quadlet/runtime"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

echo "=== Tearing down ComplyTime Quadlet deployment ==="

# Stop services
echo "Stopping services..."
systemctl --user stop complytime-collector complytime-grafana complytime-loki complytime-rustfs complytime-network 2>/dev/null || true

# Remove quadlet unit files
echo "Removing quadlet unit files..."
rm -f "$SYSTEMD_DIR"/complytime*.{container,network,volume}
rm -f "$SYSTEMD_DIR"/{rustfs,loki,collector,grafana}.container
rm -f "$SYSTEMD_DIR"/{rustfs,loki,grafana}-storage.volume
systemctl --user daemon-reload

# Remove podman volumes
echo "Removing volumes..."
podman volume rm complytime-loki-storage complytime-grafana-storage complytime-rustfs-storage 2>/dev/null || true

# Remove runtime directory
echo "Removing runtime files..."
rm -rf "$RUNTIME_DIR"

# Remove network
echo "Removing network..."
podman network rm complytime 2>/dev/null || true

echo ""
echo "=== Teardown complete ==="
