#!/bin/bash
set -euo pipefail

# ensure-sealed-secrets.sh — Create SealedSecrets and ConfigMaps with dev values
# for local CRC testing.
# Usage: ensure-sealed-secrets.sh <namespace>
#
# For each of the 5 required secrets (aws-creds, grafana-oidc-secret,
# grafana-admin-secret, quay-io-pull-secret, route-tls-certs), this script:
#   1. Checks if the secret already exists — skips if so
#   2. Creates a plaintext secret (dry-run)
#   3. Pipes through kubeseal to encrypt
#   4. Applies the SealedSecret to the cluster
#   5. Waits for the controller to decrypt it
#
# It also creates the collector-env ConfigMap with dev placeholder values
# so that local deploys using stage/production overlays can start the
# collector without requiring CI environment variables.
#
# When run as a non-kubeadmin user (e.g., 'developer'), the script exits
# early with a skip message. This lets 'developer' run integration:test
# after kubeadmin has done the initial setup via integration:setup.
#
# Prerequisites (only needed when resources must be created):
#   - oc CLI logged into the cluster
#   - kubeseal CLI installed
#   - sealed-secrets-controller running in kube-system

NAMESPACE="${1:?Usage: $0 <namespace>}"
[[ "$NAMESPACE" =~ ^[a-z][a-z0-9-]*$ ]] || {
	echo "ERROR: Invalid namespace: $NAMESPACE"
	exit 1
}

WORK_DIR=""
cleanup() { if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi; }
trap cleanup EXIT

# --- Early exit: skip for unprivileged users ---
# Creating SealedSecrets requires kubeadmin (access to kube-system and
# openshift-service-ca namespaces).  When running as a different user
# (e.g., 'developer'), skip gracefully — kubeadmin must have already run
# 'task integration:setup' to create the secrets.
if ! command -v oc &>/dev/null; then
	echo "ERROR: oc not found"
	exit 1
fi
CURRENT_USER="$(oc whoami 2>/dev/null || true)"
if [[ -z "$CURRENT_USER" ]]; then
	echo "ERROR: not logged into the cluster (oc whoami failed)"
	exit 1
fi
if [[ "$CURRENT_USER" != "kubeadmin" && "$CURRENT_USER" != "system:admin" ]]; then
	echo "Skipping sealed-secrets setup (logged in as '$CURRENT_USER', requires kubeadmin)"
	echo "  If secrets don't exist yet, run:  task integration:setup  as kubeadmin first"
	exit 0
fi

# --- Prerequisite checks (only reached as kubeadmin) ---
for cmd in kubeseal openssl; do
	if ! command -v "$cmd" &>/dev/null; then
		echo "ERROR: $cmd not found"
		[[ "$cmd" == "kubeseal" ]] && echo "  Install: task tools:install -- kubeseal"
		exit 1
	fi
done

if ! oc -n kube-system get deployment/sealed-secrets-controller \
	-o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^[1-9]'; then
	echo "ERROR: sealed-secrets-controller not running in kube-system"
	echo "  Install it: task crc:sealed-secrets"
	exit 1
fi

# Ensure the namespace exists
oc new-project "$NAMESPACE" 2>/dev/null || oc project "$NAMESPACE" >/dev/null

CREATED=0
SKIPPED=0

# --- Helper: seal and apply a secret, then wait for decryption ---
seal_and_apply() {
	local name="$1"
	shift

	if oc get secret "$name" -n "$NAMESPACE" &>/dev/null; then
		echo "  $name: already exists — skipping"
		SKIPPED=$((SKIPPED + 1))
		return 0
	fi

	echo "  $name: creating SealedSecret..."
	"$@" -n "$NAMESPACE" --dry-run=client -o yaml |
		kubeseal --controller-namespace kube-system -o yaml |
		oc apply -n "$NAMESPACE" -f -

	for _i in $(seq 1 30); do
		if oc get secret "$name" -n "$NAMESPACE" &>/dev/null; then
			echo "  $name: decrypted and ready"
			CREATED=$((CREATED + 1))
			return 0
		fi
		sleep 2
	done
	echo "ERROR: $name was not decrypted after 60s"
	echo "  Check: oc get sealedsecret $name -n $NAMESPACE -o yaml"
	exit 1
}

echo "Ensuring SealedSecrets in namespace $NAMESPACE..."

# --- 1. aws-creds ---
seal_and_apply aws-creds \
	oc create secret generic aws-creds \
	--from-literal=AWS_ACCESS_KEY_ID=rustfsadmin \
	--from-literal=AWS_SECRET_ACCESS_KEY=rustfsadmin

# --- 2. grafana-oidc-secret ---
seal_and_apply grafana-oidc-secret \
	oc create secret generic grafana-oidc-secret \
	--from-literal=client_secret=not-configured

# --- 3. quay-io-pull-secret ---
seal_and_apply quay-io-pull-secret \
	oc create secret docker-registry quay-io-pull-secret \
	--docker-server=quay.io \
	--docker-username=devlocal \
	--docker-password=not-configured

# --- 4. route-tls-certs (requires cert generation) ---
if oc get secret route-tls-certs -n "$NAMESPACE" &>/dev/null; then
	echo "  route-tls-certs: already exists — skipping"
	SKIPPED=$((SKIPPED + 1))
