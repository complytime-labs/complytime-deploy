#!/bin/bash
set -euo pipefail

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

SEALED_DIR="$REPO_ROOT/overlays/$OVERLAY/sealed-secrets"

if ! ls "$SEALED_DIR"/*.yaml &>/dev/null 2>&1; then
	exit 0
fi

echo "Applying SealedSecrets from overlays/$OVERLAY/sealed-secrets/..."
for f in "$SEALED_DIR"/*.yaml; do
	echo "  $(basename "$f")"
	oc apply -f "$f" -n "$NAMESPACE"
done
