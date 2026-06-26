#!/bin/bash
# quadlet-stop.sh — Stop all ComplyTime services.
set -euo pipefail

echo "=== Stopping ComplyTime services ==="
systemctl --user stop complytime-collector complytime-grafana complytime-keycloak complytime-loki complytime-rustfs complytime-network 2>/dev/null || true
echo "=== All services stopped ==="
