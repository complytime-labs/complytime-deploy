#!/bin/bash
set -euo pipefail

# ensure-sealed-secrets.sh — Create SealedSecrets with dev values for local CRC testing.
# Usage: ensure-sealed-secrets.sh <namespace>
#
# For each of the 4 required secrets (aws-creds, grafana-oidc-secret,
# quay-io-pull-secret, route-tls-certs), this script:
#   1. Checks if the secret already exists — skips if so
#   2. Creates a plaintext secret (dry-run)
#   3. Pipes through kubeseal to encrypt
#   4. Applies the SealedSecret to the cluster
#   5. Waits for the controller to decrypt it
#
# Prerequisites:
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

# --- Prerequisite checks ---
for cmd in oc kubeseal openssl; do
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

echo ""
echo "SealedSecrets: $CREATED created, $SKIPPED already existed"
