# SealedSecrets — Production

This directory holds SealedSecret resources for the production environment. SealedSecrets are encrypted Kubernetes Secrets that are safe to commit to git. The SealedSecrets controller on the cluster decrypts them into regular Secrets at deploy time.

## Prerequisites

1. **SealedSecrets controller** installed on the target cluster:
   ```bash
   oc apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
   ```

2. **kubeseal CLI** installed locally:
   ```bash
   brew install kubeseal   # macOS
   # or download from https://github.com/bitnami-labs/sealed-secrets/releases
   ```

## Required Secrets

### aws-creds — S3 evidence export credentials

```bash
oc create secret generic aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
  -n complytime-prod \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml \
  > aws-creds.yaml
```

### grafana-oidc-secret — Grafana OIDC client secret

```bash
oc create secret generic grafana-oidc-secret \
  --from-literal=client_secret=<your-oidc-client-secret> \
  -n complytime-prod \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml \
  > grafana-oidc-secret.yaml
```

### quay-io-pull-secret — Private image registry credentials

```bash
oc create secret docker-registry quay-io-pull-secret \
  --docker-server=quay.io \
  --docker-username=<username> \
  --docker-password=<token> \
  -n complytime-prod \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml \
  > quay-io-pull-secret.yaml
```

### route-tls-certs — TLS certificates for external Routes

```bash
oc create secret generic route-tls-certs \
  --from-file=collector.crt=<path-to-collector-cert> \
  --from-file=collector.key=<path-to-collector-key> \
  --from-file=grafana.crt=<path-to-grafana-cert> \
  --from-file=grafana.key=<path-to-grafana-key> \
  --from-file=ca-chain.crt=<path-to-ca-chain> \
  -n complytime-prod \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml \
  > route-tls-certs.yaml
```

### grafana-admin-secret — Grafana admin password

```bash
oc create secret generic grafana-admin-secret \
  --from-literal=admin_password=<your-admin-password> \
  -n complytime-prod \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml \
  > grafana-admin-secret.yaml
```

## Usage

Sealed-secret files in this directory are applied automatically by
Skaffold's **pre-deploy hook**, which runs
`./scripts/apply-sealed-secrets.sh production` before each deployment. You
do not need to add them to `kustomization.yaml`.

To deploy: `task sk:run -- production`

Skaffold's post-deploy hook then patches Routes with TLS certs from the
`route-tls-certs` Secret.

## Re-sealing

SealedSecrets are encrypted with the controller's public key. If the controller is rotated or you switch clusters, re-seal all secrets:

```bash
for f in *.yaml; do
  kubeseal --recovery-unseal < "$f" \
    | kubeseal --controller-namespace kube-system -o yaml \
    > "$f.new" && mv "$f.new" "$f"
done
```
