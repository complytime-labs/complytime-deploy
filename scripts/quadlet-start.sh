#!/bin/bash
# quadlet-start.sh — Start all ComplyTime services via systemd --user.
set -euo pipefail

echo "=== Starting ComplyTime services ==="

echo "Starting network..."
systemctl --user start complytime-network.service

echo "Starting RustFS..."
systemctl --user start complytime-rustfs
echo "Starting Loki..."
systemctl --user start complytime-loki

# Keycloak must start before the collector — the collector's OIDC extension
# needs Keycloak's discovery endpoint at startup.
if systemctl --user cat complytime-keycloak.service &>/dev/null; then
	echo "Starting Keycloak..."
	systemctl --user start complytime-keycloak
fi

echo "Starting Collector..."
systemctl --user start complytime-collector
echo "Starting Grafana..."
systemctl --user start complytime-grafana

echo ""
echo "=== All services started ==="
echo ""
SERVICES=(complytime-rustfs complytime-loki complytime-collector complytime-grafana)
if systemctl --user cat complytime-keycloak.service &>/dev/null; then
	SERVICES=(complytime-rustfs complytime-loki complytime-keycloak complytime-collector complytime-grafana)
fi
systemctl --user --no-pager status "${SERVICES[@]}" 2>/dev/null | grep -E "●|Active:" || true
