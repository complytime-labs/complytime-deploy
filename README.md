# ComplyTime


----

> 🤖 LLM WARNING 🤖
>
> This material was written with LLM (AI) assistance.
>
> 🤖 LLM WARNING 🤖

----

ComplyTime is a compliance monitoring and observability platform that collects, processes, and visualizes compliance data from various sources.

The system consists of:
- **Collector**: OpenTelemetry collector — receives compliance data via webhook and OTLP, and exports to Loki and S3
- **Loki**: Log aggregation — stores compliance evaluation logs with indexed attributes for querying
- **Grafana**: Dashboard UI — visualizes compliance data from Loki
- **RustFS**: S3-compatible object storage (local only) — stores compliance evidence for local development

## Architecture

```
  External Clients              Browser
       |                           |
       | webhook/OTLP              | HTTPS
       v                           v
  +----------+
  |Collector |
  | (Route)  |
  +----+-----+
       |
       | OTLP/HTTPS
       v
  +----------+
  |   Loki   |<--- Grafana (Route)
  |(internal)|     queries logs
  +----------+
       |
       v
  +----------+
  |    S3    |  Production: AWS S3
  | evidence |  Local: RustFS (Apache 2.0)
  +----------+
```

**Data flow:** External clients send compliance data to Collector via webhook (OIDC-authenticated) or OTLP. Collector transforms them to OCSF format, generates metrics, and exports to Loki (for querying) and S3 (for evidence storage). Grafana queries Loki for dashboard visualization.

## Prerequisites

### Tools

