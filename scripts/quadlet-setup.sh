#!/bin/bash
# quadlet-setup.sh — Generate certs, configs, and install quadlet units for ComplyTime.
# Usage: ./scripts/quadlet-setup.sh [--no-tls]
set -euo pipefail

# Parse arguments
TLS_ENABLED=true
OIDC_ENABLED=false
for arg in "$@"; do
	case "$arg" in
	--no-tls) TLS_ENABLED=false ;;
	--oidc) OIDC_ENABLED=true ;;
	*)
		echo "Unknown argument: $arg"
		echo "Usage: $0 [--no-tls] [--oidc]"
		exit 1
		;;
	esac
done

COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-quay.io/complytime/beacon-collector:latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUADLET_DIR="$REPO_ROOT/quadlet"
RUNTIME_DIR="$QUADLET_DIR/runtime"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

# Config source directories
BASE_CONFIGS="$REPO_ROOT/base"
LOCAL_CONFIGS="$REPO_ROOT/overlays/local/configs"
QUADLET_CONFIGS="$QUADLET_DIR/configs"

echo "=== ComplyTime Quadlet Setup ==="
TLS_LABEL=$([[ "$TLS_ENABLED" = true ]] && echo "enabled" || echo "disabled")
OIDC_LABEL=$([[ "$OIDC_ENABLED" = true ]] && echo "enabled" || echo "disabled")
echo "TLS: $TLS_LABEL"
echo "OIDC: $OIDC_LABEL"
echo "Collector image: $COLLECTOR_IMAGE"
echo ""

# --- Prerequisites ---

check_prereqs() {
	if ! command -v podman &>/dev/null; then
		echo "ERROR: podman not found. Install: https://podman.io/getting-started/installation"
		exit 1
	fi
	local podman_version_output version major minor
	podman_version_output=$(podman --version)
	version=$(echo "$podman_version_output" | grep -oP '\d+\.\d+')
	major=$(echo "$version" | cut -d. -f1)
	minor=$(echo "$version" | cut -d. -f2)
	if [[ "$major" -lt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -lt 4 ]]; }; then
		echo "ERROR: podman >= 4.4 required (found: $version)"
		exit 1
	fi
	podman_full_version=$(podman --version)
	podman_display_version=$(echo "$podman_full_version" | grep -oP '\d+\.\d+\.\d+') || true
	echo "OK: podman $podman_display_version"

	if systemctl --user is-system-running &>/dev/null; then
		echo "OK: systemctl --user available"
	else
		# is-system-running exits non-zero for "degraded" (some units failed)
		# but that still means the user session manager is reachable.
		state=$(systemctl --user is-system-running 2>/dev/null) || true
		if [[ "$state" == "degraded" || "$state" == "running" ]]; then
			echo "OK: systemctl --user available ($state)"
		else
			echo "ERROR: systemctl --user not available"
			current_user=$(whoami) || true
			echo "  Ensure user lingering is enabled: loginctl enable-linger $current_user"
			exit 1
		fi
	fi

	if [[ "$TLS_ENABLED" = true ]]; then
		if ! command -v openssl &>/dev/null; then
			echo "ERROR: openssl not found (required for TLS). Install or use --no-tls"
			exit 1
		fi
		echo "OK: openssl available"
	fi
}
check_prereqs

# --- Runtime directories ---

mkdir -p "$RUNTIME_DIR"/{certs,configs,env}

# --- TLS certificates ---

if [[ "$TLS_ENABLED" = true ]]; then
	echo ""
	echo "Generating TLS certificates..."
	CERT_DIR="$RUNTIME_DIR/certs"

	# Generate CA
	openssl req -x509 -newkey rsa:4096 -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
		-days 365 -nodes -subj "/CN=ComplyTime Local CA" 2>/dev/null
	echo "  CA certificate generated"

	# Generate per-service certs signed by CA
	for svc in loki collector grafana; do
		openssl req -newkey rsa:2048 -keyout "$CERT_DIR/$svc.key" -out "$CERT_DIR/$svc.csr" \
			-nodes -subj "/CN=complytime-$svc" 2>/dev/null

		cat >"$CERT_DIR/$svc-san.cnf" <<SANCNF
[req]
distinguished_name = req_dn
[req_dn]
[v3_ext]
subjectAltName = DNS:complytime-$svc,DNS:localhost
SANCNF

		openssl x509 -req -in "$CERT_DIR/$svc.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
			-CAcreateserial -out "$CERT_DIR/$svc.crt" -days 365 \
			-extfile "$CERT_DIR/$svc-san.cnf" -extensions v3_ext 2>/dev/null

		# Each service gets its own cert directory (mounted at /etc/tls in the container)
		mkdir -p "$CERT_DIR/$svc"
		cp "$CERT_DIR/$svc.crt" "$CERT_DIR/$svc/tls.crt"
		cp "$CERT_DIR/$svc.key" "$CERT_DIR/$svc/tls.key"
		cp "$CERT_DIR/ca.crt" "$CERT_DIR/$svc/ca.crt"

		# Rootless containers run as non-root; make certs readable
		chmod 0644 "$CERT_DIR/$svc/tls.key" "$CERT_DIR/$svc/tls.crt" "$CERT_DIR/$svc/ca.crt"

		rm -f "$CERT_DIR/$svc.csr" "$CERT_DIR/$svc-san.cnf"
		echo "  $svc certificate generated"
	done
fi

# --- Configuration files ---

