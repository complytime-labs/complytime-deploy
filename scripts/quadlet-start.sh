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

echo "Starting Collector..."
systemctl --user start complytime-collector
echo "Starting Grafana..."
systemctl --user start complytime-grafana

echo ""
echo "=== All services started ==="
echo ""
systemctl --user --no-pager status complytime-rustfs complytime-loki complytime-collector complytime-grafana 2>/dev/null | grep -E "●|Active:" || true