else
	echo "  route-tls-certs: generating certs from service CA..."
	WORK_DIR=$(mktemp -d)

	# Try to extract the OpenShift service-serving signer CA.
	CA_SECRET="signing-key"
	CA_NS="openshift-service-ca"
	if oc get secret "$CA_SECRET" -n "$CA_NS" &>/dev/null; then
		oc get secret "$CA_SECRET" -n "$CA_NS" -o jsonpath='{.data.tls\.crt}' |
			base64 -d >"$WORK_DIR/ca.crt"
		oc get secret "$CA_SECRET" -n "$CA_NS" -o jsonpath='{.data.tls\.key}' |
			base64 -d >"$WORK_DIR/ca.key"
	else
		echo "  WARNING: service-serving signer not found — generating self-signed CA"
		openssl req -x509 -newkey rsa:2048 -keyout "$WORK_DIR/ca.key" -out "$WORK_DIR/ca.crt" \
			-days 365 -nodes -subj "/CN=complytime-dev-ca" 2>/dev/null
	fi

	# Generate collector cert signed by the CA
	openssl req -newkey rsa:2048 -keyout "$WORK_DIR/collector.key" -out "$WORK_DIR/collector.csr" \
		-nodes -subj "/CN=collector.$NAMESPACE.svc" 2>/dev/null
	openssl x509 -req -in "$WORK_DIR/collector.csr" \
		-CA "$WORK_DIR/ca.crt" -CAkey "$WORK_DIR/ca.key" -CAcreateserial \
		-out "$WORK_DIR/collector.crt" -days 365 \
		-extfile <(printf "subjectAltName=DNS:collector,DNS:collector.%s.svc,DNS:collector.%s.svc.cluster.local" \
			"$NAMESPACE" "$NAMESPACE") 2>/dev/null

	# Generate grafana cert signed by the CA
	openssl req -newkey rsa:2048 -keyout "$WORK_DIR/grafana.key" -out "$WORK_DIR/grafana.csr" \
		-nodes -subj "/CN=grafana.$NAMESPACE.svc" 2>/dev/null
	openssl x509 -req -in "$WORK_DIR/grafana.csr" \
		-CA "$WORK_DIR/ca.crt" -CAkey "$WORK_DIR/ca.key" -CAcreateserial \
		-out "$WORK_DIR/grafana.crt" -days 365 \
		-extfile <(printf "subjectAltName=DNS:grafana,DNS:grafana.%s.svc,DNS:grafana.%s.svc.cluster.local" \
			"$NAMESPACE" "$NAMESPACE") 2>/dev/null

	seal_and_apply route-tls-certs \
		oc create secret generic route-tls-certs \
		--from-file=collector.crt="$WORK_DIR/collector.crt" \
		--from-file=collector.key="$WORK_DIR/collector.key" \
		--from-file=grafana.crt="$WORK_DIR/grafana.crt" \
		--from-file=grafana.key="$WORK_DIR/grafana.key" \
		--from-file=ca-chain.crt="$WORK_DIR/ca.crt"
fi

# --- 5. collector-env ConfigMap (plain ConfigMap, not a SealedSecret) ---
# Stage/production overlays reference this ConfigMap via configMapKeyRef for
# OIDC_ISSUER_URL and S3_ENDPOINT.  For local CRC testing, use dev values
# that match the local overlay conventions (RustFS for S3, no real OIDC).
if oc get configmap collector-env -n "$NAMESPACE" &>/dev/null; then
	echo "  collector-env: already exists — skipping"
	SKIPPED=$((SKIPPED + 1))
else
	echo "  collector-env: creating ConfigMap with dev values..."
	oc create configmap collector-env \
		--from-literal=OIDC_ISSUER_URL="https://not-configured.example.com/realms/complytime" \
		--from-literal=S3_ENDPOINT="http://rustfs:9000" \
		-n "$NAMESPACE"
	echo "  collector-env: created"
	CREATED=$((CREATED + 1))
fi

# --- 6. grafana-env ConfigMap (plain ConfigMap, not a SealedSecret) ---
# Stage/production overlays reference this ConfigMap via configMapKeyRef for
# Grafana OIDC env vars and root URL.  For local CRC testing, use dev
# placeholder values (Grafana uses anonymous auth locally, so these don't
# matter functionally).
if oc get configmap grafana-env -n "$NAMESPACE" &>/dev/null; then
	echo "  grafana-env: already exists — skipping"
	SKIPPED=$((SKIPPED + 1))
else
	echo "  grafana-env: creating ConfigMap with dev values..."
	oc create configmap grafana-env \
		--from-literal=GF_AUTH_GENERIC_OAUTH_ENABLED="false" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID="not-configured" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_AUTH_URL="https://not-configured.example.com/auth" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_TOKEN_URL="https://not-configured.example.com/token" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_API_URL="https://not-configured.example.com/userinfo" \
		--from-literal=GF_AUTH_SIGNOUT_REDIRECT_URL="https://not-configured.example.com/logout" \
		--from-literal=GF_SERVER_ROOT_URL="https://grafana-dev.example.com" \
		-n "$NAMESPACE"
	echo "  grafana-env: created"
	CREATED=$((CREATED + 1))
fi

# --- 7. grafana-admin-secret ---
# Admin password for non-local environments.  For local dev, use the
# Grafana default (admin/admin) — sealed so it exists for overlays that
# reference it with optional: true.
seal_and_apply grafana-admin-secret \
	oc create secret generic grafana-admin-secret \
	--from-literal=admin_password=admin

echo ""
echo "SealedSecrets/ConfigMaps: $CREATED created, $SKIPPED already existed"