echo ""
echo "Generating configuration files..."
PROTOCOL=$([[ "$TLS_ENABLED" = true ]] && echo "https" || echo "http")

# Collector — local config with ${env:*} substitution for hosts
if [[ "$OIDC_ENABLED" = true ]]; then
	cp "$LOCAL_CONFIGS/collector-oidc.yaml" "$RUNTIME_DIR/configs/collector-config.yaml"
else
	cp "$LOCAL_CONFIGS/collector-local.yaml" "$RUNTIME_DIR/configs/collector-config.yaml"
fi
# CRC mounts the service CA at /etc/ssl/certs/service-ca.crt via configmap;
# quadlet mounts it at /etc/tls/ca.crt alongside the server cert.
sed -i 's|/etc/ssl/certs/service-ca.crt|/etc/tls/ca.crt|g' "$RUNTIME_DIR/configs/collector-config.yaml"
if [[ "$TLS_ENABLED" = false ]]; then
	# Strip TLS blocks for no-TLS mode
	sed -i '/tls:/,/insecure_skip_verify:/d' "$RUNTIME_DIR/configs/collector-config.yaml"
	sed -i 's|https://|http://|g' "$RUNTIME_DIR/configs/collector-config.yaml"
fi

# Loki — shared config from base
cp "$BASE_CONFIGS/loki/local-config.yaml" "$RUNTIME_DIR/configs/loki-config.yaml"
if [[ "$TLS_ENABLED" = false ]]; then
	sed -i '/http_tls_config:/,/key_file:/d' "$RUNTIME_DIR/configs/loki-config.yaml"
fi

# Grafana datasource
if [[ "$TLS_ENABLED" = true ]]; then
	python3 -c "
with open('$QUADLET_CONFIGS/grafana-datasource-tls.yaml') as f:
    template = f.read()
with open('$RUNTIME_DIR/certs/ca.crt') as f:
    ca_cert = f.read()
indented = '\n'.join('        ' + line for line in ca_cert.strip().split('\n'))
result = template.replace('@@CA_CERT@@', indented.lstrip())
result = result.replace('@@LOKI_HOST@@', 'complytime-loki')
with open('$RUNTIME_DIR/configs/grafana-datasource.yaml', 'w') as f:
    f.write(result)
"
else
	sed 's|@@LOKI_HOST@@|complytime-loki|g' \
		"$QUADLET_CONFIGS/grafana-datasource-notls.yaml" >"$RUNTIME_DIR/configs/grafana-datasource.yaml"
fi
echo "  Configuration files generated"

# --- Collector environment file ---

if [[ "$OIDC_ENABLED" = true ]]; then
	OIDC_URL="http://complytime-keycloak:8080/realms/complytime"
else
	OIDC_URL=""
fi
cat >"$RUNTIME_DIR/env/collector.env" <<ENVFILE
LOKI_HOST=complytime-loki
OIDC_ISSUER_URL=${OIDC_URL}
S3_ENDPOINT=http://complytime-rustfs:9000
S3_BUCKETNAME=complytime-evidence
S3_OBJ_DIR=local
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=rustfsadmin
AWS_SECRET_ACCESS_KEY=rustfsadmin
ENVFILE
echo "  Collector environment file generated"

# --- Keycloak realm (OIDC mode only) ---

if [[ "$OIDC_ENABLED" = true ]]; then
	echo ""
	echo "Copying Keycloak realm configuration..."
	cp "$REPO_ROOT/overlays/local/keycloak/complytime-realm.json" \
		"$RUNTIME_DIR/configs/complytime-realm.json"
	echo "  Realm config copied"
fi

# --- Install quadlet unit files ---

echo ""
echo "Installing quadlet unit files..."
mkdir -p "$SYSTEMD_DIR"

# Remove stale unit files from previous naming conventions
rm -f "$SYSTEMD_DIR"/{rustfs,loki,collector,grafana}.container
rm -f "$SYSTEMD_DIR"/{rustfs,loki,grafana}-storage.volume

for template in "$QUADLET_DIR/templates"/*; do
	filename=$(basename "$template")
	sed -e "s|@@RUNTIME@@|$RUNTIME_DIR|g" \
		-e "s|@@PROTOCOL@@|$PROTOCOL|g" \
		-e "s|@@COLLECTOR_IMAGE@@|$COLLECTOR_IMAGE|g" \
		"$template" >"$SYSTEMD_DIR/$filename"
	echo "  Installed $filename"
done

# For no-TLS mode, strip cert volume mounts and Grafana cert env vars
if [[ "$TLS_ENABLED" = false ]]; then
	for f in "$SYSTEMD_DIR"/*.container; do
		sed -i '/Volume=.*\/certs.*\/etc\/tls/d' "$f"
		sed -i '/GF_SERVER_CERT_FILE/d' "$f"
		sed -i '/GF_SERVER_CERT_KEY/d' "$f"
	done
fi

# Reload systemd to pick up new unit files
systemctl --user daemon-reload
echo ""
echo "=== Quadlet setup complete ==="
echo ""
echo "Next steps:"
echo "  task quadlet:start     # Start all services"
echo "  task quadlet:status    # Check status"
if [[ "$TLS_ENABLED" = true ]]; then
	echo "  Grafana: https://localhost:3000 (accept self-signed cert)"
	echo "  Collector: https://localhost:4318"
else
	echo "  Grafana: http://localhost:3000"
	echo "  Collector: http://localhost:4318"
fi