| Tool        | Purpose                                        | Install                                                                                                                                                   |
|-------------|------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `crc`       | OpenShift Local cluster                        | [Download](https://developers.redhat.com/products/openshift-local) (free Red Hat account) — see [Installing OpenShift Local](#installing-openshift-local) |
| `oc`        | OpenShift CLI                                  | Bundled with `crc` — run `eval $(crc oc-env)` to add to PATH                                                                                              |
| `task`      | Task runner                                    | [taskfile.dev/installation](https://taskfile.dev/installation/)                                                                                           |
| `skaffold`  | Deploy lifecycle manager                       | [skaffold.dev/docs/install](https://skaffold.dev/docs/install/)                                                                                           |
| `kustomize` | Manifest renderer (used by Skaffold)           | [kubectl.docs.kubernetes.io](https://kubectl.docs.kubernetes.io/installation/kustomize/)                                                                  |
| `kubectl`   | Kubernetes CLI (symlink `oc` if not installed) | `ln -sf $(which oc) /usr/local/bin/kubectl`                                                                                                               |
| `kubeseal`  | Encrypt secrets for git (stage/production)     | [SealedSecrets releases](https://github.com/bitnami-labs/sealed-secrets/releases)                                                                         |
| `podman`    | Local deployment (Quadlet)                     | [podman.io/docs/installation](https://podman.io/docs/installation) — requires >= 4.4                                                                      |

### OpenShift Cluster Requirements

The target cluster must have:

- **Service CA operator** — auto-generates TLS certificates for internal services. The `serving-cert-secret-name` annotation on each Service triggers automatic TLS secret creation (`collector-tls`, `loki-tls`, `grafana-tls`). The `inject-cabundle` annotation on the `service-ca-bundle` ConfigMap populates it with the cluster CA certificate. No manual TLS setup is needed for internal communication.
- **Persistent volume provisioner** — Loki and Grafana require PersistentVolumeClaims. Production uses AWS EFS (`ReadWriteMany`). OpenShift Local provides default storage automatically.
- **Route support** — Collector and Grafana are exposed externally via OpenShift Routes.
- **SealedSecrets controller** (stage/production only) — decrypts committed SealedSecrets into Kubernetes Secrets on-cluster:
  ```bash
  task crc:sealed-secrets   # installs controller and waits for rollout
  ```

### Secrets

Pods will fail to start if required secrets are missing. The table below lists every secret the deployments reference.

| Secret                | Keys                                                                           | Required By    | How to Create                                    |
|-----------------------|--------------------------------------------------------------------------------|----------------|--------------------------------------------------|
| `aws-creds`           | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`                                   | Collector      | GitLab CI variable or SealedSecret               |
| `collector-tls`       | `tls.crt`, `tls.key`                                                           | Collector      | Auto-generated by Service CA                     |
| `loki-tls`            | `tls.crt`, `tls.key`                                                           | Loki           | Auto-generated by Service CA                     |
| `grafana-tls`         | `tls.crt`, `tls.key`                                                           | Grafana        | Auto-generated by Service CA                     |
| `grafana-oidc-secret` | `client_secret`                                                                | Grafana (OIDC) | SealedSecret (stage/production only)             |
| `quay-io-pull-secret` | `.dockerconfigjson`                                                            | Collector      | GitLab CI variable or SealedSecret               |

For **local development**, secrets (TLS) are auto-generated by OpenShift Service CA.

For **stage/production**, secrets can be managed two ways:

1. **GitLab CI variables (recommended)** — the deploy script creates secrets from environment variables injected by GitLab. See [GitLab CI Secret Management](#gitlab-ci-secret-management) below.
2. **SealedSecrets** — encrypted secret YAML files committed to git. See `overlays/<env>/sealed-secrets/README.md`. Requires a SealedSecrets controller on the cluster.

The pre-deploy script (`scripts/apply-sealed-secrets.sh`) detects which mode to use automatically: if `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set as environment variables, it creates secrets directly; otherwise it falls back to applying SealedSecret YAML files.

#### GitLab CI Secret Management

The GitLab CI pipeline uses **environment-scoped variables** to inject different secret values per deployment target. Each deploy job declares an `environment:` (`stage` or `production`), and GitLab resolves variables scoped to that environment.

**Required CI variables** (Settings > CI/CD > Variables):

| Variable                 | Environment Scope | Type     | Protected | Masked | Purpose                          |
|--------------------------|-------------------|----------|-----------|--------|----------------------------------|
| `OPENSHIFT_SERVER`       | `stage`           | Variable | Yes       | No     | Stage cluster API URL            |
| `OPENSHIFT_TOKEN`        | `stage`           | Variable | Yes       | Yes    | Stage deployer SA token          |
| `OPENSHIFT_SERVER`       | `production`      | Variable | Yes       | No     | Production cluster API URL       |
| `OPENSHIFT_TOKEN`        | `production`      | Variable | Yes       | Yes    | Production deployer SA token     |
| `AWS_ACCESS_KEY_ID`      | `stage`           | Variable | Yes       | No     | AWS key for stage S3 bucket      |
| `AWS_SECRET_ACCESS_KEY`  | `stage`           | Variable | Yes       | Yes    | AWS secret for stage S3 bucket   |
| `AWS_ACCESS_KEY_ID`      | `production`      | Variable | Yes       | No     | AWS key for prod S3 bucket       |
| `AWS_SECRET_ACCESS_KEY`  | `production`      | Variable | Yes       | Yes    | AWS secret for prod S3 bucket    |
| `QUAY_DOCKER_CONFIG_JSON`| `stage`           | Variable | Yes       | Yes    | Quay pull secret JSON (stage)    |
| `QUAY_DOCKER_CONFIG_JSON`| `production`      | Variable | Yes       | Yes    | Quay pull secret JSON (prod)     |

**Security hardening:**

- **Protected variables** — only injected on protected branches (typically `main`), preventing secret exposure from feature branch pipelines.
- **Masked variables** — GitLab redacts the literal value from job logs. The deploy script additionally suppresses `oc apply` output to prevent base64-encoded values from bypassing the mask.
- **Environment scoping** — stage credentials are never available to production jobs, and vice versa. GitLab enforces this at the variable resolution layer.
- **No trace mode** — the deploy script explicitly disables bash tracing (`set +x`) to prevent variable expansions from leaking to stderr.

### Environment Variables

The Collector config uses OTel `${env:VAR}` substitution. These environment variables are set in the Collector deployment and patched per overlay:

| Variable          | Purpose                                  | Base Default                        |
|-------------------|------------------------------------------|-------------------------------------|
| `OIDC_ISSUER_URL` | OIDC provider for webhook authentication | `""` (empty — overlay must provide) |
| `AWS_REGION`      | AWS region for S3 export                 | `""` (empty — overlay must provide) |
| `S3_BUCKETNAME`   | S3 bucket for evidence storage           | `""` (empty — overlay must provide) |
| `S3_OBJ_DIR`      | S3 key prefix for evidence files         | `""` (empty — overlay must provide) |

## Quick Start — OpenShift Local (CRC)

### Installing OpenShift Local

OpenShift Local (CRC) runs a single-node OpenShift cluster on your laptop.

**System requirements:** 9 GB RAM (16 GB recommended), 60 GB disk (SSD required), 4 CPU cores

1. **Download** from <https://developers.redhat.com/products/openshift-local> (free Red Hat Developer account required). Save your pull secret.

2. **Install:**
   ```bash
   # Linux/macOS
   tar -xvf crc-linux-amd64.tar.xz
   sudo mv crc-linux-*/crc /usr/local/bin/

   # macOS (Homebrew)
   brew install crc
   ```

3. **Setup and start:**
   ```bash
   task crc:setup         # Downloads ~3GB bundle, configures 6 CPUs / 16 GiB RAM
   task crc:start         # Start cluster (5-10 min, paste pull secret when prompted)
   eval $(crc oc-env)     # Add oc to PATH (add to ~/.bashrc to persist)
   ```

4. **Login and deploy:**
   ```bash
   task crc:login         # Opens browser for cluster authentication
   task sk:dev            # continuous dev loop (port-forward, log-tail, cleanup on Ctrl+C)
   # or: task sk:run      # one-shot deploy without dev loop
   ```

5. **Access services:**
   - Collector: <https://collector.apps-crc.testing>
   - Grafana: <https://grafana.apps-crc.testing> (anonymous access, no login)
   - RustFS console: <http://localhost:9000> (rustfsadmin/rustfsadmin)

   Browser will show a self-signed certificate warning — this is expected.

### CRC Lifecycle

```bash
task crc:stop              # Stop cluster (preserves data)
task crc:start             # Restart (no redeploy needed, just login again)
task crc:delete            # Delete cluster and all data
crc cleanup                # Reclaim disk space after delete
```

### CRC Troubleshooting

```bash
# Pods not starting
oc get events -n complytime-dev --sort-by='.lastTimestamp'
oc describe pod <pod-name> -n complytime-dev

# Image pull failures (private Quay images)
oc create secret docker-registry quay-io-pull-secret \
  --docker-server=quay.io \
  --docker-username=<username> \
  --docker-password=<token> \
  -n complytime-dev
oc secrets link default quay-io-pull-secret --for=pull -n complytime-dev

# Service CA certificates missing
oc get pods -n openshift-service-ca     # Verify operator is running
oc delete service <name> -n complytime-dev && oc apply -k overlays/local

# CRC won't start
crc delete && crc setup && crc start
```

## Deployment

### Kustomize Overlays

Each environment has an overlay directory (`overlays/<env>/`) that customizes the base manifests. The base contains the full production configuration; overlays patch what differs.

| Overlay      | Namespace          | Auth                        | Debug    | Secrets                       |
|--------------|--------------------|-----------------------------|----------|-------------------------------|
| `local`      | `complytime-dev`   | Disabled (anonymous/no JWT) | Enabled  | Auto-created by deploy script |
| `stage`      | `complytime-stage` | OIDC + JWT                  | Enabled  | SealedSecrets                 |
| `production` | `complytime-prod`  | OIDC + JWT                  | Disabled | SealedSecrets                 |

### Deploying

```bash
# Login to the target cluster
oc login --web --server=<cluster-api-url>

# Local development (continuous loop with port-forwarding)
task sk:dev

# One-shot deploy to any environment
task sk:run                  # local
task sk:run -- stage         # stage
task sk:run -- production    # production
```

### Custom Namespace Deployment

Deploy the local (or any) overlay configuration to a different OpenShift namespace for testing:

```bash
# Deploy local config to a custom namespace
task sk:run NAMESPACE=my-test

# Deploy stage config to a custom namespace
task sk:run NAMESPACE=my-test BASE=stage

# Render manifests for a custom namespace (preview without deploying)
task sk:render NAMESPACE=my-test

# Tear down custom deployment and clean up generated overlay
task sk:delete NAMESPACE=my-test
```

This generates a thin Kustomize overlay at `overlays/custom-<NAMESPACE>/` that inherits from the base overlay (default: `local`) and overrides only the namespace. The generated overlay is gitignored and cleaned up by `sk:delete`.

**Notes:**
- Custom deploys generate a per-namespace Skaffold config that runs the full pipeline (sealed-secrets, post-deploy hooks, status checking)
- `NAMESPACE` and profile selection (`-- stage`) are mutually exclusive
- `sk:dev` does not support `NAMESPACE` — use `sk:run` for custom namespace deploys

For stage/production, you must first:
1. Configure secrets — either set GitLab CI variables (see [GitLab CI Secret Management](#gitlab-ci-secret-management)) or install the SealedSecrets controller and create SealedSecrets in `overlays/<env>/sealed-secrets/`
2. Set OIDC URLs in `overlays/<env>/patches/collector-env.yaml` and `grafana-env.yaml`

### Switching Environments

Skaffold profiles handle environment-specific configuration. For stage and production, set the required environment variables before deploying:

```bash
# Stage
export OPENSHIFT_SERVER=https://api.stage-cluster.example.com
export OPENSHIFT_TOKEN=<token>
task sk:run -- stage

# Production
export OPENSHIFT_SERVER=https://api.prod-cluster.example.com
export OPENSHIFT_TOKEN=<token>
task sk:run -- production
```

Skaffold handles login, namespace creation, SealedSecrets application, manifest deployment, Route TLS cert injection, and Grafana datasource CA cert injection via deploy hooks.

### Podman Quadlet (No OpenShift Required)

Run ComplyTime locally using rootless Podman with systemctl --user. No OpenShift or CRC needed — just Podman 4.4+ on Linux.

**Requirements:** Podman 4.4+, systemctl --user, openssl (for TLS mode)

```bash
# Setup (generates self-signed TLS certs, installs quadlet units)
task quadlet:setup

# Use a local collector image instead of the default (quay.io/complytime/beacon-collector:latest)
COLLECTOR_IMAGE=localhost/complybeacon/collector:latest task quadlet:setup

# Or without TLS for debugging
task quadlet:setup -- --no-tls

# Start/stop/status
task quadlet:start
task quadlet:status
task quadlet:logs -- collector

# Access services
#   Grafana:   https://localhost:3000 (or http:// with --no-tls)
#   Collector: https://localhost:4318
#   RustFS:    http://localhost:9001 (rustfsadmin/rustfsadmin)

# Full cleanup
task quadlet:teardown
```

See [Quadlet README](quadlet/README.md) for detailed setup and troubleshooting.

## Migrating from Ansible

If you are currently deploying with the Ansible playbook, this section maps every Ansible variable to its Kustomize equivalent.

### How Configuration Works Differently

| Concept                | Ansible                                             | Kustomize                                                                     |
|------------------------|-----------------------------------------------------|-------------------------------------------------------------------------------|
| Per-environment config | `group_vars/stage.yml`, `group_vars/production.yml` | Overlay directories: `overlays/stage/`, `overlays/production/`                |
| Variable injection     | Jinja2 templates: `{{ variable }}`                  | OTel env substitution: `${env:VAR}`, Kustomize patches, or overlay ConfigMaps |
| Secrets                | Ansible Vault + `oc create secret` in tasks         | GitLab CI variables (recommended) or SealedSecrets                            |
| Conditional resources  | `{% if deploy_loki %}`                              | Include/exclude resources in overlay `kustomization.yaml`                     |
| TLS certificates       | Vault-encrypted cert files, injected into Routes    | SealedSecrets for Route certs, OpenShift Service CA for internal certs        |

### Variable Mapping Reference

#### Images

| Ansible Variable  | Ansible Default                            | Kustomize Location               | How to Change                         |
|-------------------|--------------------------------------------|----------------------------------|---------------------------------------|
| `collector_image` | `quay.io/complytime/beacon-collector:test` | `base/collector/deployment.yaml` | Overlay patch (`patches/images.yaml`) |
| `loki_image`      | `docker.io/grafana/loki:3.5.1`             | `base/loki/deployment.yaml`      | Overlay patch                         |
| `grafana_image`   | `grafana/grafana:11.6.0`                   | `base/grafana/deployment.yaml`   | Overlay patch                         |

#### Namespace and Cluster

| Ansible Variable     | Kustomize Equivalent                         | Notes                               |
|----------------------|----------------------------------------------|-------------------------------------|
| `target_namespace`   | `namespace:` in overlay `kustomization.yaml` | Each overlay sets its own namespace |
| `OPENSHIFT_SERVER`/`OPENSHIFT_TOKEN` | GitLab CI variable (environment-scoped) or `oc login` | Authenticate before deploying |

#### AWS S3

| Ansible Variable        | Ansible Default                   | Kustomize Env Var | Set In                                                   |
|-------------------------|-----------------------------------|-------------------|----------------------------------------------------------|
| `s3_bucketname`         | `sw-s3-hyperproof`                | `S3_BUCKETNAME`   | `base/collector/deployment.yaml`, patched per overlay    |
| `s3_obj_dir`            | Stage: `test`, Prod: `production` | `S3_OBJ_DIR`      | `base/collector/deployment.yaml`, patched per overlay    |
| `aws_region`            | `us-east-2`                       | `AWS_REGION`      | `base/collector/deployment.yaml`, patched per overlay    |
| `AWS_ACCESS_KEY_ID`     | K8s secret `aws-creds`            | Same              | GitLab CI variable (per environment) or SealedSecret |
| `AWS_SECRET_ACCESS_KEY` | K8s secret `aws-creds`            | Same              | GitLab CI variable (per environment) or SealedSecret |

#### Hostnames and Routes

| Ansible Variable     | Ansible Default  | Kustomize Location           | Notes                                                                     |
|----------------------|------------------|------------------------------|---------------------------------------------------------------------------|
| `grafana_hostname`   | Required per env | `overlays/<env>/routes.yaml` | No longer needed — Routes omit `spec.host`, OpenShift auto-generates URLs |
| `collector_hostname` | Required per env | `overlays/<env>/routes.yaml` | Same                                                                      |

#### Authentication

| Ansible Variable             | Ansible Default  | Kustomize Location                                                 | Notes                                                                |
|------------------------------|------------------|--------------------------------------------------------------------|----------------------------------------------------------------------|
| `grafana_oidc_enabled`       | `true`           | `overlays/<env>/patches/grafana-env.yaml`                          | Base has no OIDC; stage/production overlays add OIDC env vars        |
| `grafana_oidc_client_id`     | Required         | Overlay patch env var                                              | Stage/production overlays set `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`      |
| `GRAFANA_OIDC_CLIENT_SECRET` | K8s secret       | SealedSecret `grafana-oidc-secret`                                 | See `sealed-secrets/README.md`                                       |
| `oidc_issuer_url`            | Required per env | `OIDC_ISSUER_URL` env var on Collector, plus Grafana OIDC env vars | Set in overlay deployment patches                                    |
| `grafana_anonymous_enabled`  | `false`          | `base/grafana/deployment.yaml`                                     | Base: `false`. Local overlay enables via `patches/grafana-auth.yaml` |

#### Logging

| Ansible Variable                   | Ansible Default              | Kustomize Location                                      | How to Change                                                        |
|------------------------------------|------------------------------|---------------------------------------------------------|----------------------------------------------------------------------|
| `collector_log_level`              | Stage: `debug`, Prod: `info` | `base/collector/otel-collector.yaml` (hardcoded `info`) | Override entire ConfigMap via `configMapGenerator` in overlay        |
| `loki_log_level`                   | Stage: `debug`, Prod: `info` | `base/loki/local-config.yaml` (hardcoded `info`)        | Overlay ConfigMap patch                                              |
| `collector_debug_exporter_enabled` | Stage: `true`, Prod: `false` | Not in production config                                | Local and stage overlays add it via `configMapGenerator` replacement |

#### Storage

| Ansible Variable           | Ansible Default   | Kustomize Location      | How to Change                                                            |
|----------------------------|-------------------|-------------------------|--------------------------------------------------------------------------|
| `loki_storage_size`        | `20Gi`            | `base/loki/pvc.yaml`    | Overlay PVC patch                                                        |
| `loki_storage_class`       | `aws-efs-tier-c4` | Not in base PVC         | Stage/production overlays add `storageClassName` via `patches/pvcs.yaml` |
| `loki_storage_access_mode` | `ReadWriteMany`   | `base/loki/pvc.yaml`    | Local overlay patches to `ReadWriteOnce`                                 |
| `grafana_storage_size`     | `2Gi`             | `base/grafana/pvc.yaml` | Overlay PVC patch                                                        |
| `grafana_storage_class`    | `aws-efs-tier-c4` | Not in base PVC         | Stage/production overlays add `storageClassName` via `patches/pvcs.yaml` |

#### TLS Certificates

| Ansible Variable            | Kustomize Equivalent           | Notes                                                                   |
|-----------------------------|--------------------------------|-------------------------------------------------------------------------|
| `grafana_tls_certificate`   | Not needed                     | Routes use OpenShift ingress controller wildcard cert                   |
| `grafana_tls_key`           | Not needed                     | Same                                                                    |
| `collector_tls_certificate` | Not needed                     | Same                                                                    |
| `collector_tls_key`         | Not needed                     | Same                                                                    |
| `ca_chain_certificate`      | Not needed                     | Same                                                                    |
| Internal service TLS        | Automatic                      | OpenShift Service CA generates `*-tls` secrets from service annotations |
| `service_ca_cert_grafana`   | Post-deploy injection          | Deploy script injects Service CA cert into Grafana datasource           |

#### Component Toggles

| Ansible Variable | Ansible Default | Kustomize Equivalent                                                      |
|------------------|-----------------|---------------------------------------------------------------------------|
| `deploy_loki`    | `false`         | Always deployed in base. To exclude: remove from overlay `resources` list |
| `deploy_grafana` | `false`         | Always deployed in base. To exclude: remove from overlay `resources` list |

#### Collector ServiceAccount

| Ansible Variable    | Ansible Default                           | Kustomize Equivalent                                                |
|---------------------|-------------------------------------------|---------------------------------------------------------------------|
| `collector_sa_name` | Auto-generated: `otel-collector-<random>` | Hardcoded: `otel-collector` in `base/collector/serviceaccount.yaml` |

## Development

This project uses [Task](https://taskfile.dev) as a task runner. Run `task` to see all commands.

```bash
# CRC (OpenShift Local)
task crc:start               # Start CRC cluster
task crc:stop                # Stop cluster (preserves data)
task crc:status              # Show cluster status
task crc:login               # Log in as kubeadmin (opens browser)
task crc:sealed-secrets      # Install SealedSecrets controller
task crc:delete              # Delete cluster and all data

# Skaffold (OpenShift)
task sk:dev                   # Continuous dev loop (port-forward, logs, cleanup)
task sk:run                   # One-shot deploy to local
task sk:run -- stage          # Deploy to stage
task sk:run -- production     # Deploy to production
task sk:render                # Render local manifests to stdout
task sk:render -- stage       # Render stage manifests to stdout
task sk:validate              # Validate all profiles render cleanly
task sk:status                # Show pod status
task sk:delete                # Delete deployed resources
task sk:run NAMESPACE=foo        # Deploy to custom namespace
task sk:render NAMESPACE=foo     # Render manifests for custom namespace
task sk:delete NAMESPACE=foo     # Tear down custom namespace deploy

# Podman Quadlet (systemctl --user)
task quadlet:setup            # Generate certs, install quadlet units
task quadlet:start            # Start all services
task quadlet:status           # Show service status
task quadlet:logs -- collector  # Stream logs via journalctl
task quadlet:teardown         # Full cleanup

# Integration Tests
task integration:test                    # Run all tests (CRC mode)
task integration:test MODE=quadlet       # Run all tests (Quadlet mode)
task integration:test NAMESPACE=foo      # Run tests in custom namespace (CRC only)
task integration:setup                   # Install tools + deploy + port-forward
task integration:clean                   # Remove test artifacts
```

### Testing Local Images

#### Quadlet

Set `COLLECTOR_IMAGE` when running setup to use a locally-built collector:

```bash
COLLECTOR_IMAGE=localhost/complybeacon/collector:latest task quadlet:setup
task quadlet:restart
```

The default is `quay.io/complytime/beacon-collector:latest`. Re-run setup to switch back.

#### CRC (OpenShift Local)

CRC includes an internal image registry. Push your local image there, then patch the deployment to use it.

```bash
# 1. Log in to CRC's internal registry (accepts its self-signed cert)
oc registry login --insecure=true

# 2. Tag your local image for the internal registry
podman tag localhost/complybeacon/collector:latest \
  $(oc registry info)/complytime-dev/collector:dev

# 3. Push (--tls-verify=false because CRC's registry uses a self-signed cert)
podman push --tls-verify=false \
  $(oc registry info)/complytime-dev/collector:dev

# 4. Patch the deployment to use the pushed image
#    Inside the cluster, the registry is at image-registry.openshift-image-registry.svc:5000
oc set image deployment/collector \
  collector=image-registry.openshift-image-registry.svc:5000/complytime-dev/collector:dev \
  -n complytime-dev
```

To switch back to the upstream image:

```bash
oc set image deployment/collector \
  collector=quay.io/complytime/beacon-collector:latest \
  -n complytime-dev
```

After either change, OpenShift rolls out a new pod automatically. Watch progress with `oc rollout status deployment/collector -n complytime-dev`.

**Iterating:** When you rebuild and push a new version of the same `collector:dev` tag, delete the running pod to force a re-pull (Kubernetes caches `imagePullPolicy: IfNotPresent` by default for named tags):

```bash
podman push --tls-verify=false $(oc registry info)/complytime-dev/collector:dev
oc delete pod -l app=collector -n complytime-dev
```

**Note:** `oc set image` patches the live deployment directly. Running `task sk:dev` or `task sk:run` redeploys from the kustomize overlay and resets the image back to the base default (`quay.io/complytime/beacon-collector:latest`).

**Using the overlay instead:** If you want `task sk:dev` and `task sk:run` to deploy your custom image (so Skaffold doesn't reset it on every cycle), add a kustomize `images` transformer to `overlays/local/kustomization.yaml`:

```yaml
images:
  - name: quay.io/complytime/beacon-collector
    newName: image-registry.openshift-image-registry.svc:5000/complytime-dev/collector
    newTag: dev
```

This only affects the local overlay — stage and production continue pulling from quay.io. Remove the `images:` block when you're done testing to return to the upstream default. Don't commit this change unless the team agrees to a new default.

## Repository Structure

```
.
├── Taskfile.yml            # Task runner — run 'task' for commands
├── base/                   # Kustomize base manifests (production-accurate)
│   ├── kustomization.yaml  # Aggregates all components
│   ├── service-ca-bundle/  # OpenShift Service CA for internal TLS
│   ├── collector/          # OTel pipeline
│   │   ├── deployment.yaml, service.yaml, serviceaccount.yaml
│   │   └── otel-collector.yaml  # OTel config (kustomize generates ConfigMap)
│   ├── loki/               # Log storage
│   │   ├── deployment.yaml, service.yaml, pvc.yaml
│   │   └── local-config.yaml  # Loki server config
│   └── grafana/            # Dashboard UI
│       ├── deployment.yaml, service.yaml, pvc.yaml
│       └── configmap.yaml  # Grafana datasource config
├── overlays/               # Environment-specific customizations
│   ├── local/              # Local development (CRC)
│   ├── stage/              # Pre-production (OIDC, debug, SealedSecrets)
│   └── production/         # Production (OIDC, no debug, SealedSecrets)
├── quadlet/                # Podman Quadlet deployment (no OpenShift needed)
│   ├── README.md
│   ├── templates/          # Quadlet unit file templates
│   ├── configs/            # Grafana datasource templates (quadlet-specific)
│   └── runtime/            # Generated at setup time (gitignored)
├── skaffold.yaml           # Skaffold config — deploy lifecycle manager
├── scripts/                # Automation (called by Skaffold hooks and Taskfile)
│   ├── apply-sealed-secrets.sh   # Pre-deploy: create secrets (CI vars or SealedSecrets)
│   ├── post-deploy.sh            # Post-deploy: TLS patching, CA injection
└── .gitlab-ci.yml          # CI/CD pipeline (validate + deploy)
```

### Config Organization

Service configs live next to the manifests that use them, eliminating duplication:

- **Base configs** (`base/<component>/`) — production-accurate. Used by `configMapGenerator` to create ConfigMaps.
- **Overlay configs** (`overlays/<env>/configs/`) — environment-specific overrides. Each overlay replaces collector config via `configMapGenerator` with `behavior: replace`.
- **Quadlet configs** (`quadlet/configs/`) — Grafana datasource templates with `@@LOKI_HOST@@` and `@@CA_CERT@@` placeholders, substituted at runtime by the setup script. Other quadlet configs are sourced from base/ and overlays/ at setup time.

## Contributing

1. Create a feature branch
2. Make changes to base manifests or overlays
3. Validate: `task sk:validate`
4. Test locally: `task sk:dev`
5. Commit changes
6. Create merge request

## Appendix

### Why Quadlets Over `podman kube play`

The quadlet deployment uses systemd unit files (`.container`, `.network`, `.volume`) rather
than feeding Kubernetes YAML to `podman kube play`. Both approaches run containers under
rootless Podman without a cluster, but quadlets were chosen for several reasons:

- **systemd integration** — Quadlet units are native systemd services. You get ordered
  startup via `Requires=`/`After=`, automatic restart policies, and `journalctl` logging
  with no extra plumbing. `podman kube play` creates containers outside of systemd's
  supervision, so you'd need to wrap it in a service unit yourself to get the same
  lifecycle guarantees.

- **Dependency ordering** — The collector must start after Loki and RustFS. Quadlet
  expresses this directly in the unit file (`Requires=complytime-loki.service`). With
  `podman kube play`, all containers in a pod start together; cross-pod ordering requires
  external scripting.

- **Familiar operational model** — `systemctl --user start/stop/status` and `journalctl
  --user` are the same tools used to manage any other user service. There's no new CLI
  surface to learn.

- **Template substitution** — The quadlet setup script substitutes placeholders
  (`@@RUNTIME@@`, `@@PROTOCOL@@`, `@@COLLECTOR_IMAGE@@`, `@@CA_CERT@@`) at install time, generating
  environment-specific unit files. Kubernetes YAML doesn't have a built-in templating
  mechanism, so `podman kube play` would require a separate tool (envsubst, Helm, Kustomize)
  to achieve the same result.

The tradeoff is that quadlet unit files don't share YAML with the Kustomize base, so the
two deployment paths maintain separate configuration. This is acceptable because the
quadlet surface is small (4 containers, 3 volumes, 1 network) and the configs it references
(OTel collector, Loki, Grafana datasources) are sourced from the same base files at setup
time.

## License

Proprietary - Red Hat Internal Use Only
