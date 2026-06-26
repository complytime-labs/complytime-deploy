#!/bin/bash
set -euo pipefail
set +x # Never trace — variable expansions would leak secrets to stderr

# apply-sealed-secrets.sh — Ensure required secrets exist before deployment.
#
# Two modes of operation:
#   1. CI mode:  When CI environment variables are set (AWS_ACCESS_KEY_ID, etc.),
#                creates/updates secrets directly from those variables.
#   2. Fallback: When CI variables are absent, applies SealedSecret YAML files
#                from overlays/<overlay>/sealed-secrets/ (original behavior).
#
# Usage: apply-sealed-secrets.sh <overlay> [namespace-override]

OVERLAY="${1:?Usage: $0 <overlay> [namespace-override] (e.g., stage, production)}"
[[ "$OVERLAY" =~ ^[a-z-]+$ ]] || {
	echo "ERROR: Invalid overlay name: $OVERLAY"
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${2:-}" ]]; then
	NAMESPACE="$2"
else
	NAMESPACE=$(grep '^namespace:' "$REPO_ROOT/overlays/$OVERLAY/kustomization.yaml" | awk '{print $2}')
	if [[ -z "$NAMESPACE" ]]; then
		echo "ERROR: Could not extract namespace from overlays/$OVERLAY/kustomization.yaml"
		exit 1
	fi
fi

# Validate namespace — must be a valid Kubernetes name (RFC 1123 DNS label)
[[ "$NAMESPACE" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] || {
	echo "ERROR: Invalid namespace: $NAMESPACE"
	exit 1
}

CREATED=0
UPDATED=0
SKIPPED=0

# --- Helper: create or update a secret idempotently ---
# Uses dry-run + apply so the secret is created if missing or updated if changed.
# Output is suppressed to prevent base64-encoded secret values from leaking into
# CI job logs.
apply_secret() {
	local name="$1"
	shift

	if oc get secret "$name" -n "$NAMESPACE" &>/dev/null; then
		echo "  $name: exists — updating"
		"$@" -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f - >/dev/null
		UPDATED=$((UPDATED + 1))
	else
		echo "  $name: creating"
		"$@" -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f - >/dev/null
		CREATED=$((CREATED + 1))
	fi
}

# --- Helper: create or update a ConfigMap idempotently ---
apply_configmap() {
	local name="$1"
	shift

	if oc get configmap "$name" -n "$NAMESPACE" &>/dev/null; then
		echo "  $name: exists — updating"
		"$@" -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
		UPDATED=$((UPDATED + 1))
	else
		echo "  $name: creating"
		"$@" -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
		CREATED=$((CREATED + 1))
	fi
}

# --- CI mode: create secrets from environment variables ---
if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
	echo "Creating secrets from CI variables for $OVERLAY (namespace: $NAMESPACE)..."

	# aws-creds
	apply_secret aws-creds \
		oc create secret generic aws-creds \
		--from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
		--from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"

	# collector-env (required — OIDC_ISSUER_URL and S3_ENDPOINT must be set)
	if [[ -z "${OIDC_ISSUER_URL:-}" ]]; then
		echo "ERROR: OIDC_ISSUER_URL is not set — the collector OIDC extension requires a valid issuer URL."
		echo "  Set OIDC_ISSUER_URL in GitLab CI variables (Settings > CI/CD > Variables)."
		exit 1
	fi
	if [[ -z "${S3_ENDPOINT:-}" ]]; then
		echo "ERROR: S3_ENDPOINT is not set — the collector S3 exporter requires an endpoint URL."
		echo "  Set S3_ENDPOINT in GitLab CI variables (Settings > CI/CD > Variables)."
		exit 1
	fi
	apply_configmap collector-env \
		oc create configmap collector-env \
		--from-literal=OIDC_ISSUER_URL="$OIDC_ISSUER_URL" \
		--from-literal=S3_ENDPOINT="$S3_ENDPOINT"

	# grafana-env (always created — OIDC is enabled only when client ID is set)
	# These use Grafana's native GF_* env var names.
	# See: https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
	#
	# SSO client setup checklist (Keycloak / Red Hat SSO):
	#   1. Create a client with Client ID matching GF_AUTH_GENERIC_OAUTH_CLIENT_ID
	#   2. Set Access Type to "confidential"
	#   3. Add valid redirect URIs:
	#        - <GF_SERVER_ROOT_URL>/login/generic_oauth  (login callback)
	#      Add post-logout redirect URIs (Keycloak: client > Advanced > postLogoutRedirectUris):
	#        - <GF_SERVER_ROOT_URL>
	#   4. Set client secret → store as GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET CI var
	#   5. Set GF_SERVER_ROOT_URL to the exact public Grafana URL (with https://)
	#      This must match the redirect URI sent to the SSO provider.
	#
	# Common error: "Invalid parameter: redirect_uri"
	#   → The redirect URI Grafana sends (<root_url>/login/generic_oauth)
	#     is not in the SSO client's valid redirect URIs list.
	if [[ -n "${GF_AUTH_GENERIC_OAUTH_CLIENT_ID:-}" ]]; then
		GRAFANA_OAUTH_ENABLED="true"
		GRAFANA_ENV_WARNINGS=""
		for gf_var in GF_AUTH_GENERIC_OAUTH_AUTH_URL GF_AUTH_GENERIC_OAUTH_TOKEN_URL \
			GF_AUTH_GENERIC_OAUTH_API_URL GF_AUTH_SIGNOUT_REDIRECT_URL; do
			if [[ -z "${!gf_var:-}" ]]; then
				GRAFANA_ENV_WARNINGS="${GRAFANA_ENV_WARNINGS}  WARNING: $gf_var is not set — Grafana OIDC may not work correctly.\n"
			fi
		done
		if [[ -z "${GF_SERVER_ROOT_URL:-}" ]]; then
			GRAFANA_ENV_WARNINGS="${GRAFANA_ENV_WARNINGS}  INFO: GF_SERVER_ROOT_URL not set — will be auto-derived from Route hostname in post-deploy.\n"
		fi
		if [[ -n "$GRAFANA_ENV_WARNINGS" ]]; then
			printf '%b' "$GRAFANA_ENV_WARNINGS"
		fi
	else
		GRAFANA_OAUTH_ENABLED="false"
		echo "  GF_AUTH_GENERIC_OAUTH_CLIENT_ID not set — OIDC disabled"
	fi
	# GF_AUTH_SIGNOUT_REDIRECT_URL format for Keycloak/RHSSO:
	#   https://<sso-host>/realms/<realm>/protocol/openid-connect/logout?post_logout_redirect_uri=<url-encoded-grafana-root-url>
	# The post_logout_redirect_uri value must be registered in the SSO
	# client's postLogoutRedirectUris (Keycloak: client > Advanced).
	apply_configmap grafana-env \
		oc create configmap grafana-env \
		--from-literal=GF_AUTH_GENERIC_OAUTH_ENABLED="$GRAFANA_OAUTH_ENABLED" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID="${GF_AUTH_GENERIC_OAUTH_CLIENT_ID:-}" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_AUTH_URL="${GF_AUTH_GENERIC_OAUTH_AUTH_URL:-}" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_TOKEN_URL="${GF_AUTH_GENERIC_OAUTH_TOKEN_URL:-}" \
		--from-literal=GF_AUTH_GENERIC_OAUTH_API_URL="${GF_AUTH_GENERIC_OAUTH_API_URL:-}" \
		--from-literal=GF_AUTH_SIGNOUT_REDIRECT_URL="${GF_AUTH_SIGNOUT_REDIRECT_URL:-}" \
		--from-literal=GF_SERVER_ROOT_URL="${GF_SERVER_ROOT_URL:-}"

	# grafana-admin-secret (required — do not deploy with default admin:admin)
	if [[ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ]]; then
		echo "ERROR: GF_SECURITY_ADMIN_PASSWORD is not set — refusing to deploy Grafana with default admin credentials."
		echo "  Set GF_SECURITY_ADMIN_PASSWORD in GitLab CI variables (Settings > CI/CD > Variables)."
		exit 1
	fi
	apply_secret grafana-admin-secret \
		oc create secret generic grafana-admin-secret \
		--from-literal=admin_password="$GF_SECURITY_ADMIN_PASSWORD"

	# grafana-oidc-secret (optional — only if GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET is set)
	if [[ -n "${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:-}" ]]; then
		apply_secret grafana-oidc-secret \
			oc create secret generic grafana-oidc-secret \
			--from-literal=client_secret="$GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
	else
		echo "  grafana-oidc-secret: GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET not set — skipping"
		SKIPPED=$((SKIPPED + 1))
	fi

	# quay-io-pull-secret (optional — only if QUAY_DOCKER_CONFIG_JSON is set)
	if [[ -n "${QUAY_DOCKER_CONFIG_JSON:-}" ]]; then
		# Validate JSON before writing to disk
		if ! printf '%s' "$QUAY_DOCKER_CONFIG_JSON" | jq empty 2>/dev/null; then
			echo "ERROR: QUAY_DOCKER_CONFIG_JSON is not valid JSON"
			exit 1
		fi

		TMPFILE=$(mktemp)
		trap 'rm -f "$TMPFILE"' EXIT
		chmod 600 "$TMPFILE"
		printf '%s' "$QUAY_DOCKER_CONFIG_JSON" >"$TMPFILE"

		apply_secret quay-io-pull-secret \
			oc create secret generic quay-io-pull-secret \
			--type=kubernetes.io/dockerconfigjson \
			--from-file=.dockerconfigjson="$TMPFILE"

		rm -f "$TMPFILE"
		trap - EXIT
	else
		echo "  quay-io-pull-secret: QUAY_DOCKER_CONFIG_JSON not set — skipping"
		SKIPPED=$((SKIPPED + 1))
	fi

	# route-tls-certs (optional — only if ROUTE_TLS_COLLECTOR_CRT is set)
	# All 5 variables must be base64-encoded PEM content.
	# Encode with: base64 -w0 < collector.crt
	if [[ -n "${ROUTE_TLS_COLLECTOR_CRT:-}" ]]; then
		CERT_DIR=$(mktemp -d)
		trap 'rm -rf "$CERT_DIR"' EXIT
		chmod 700 "$CERT_DIR"

		for var_pair in \
			"ROUTE_TLS_COLLECTOR_CRT:collector.crt" \
			"ROUTE_TLS_COLLECTOR_KEY:collector.key" \
			"ROUTE_TLS_GRAFANA_CRT:grafana.crt" \
			"ROUTE_TLS_GRAFANA_KEY:grafana.key" \
			"ROUTE_TLS_CA_CHAIN:ca-chain.crt"; do
			var_name="${var_pair%%:*}"
			file_name="${var_pair##*:}"
			var_value="${!var_name:-}"
			if [[ -z "$var_value" ]]; then
				echo "ERROR: $var_name is not set (all 5 ROUTE_TLS_* variables are required together)"
				exit 1
			fi
			printf '%s' "$var_value" | base64 -d >"$CERT_DIR/$file_name" 2>/dev/null || {
				echo "ERROR: $var_name is not valid base64"
				exit 1
			}
		done

		apply_secret route-tls-certs \
			oc create secret generic route-tls-certs \
			--from-file=collector.crt="$CERT_DIR/collector.crt" \
			--from-file=collector.key="$CERT_DIR/collector.key" \
			--from-file=grafana.crt="$CERT_DIR/grafana.crt" \
			--from-file=grafana.key="$CERT_DIR/grafana.key" \
			--from-file=ca-chain.crt="$CERT_DIR/ca-chain.crt"

		rm -rf "$CERT_DIR"
		trap - EXIT
	else
		echo "  route-tls-certs: ROUTE_TLS_COLLECTOR_CRT not set — skipping (Routes will use default OpenShift certs)"
		SKIPPED=$((SKIPPED + 1))
	fi

	echo ""
	echo "Secrets/ConfigMaps from CI variables: $CREATED created, $UPDATED updated, $SKIPPED skipped"
	exit 0
fi

# --- Fallback: apply SealedSecret YAML files (original behavior) ---
SEALED_DIR="$REPO_ROOT/overlays/$OVERLAY/sealed-secrets"

if ! ls "$SEALED_DIR"/*.yaml &>/dev/null 2>&1; then
	exit 0
fi

echo "Applying SealedSecrets from overlays/$OVERLAY/sealed-secrets/..."
for f in "$SEALED_DIR"/*.yaml; do
	echo "  $(basename "$f")"
	oc apply -f "$f" -n "$NAMESPACE"
done
