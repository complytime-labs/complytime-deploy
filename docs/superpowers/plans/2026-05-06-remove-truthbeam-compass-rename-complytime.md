# Remove Truthbeam/Compass and Rename to ComplyTime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Truthbeam processor and Compass service from the project, and rename from 'complybeacon' to 'complytime' throughout the codebase.

**Architecture:** Truthbeam is an OTEL collector processor that will be removed from all pipeline configurations. Compass is a compliance evaluation backend service that will be fully removed (K8s manifests, quadlet configs, references). The project rename affects namespaces, systemd service names, network names, volume names, and documentation.

**Tech Stack:** Kubernetes/OpenShift manifests (Kustomize), OpenTelemetry Collector, Podman Quadlet, Taskfile

---

## Task 1: Remove Truthbeam Processor from OTEL Collector Configs

**Files:**
- Modify: `base/collector/otel-collector.yaml`
- Modify: `overlays/local/configs/collector-local.yaml`
- Modify: `overlays/stage/configs/collector-stage.yaml`
- Modify: `base/loki/local-config.yaml`

- [ ] **Step 1: Remove truthbeam processor from base collector config**

Edit `base/collector/otel-collector.yaml`:
- Remove the `truthbeam:` processor block (should be around line 30-35)
- In the `service.pipelines.logs.processors` array, remove `truthbeam` from the list
- The processors should change from `[batch, transform/ocsf, truthbeam]` to `[batch, transform/ocsf]`

```bash
git diff base/collector/otel-collector.yaml
```

Expected: Shows removal of truthbeam processor definition and reference in pipeline

- [ ] **Step 2: Remove truthbeam processor from local collector config**

Edit `overlays/local/configs/collector-local.yaml`:
- Remove the `truthbeam:` processor block
- In the `service.pipelines.logs.processors` array, remove `truthbeam`
- The processors should change from `[batch, transform/ocsf, truthbeam]` to `[batch, transform/ocsf]`

```bash
git diff overlays/local/configs/collector-local.yaml
```

Expected: Shows removal of truthbeam processor definition and reference in pipeline

- [ ] **Step 3: Remove truthbeam processor from stage collector config**

Edit `overlays/stage/configs/collector-stage.yaml`:
- Remove the `truthbeam:` processor block
- In the `service.pipelines.logs.processors` array, remove `truthbeam`
- The processors should change from `[batch, transform/ocsf, truthbeam]` to `[batch, transform/ocsf]`

```bash
git diff overlays/stage/configs/collector-stage.yaml
```

Expected: Shows removal of truthbeam processor definition and reference in pipeline

- [ ] **Step 4: Remove truthbeam comment from Loki config**

Edit `base/loki/local-config.yaml`:
- Find the comment `# These attributes are added by truthbeam processor` (around line 47)
- Remove this comment line

```bash
git diff base/loki/local-config.yaml
```

Expected: Shows removal of truthbeam comment

- [ ] **Step 5: Commit truthbeam removal**

```bash
git add base/collector/otel-collector.yaml overlays/local/configs/collector-local.yaml overlays/stage/configs/collector-stage.yaml base/loki/local-config.yaml
git commit -m "refactor: remove truthbeam processor from OTEL collector pipeline"
```

---

## Task 2: Remove Compass Service Manifests

**Files:**
- Delete: `base/compass/` (entire directory)
- Modify: `base/kustomization.yaml`

- [ ] **Step 1: Remove compass from base kustomization**

Edit `base/kustomization.yaml`:
- Remove the line `  - compass` from the `resources:` array (line 8)

```bash
git diff base/kustomization.yaml
```

Expected: Shows removal of compass resource reference

- [ ] **Step 2: Delete compass directory**

```bash
rm -rf base/compass/
```

Expected: Directory `base/compass/` no longer exists

- [ ] **Step 3: Verify compass directory is deleted**

```bash
test ! -d base/compass/ && echo "PASS: compass directory removed" || echo "FAIL: compass directory still exists"
```

Expected: Output shows "PASS: compass directory removed"

- [ ] **Step 4: Commit compass manifest removal**

```bash
git add base/kustomization.yaml
git add -u base/compass/
git commit -m "refactor: remove compass service manifests"
```

---

## Task 3: Remove Compass References from Collector Deployment

**Files:**
- Modify: `base/collector/deployment.yaml`

- [ ] **Step 1: Remove compass environment variable from collector**

Edit `base/collector/deployment.yaml`:
- Find the environment variable block with `name: JWT_AUDIENCE` and `value: "compass"` (around line 75)
- Remove this entire env block (3 lines: name, value)

```bash
git diff base/collector/deployment.yaml | grep -A2 -B2 "JWT_AUDIENCE"
```

Expected: Shows removal of JWT_AUDIENCE environment variable

- [ ] **Step 2: Remove compass-sa-token volume mount**

Edit `base/collector/deployment.yaml`:
- Find the `volumeMounts:` section
- Remove the compass-sa-token volume mount block (around line 91, 3 lines total):
  ```yaml
  - name: compass-sa-token
    mountPath: /var/run/secrets/tokens
    readOnly: true
  ```

```bash
git diff base/collector/deployment.yaml | grep -A2 -B2 "compass-sa-token"
```

Expected: Shows removal of compass-sa-token volumeMount

- [ ] **Step 3: Remove compass-sa-token volume definition**

Edit `base/collector/deployment.yaml`:
- Find the `volumes:` section
- Remove the compass-sa-token volume definition block (around line 104, entire projected volume with serviceAccountToken):
  ```yaml
  - name: compass-sa-token
    projected:
      sources:
        - serviceAccountToken:
            path: compass-token
            expirationSeconds: 3600
            audience: compass-internal-auth
  ```

```bash
git diff base/collector/deployment.yaml | grep -A8 "compass-sa-token"
```

Expected: Shows removal of compass-sa-token volume with projected serviceAccountToken

- [ ] **Step 4: Remove compass comment from deployment**

Edit `base/collector/deployment.yaml`:
- Find the comment `# Mounts projected SA token for Compass JWT authentication.` (around line 72)
- Remove this comment line

```bash
git diff base/collector/deployment.yaml
```

Expected: Shows removal of compass authentication comment

- [ ] **Step 5: Commit collector deployment changes**

```bash
git add base/collector/deployment.yaml
git commit -m "refactor: remove compass authentication from collector deployment"
```

---

## Task 4: Remove Compass Configs from Local Overlay

**Files:**
- Delete: `overlays/local/configs/compass-config.yaml`
- Modify: `overlays/local/kustomization.yaml`

- [ ] **Step 1: Remove compass configMapGenerator from local kustomization**

Edit `overlays/local/kustomization.yaml`:
- Remove the entire compass-config configMapGenerator block (lines 36-39):
  ```yaml
  - name: compass-config
    behavior: merge
    files:
      - config.yaml=configs/compass-config.yaml
  ```

```bash
git diff overlays/local/kustomization.yaml
```

Expected: Shows removal of compass-config configMapGenerator

- [ ] **Step 2: Remove compass-jwt-audience secretGenerator from local kustomization**

Edit `overlays/local/kustomization.yaml`:
- Remove the entire secretGenerator block (lines 41-46):
  ```yaml
secretGenerator:
  - name: compass-jwt-audience
    literals:
      - audience=compass-internal-auth
    options:
      disableNameSuffixHash: true
  ```

```bash
git diff overlays/local/kustomization.yaml
```

Expected: Shows removal of compass-jwt-audience secretGenerator

- [ ] **Step 3: Update local kustomization comment**

Edit `overlays/local/kustomization.yaml`:
- Find the comment on line 8: `#   - Replaces compass config (disables JWT auth)`
- Remove this entire comment line

```bash
git diff overlays/local/kustomization.yaml
```

Expected: Shows removal of compass config comment

- [ ] **Step 4: Delete compass config file**

```bash
rm -f overlays/local/configs/compass-config.yaml
```

Expected: File `overlays/local/configs/compass-config.yaml` no longer exists

- [ ] **Step 5: Commit local overlay changes**

```bash
git add overlays/local/kustomization.yaml
git add -u overlays/local/configs/compass-config.yaml
git commit -m "refactor: remove compass configs from local overlay"
```

---

## Task 5: Remove Compass Configs from Stage Overlay

**Files:**
- Delete: `overlays/stage/configs/compass-config-stage.yaml`
- Delete: `overlays/stage/patches/compass-env.yaml`
- Modify: `overlays/stage/kustomization.yaml`

- [ ] **Step 1: Remove compass patch from stage kustomization**

Edit `overlays/stage/kustomization.yaml`:
- In the `patches:` section, remove the line `  - path: patches/compass-env.yaml` (line 30)

```bash
git diff overlays/stage/kustomization.yaml
```

Expected: Shows removal of compass-env.yaml patch reference

- [ ] **Step 2: Remove compass configMapGenerator from stage kustomization**

Edit `overlays/stage/kustomization.yaml`:
- Remove the entire compass-config configMapGenerator block (lines 39-42):
  ```yaml
  - name: compass-config
    behavior: merge
    files:
      - config.yaml=configs/compass-config-stage.yaml
  ```

```bash
git diff overlays/stage/kustomization.yaml
```

Expected: Shows removal of compass-config configMapGenerator

- [ ] **Step 3: Update stage kustomization comment**

Edit `overlays/stage/kustomization.yaml`:
- Find the comment on line 6: `#   - Replaces compass config (allowedSubjects for stage namespace)`
- Remove this entire comment line

```bash
git diff overlays/stage/kustomization.yaml
```

Expected: Shows removal of compass config comment

- [ ] **Step 4: Delete compass config files**

```bash
rm -f overlays/stage/configs/compass-config-stage.yaml
rm -f overlays/stage/patches/compass-env.yaml
```

Expected: Files no longer exist

- [ ] **Step 5: Verify compass files are deleted**

```bash
test ! -f overlays/stage/configs/compass-config-stage.yaml && test ! -f overlays/stage/patches/compass-env.yaml && echo "PASS: compass files removed" || echo "FAIL: compass files still exist"
```

Expected: Output shows "PASS: compass files removed"

- [ ] **Step 6: Commit stage overlay changes**

```bash
git add overlays/stage/kustomization.yaml
git add -u overlays/stage/configs/compass-config-stage.yaml overlays/stage/patches/compass-env.yaml
git commit -m "refactor: remove compass configs from stage overlay"
```

---

## Task 6: Remove Compass from Quadlet

**Files:**
- Delete: `quadlet/templates/compass.container`
- Modify: `quadlet/README.md`

- [ ] **Step 1: Delete compass quadlet container file**

```bash
rm -f quadlet/templates/compass.container
```

Expected: File `quadlet/templates/compass.container` no longer exists

- [ ] **Step 2: Update quadlet README architecture diagram**

Edit `quadlet/README.md`:
- Find the ASCII architecture diagram (around line 15-19)
- Remove the line containing `complybeacon-collector -----> complybeacon-compass (internal)`
- The diagram should now show only collector, loki, grafana, and rustfs

```bash
git diff quadlet/README.md | grep -A5 -B5 "compass"
```

Expected: Shows removal of compass from architecture diagram

- [ ] **Step 3: Commit quadlet changes**

```bash
git add -u quadlet/templates/compass.container
git add quadlet/README.md
git commit -m "refactor: remove compass from quadlet configuration"
```

---

## Task 7: Update Taskfile to Remove Compass

**Files:**
- Modify: `Taskfile.yaml`

- [ ] **Step 1: Remove compass from quadlet:status task**

Edit `Taskfile.yaml`:
- Find the `quadlet:status` task (around line 43)
- In the command, change `complybeacon-rustfs complybeacon-loki complybeacon-compass complybeacon-collector complybeacon-grafana` to `complybeacon-rustfs complybeacon-loki complybeacon-collector complybeacon-grafana`
- Remove `complybeacon-compass` from the list

```bash
git diff Taskfile.yaml | grep -A3 -B3 "status"
```

Expected: Shows removal of complybeacon-compass from status command

- [ ] **Step 2: Update quadlet:logs task description**

Edit `Taskfile.yaml`:
- Find the `quadlet:logs` task description (around line 47)
- The description currently shows `usage: task quadlet:logs -- compass`
- Change the example from `compass` to `collector` or `grafana`

```bash
git diff Taskfile.yaml
```

Expected: Shows updated example in logs task description

- [ ] **Step 3: Commit Taskfile changes**

```bash
git add Taskfile.yaml
git commit -m "refactor: remove compass from taskfile commands"
```

---

## Task 8: Rename complybeacon to complytime in Namespaces

**Files:**
- Modify: `overlays/local/kustomization.yaml`
- Modify: `overlays/stage/kustomization.yaml`
- Modify: `overlays/production/kustomization.yaml`

- [ ] **Step 1: Rename namespace in local overlay**

Edit `overlays/local/kustomization.yaml`:
- Find line 16: `namespace: complybeacon-dev`
- Change to: `namespace: complytime-dev`
- Update comment on line 3 to say `complytime-dev` instead of `complybeacon-dev`

```bash
git diff overlays/local/kustomization.yaml
```

Expected: Shows complybeacon-dev → complytime-dev

- [ ] **Step 2: Rename namespace in stage overlay**

Edit `overlays/stage/kustomization.yaml`:
- Find line 20: `namespace: complybeacon-stage`
- Change to: `namespace: complytime-stage`
- Update comment on line 3 to say `complytime-stage` instead of `complybeacon-stage`

```bash
git diff overlays/stage/kustomization.yaml
```

Expected: Shows complybeacon-stage → complytime-stage

- [ ] **Step 3: Rename namespace in production overlay**

Edit `overlays/production/kustomization.yaml`:
- Find the line: `namespace: complybeacon-prod`
- Change to: `namespace: complytime-prod`
- Update comment to say `complytime-prod` instead of `complybeacon-prod`

```bash
git diff overlays/production/kustomization.yaml
```

Expected: Shows complybeacon-prod → complytime-prod

- [ ] **Step 4: Commit namespace renames**

```bash
git add overlays/local/kustomization.yaml overlays/stage/kustomization.yaml overlays/production/kustomization.yaml
git commit -m "refactor: rename namespaces from complybeacon to complytime"
```

---

## Task 9: Rename complybeacon to complytime in Skaffold

**Files:**
- Modify: `skaffold.yaml`

- [ ] **Step 1: Rename project name in skaffold**

Edit `skaffold.yaml`:
- Find line with `name: complybeacon`
- Change to: `name: complytime`

```bash
git diff skaffold.yaml | grep "name:"
```

Expected: Shows complybeacon → complytime for project name

- [ ] **Step 2: Rename dev project in skaffold**

Edit `skaffold.yaml`:
- Find the command: `oc new-project complybeacon-dev 2>/dev/null || oc project complybeacon-dev`
- Change both occurrences to: `complytime-dev`

```bash
git diff skaffold.yaml | grep "complytime-dev"
```

Expected: Shows complybeacon-dev → complytime-dev

- [ ] **Step 3: Rename stage project in skaffold**

Edit `skaffold.yaml`:
- Find the command: `oc new-project complybeacon-stage 2>/dev/null || oc project complybeacon-stage`
- Change both occurrences to: `complytime-stage`

```bash
git diff skaffold.yaml | grep "complytime-stage"
```

Expected: Shows complybeacon-stage → complytime-stage

- [ ] **Step 4: Rename production project in skaffold**

Edit `skaffold.yaml`:
- Find the command: `oc new-project complybeacon-prod 2>/dev/null || oc project complybeacon-prod`
- Change both occurrences to: `complytime-prod`

```bash
git diff skaffold.yaml | grep "complytime-prod"
```

Expected: Shows complybeacon-prod → complytime-prod

- [ ] **Step 5: Commit skaffold changes**

```bash
git add skaffold.yaml
git commit -m "refactor: rename project from complybeacon to complytime in skaffold"
```

---

## Task 10: Rename complybeacon to complytime in Quadlet

**Files:**
- Modify: `quadlet/templates/complybeacon.network`
- Modify: `quadlet/templates/collector.container`
- Modify: `quadlet/templates/grafana.container`
- Modify: `quadlet/templates/loki.container`
- Modify: `quadlet/templates/rustfs.container`
- Modify: `quadlet/README.md`

- [ ] **Step 1: Rename network file**

```bash
git mv quadlet/templates/complybeacon.network quadlet/templates/complytime.network
```

Expected: File renamed from complybeacon.network to complytime.network

- [ ] **Step 2: Update network name in network file**

Edit `quadlet/templates/complytime.network`:
- Find the `NetworkName=` line
- Change from `complybeacon` to `complytime`

```bash
git diff quadlet/templates/complytime.network
```

Expected: Shows NetworkName change

- [ ] **Step 3: Update network references in collector container**

Edit `quadlet/templates/collector.container`:
- Find `Network=complybeacon.network`
- Change to: `Network=complytime.network`

```bash
git diff quadlet/templates/collector.container
```

Expected: Shows network reference update

- [ ] **Step 4: Update network references in grafana container**

Edit `quadlet/templates/grafana.container`:
- Find `Network=complybeacon.network`
- Change to: `Network=complytime.network`

```bash
git diff quadlet/templates/grafana.container
```

Expected: Shows network reference update

- [ ] **Step 5: Update network references in loki container**

Edit `quadlet/templates/loki.container`:
- Find `Network=complybeacon.network`
- Change to: `Network=complytime.network`

```bash
git diff quadlet/templates/loki.container
```

Expected: Shows network reference update

- [ ] **Step 6: Update network references in rustfs container**

Edit `quadlet/templates/rustfs.container`:
- Find `Network=complybeacon.network`
- Change to: `Network=complytime.network`

```bash
git diff quadlet/templates/rustfs.container
```

Expected: Shows network reference update

- [ ] **Step 7: Update volume names in volume files**

Edit `quadlet/templates/grafana-storage.volume`:
- Change volume name from `complybeacon-grafana-storage` to `complytime-grafana-storage`

Edit `quadlet/templates/loki-storage.volume`:
- Change volume name from `complybeacon-loki-storage` to `complytime-loki-storage`

Edit `quadlet/templates/rustfs-storage.volume`:
- Change volume name from `complybeacon-rustfs-storage` to `complytime-rustfs-storage`

```bash
git diff quadlet/templates/*.volume
```

Expected: Shows volume name changes

- [ ] **Step 8: Update volume references in container files**

Edit `quadlet/templates/grafana.container`:
- Find `Volume=complybeacon-grafana-storage.volume:/var/lib/grafana`
- Change to: `Volume=complytime-grafana-storage.volume:/var/lib/grafana`

Edit `quadlet/templates/loki.container`:
- Find `Volume=complybeacon-loki-storage.volume:/loki`
- Change to: `Volume=complytime-loki-storage.volume:/loki`

Edit `quadlet/templates/rustfs.container`:
- Find `Volume=complybeacon-rustfs-storage.volume:/data`
- Change to: `Volume=complytime-rustfs-storage.volume:/data`

```bash
git diff quadlet/templates/*.container | grep "Volume="
```

Expected: Shows volume reference updates

- [ ] **Step 9: Update quadlet README architecture diagram**

Edit `quadlet/README.md`:
- Find all occurrences of `complybeacon-` prefix in service names
- Change to `complytime-` (e.g., `complybeacon-collector` → `complytime-collector`)
- Update the network name from `complybeacon` to `complytime`

```bash
git diff quadlet/README.md | grep -E "complytime-|complybeacon-"
```

Expected: Shows all service name updates in README

- [ ] **Step 10: Update volume names in quadlet README**

Edit `quadlet/README.md`:
- Find references to `complybeacon-loki-storage`, `complybeacon-grafana-storage`, `complybeacon-rustfs-storage`
- Change all to `complytime-*-storage`

```bash
git diff quadlet/README.md
```

Expected: Shows volume name updates

- [ ] **Step 11: Commit quadlet renames**

```bash
git add quadlet/
git commit -m "refactor: rename complybeacon to complytime in quadlet configuration"
```

---

## Task 11: Rename complybeacon to complytime in Taskfile

**Files:**
- Modify: `Taskfile.yaml`

- [ ] **Step 1: Update Taskfile header comment**

Edit `Taskfile.yaml`:
- Find line 1: `# ComplyBeacon task runner — run 'task' to see available commands.`
- Change to: `# ComplyTime task runner — run 'task' to see available commands.`

```bash
git diff Taskfile.yaml | head -5
```

Expected: Shows ComplyBeacon → ComplyTime

- [ ] **Step 2: Update task descriptions**

Edit `Taskfile.yaml`:
- Find task descriptions mentioning "ComplyBeacon"
- Change all to "ComplyTime"
- Examples:
  - `Start all ComplyBeacon services` → `Start all ComplyTime services`
  - `Stop all ComplyBeacon services` → `Stop all ComplyTime services`
  - `Show status of all ComplyBeacon quadlet services` → `Show status of all ComplyTime quadlet services`

```bash
git diff Taskfile.yaml | grep -i "comply"
```

Expected: Shows description updates

- [ ] **Step 3: Update systemd service names in quadlet:status**

Edit `Taskfile.yaml`:
- Find the quadlet:status command with: `complybeacon-rustfs complybeacon-loki complybeacon-collector complybeacon-grafana`
- Change to: `complytime-rustfs complytime-loki complytime-collector complytime-grafana`

```bash
git diff Taskfile.yaml | grep "systemctl"
```

Expected: Shows service name changes

- [ ] **Step 4: Update systemd service names in quadlet:logs**

Edit `Taskfile.yaml`:
- Find the quadlet:logs command with: `complybeacon-{{.CLI_ARGS}}`
- Change to: `complytime-{{.CLI_ARGS}}`

```bash
git diff Taskfile.yaml | grep "journalctl"
```

Expected: Shows service prefix update

- [ ] **Step 5: Commit Taskfile renames**

```bash
git add Taskfile.yaml
git commit -m "refactor: rename complybeacon to complytime in taskfile"
```

---

## Task 12: Update S3 Bucket Name References

**Files:**
- Modify: `overlays/local/rustfs/create-bucket-job.yaml`
- Modify: `overlays/local/patches/collector-env.yaml`

- [ ] **Step 1: Update bucket name in create-bucket-job**

Edit `overlays/local/rustfs/create-bucket-job.yaml`:
- Find the curl command with `/complybeacon-evidence`
- Change to: `/complytime-evidence`
- Update the comment mentioning `complybeacon-evidence` to `complytime-evidence`

```bash
git diff overlays/local/rustfs/create-bucket-job.yaml
```

Expected: Shows bucket name change

- [ ] **Step 2: Update bucket name in collector environment**

Edit `overlays/local/patches/collector-env.yaml`:
- Find the environment variable value: `"complybeacon-evidence"`
- Change to: `"complytime-evidence"`

```bash
git diff overlays/local/patches/collector-env.yaml
```

Expected: Shows bucket name environment variable change

- [ ] **Step 3: Commit S3 bucket renames**

```bash
git add overlays/local/rustfs/create-bucket-job.yaml overlays/local/patches/collector-env.yaml
git commit -m "refactor: rename S3 bucket from complybeacon-evidence to complytime-evidence"
```

---

## Task 13: Update Main README Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README title**

Edit `README.md`:
- Find line 1: `# ComplyBeacon`
- Change to: `# ComplyTime`

```bash
git diff README.md | head -5
```

Expected: Shows title change

- [ ] **Step 2: Update README description**

Edit `README.md`:
- Find the description paragraph mentioning "ComplyBeacon is a compliance monitoring..."
- Change to: "ComplyTime is a compliance monitoring..."

```bash
git diff README.md | grep "ComplyTime is"
```

Expected: Shows description update

- [ ] **Step 3: Remove Compass from architecture diagram**

Edit `README.md`:
- Find the ASCII architecture diagram
- Remove the lines showing Collector → Compass connection
- Remove the Compass box from the diagram
- Update the diagram to show Collector only connects to Loki and S3

```bash
git diff README.md | grep -A10 -B5 "Collector"
```

Expected: Shows Compass removal from diagram

- [ ] **Step 4: Remove Compass from component list**

Edit `README.md`:
- Find the bullet list of components
- Remove the entire `- **Compass**: Compliance evaluation backend...` line

```bash
git diff README.md | grep -i "compass"
```

Expected: Shows Compass component removal

- [ ] **Step 5: Update data flow description**

Edit `README.md`:
- Find the paragraph starting with "**Data flow:**"
- Remove all mentions of Compass
- Update to: "External clients send compliance data to Collector via webhook (OIDC-authenticated) or OTLP. Collector transforms logs to OCSF format, generates metrics, and exports to Loki (for querying) and S3 (for evidence storage). Grafana queries Loki for dashboard visualization."

```bash
git diff README.md | grep -A5 "Data flow"
```

Expected: Shows updated data flow without Compass

- [ ] **Step 6: Remove Compass TLS from Service CA section**

Edit `README.md`:
- Find the Service CA operator section
- Remove `compass-tls` from the list of auto-generated TLS secrets
- Update to only mention `collector-tls`, `loki-tls`, `grafana-tls`

```bash
git diff README.md | grep "tls"
```

Expected: Shows compass-tls removal

- [ ] **Step 7: Remove compass-jwt-audience from secrets table**

Edit `README.md`:
- Find the secrets table
- Remove the row for `compass-jwt-audience`

```bash
git diff README.md | grep -A2 -B2 "jwt"
```

Expected: Shows compass JWT secret removal

- [ ] **Step 8: Remove compass from quay-io-pull-secret table row**

Edit `README.md`:
- Find the quay-io-pull-secret row in the secrets table
- Change "Compass, Collector" to just "Collector"

```bash
git diff README.md | grep "quay-io"
```

Expected: Shows Compass removal from pull secret usage

- [ ] **Step 9: Remove compass-jwt-audience from local development section**

Edit `README.md`:
- Find the "For **local development**" paragraph
- Remove the mention of `compass-jwt-audience` secret being generated by kustomize

```bash
git diff README.md | grep -A5 "local development"
```

Expected: Shows compass secret removal

- [ ] **Step 10: Remove compass from logs example**

Edit `README.md`:
- Find the task logs example: `task quadlet:logs -- compass`
- Change to a different example like: `task quadlet:logs -- collector`

```bash
git diff README.md | grep "task quadlet:logs"
```

Expected: Shows example change

- [ ] **Step 11: Remove compass image variables from table**

Edit `README.md`:
- Find the configuration table with image variables
- Remove rows for `compass_image`, `compass_jwt_auth_enabled`, `compass_jwt_audience`, `compass_log_level`

```bash
git diff README.md | grep -i "compass_"
```

Expected: Shows compass variable rows removal

- [ ] **Step 12: Remove compass from build/push examples**

Edit `README.md`:
- Find the podman build/push example commands mentioning compass
- Remove these examples entirely (they reference compass image building)

```bash
git diff README.md | grep -A3 -B3 "podman build"
```

Expected: Shows compass build example removal

- [ ] **Step 13: Remove compass directory from structure diagram**

Edit `README.md`:
- Find the directory structure tree
- Remove the lines showing `base/compass/` and its files

```bash
git diff README.md | grep -A5 "├── compass"
```

Expected: Shows compass directory removal from tree

- [ ] **Step 14: Remove compass config from overlay configs description**

Edit `README.md`:
- Find the section describing overlay configs
- Remove mentions of compass configs being replaced via configMapGenerator

```bash
git diff README.md | grep -A3 -B3 "compass config"
```

Expected: Shows compass config description removal

- [ ] **Step 15: Update namespace references in README**

Edit `README.md`:
- Find all occurrences of `complybeacon-dev`, `complybeacon-stage`, `complybeacon-prod`
- Change to `complytime-dev`, `complytime-stage`, `complytime-prod`
- This includes oc commands, table entries, and descriptive text

```bash
git diff README.md | grep -E "complytime-dev|complytime-stage|complytime-prod"
```

Expected: Shows all namespace renames

- [ ] **Step 16: Update service account references**

Edit `README.md`:
- Find service account references like `system:serviceaccount:complybeacon-stage:otel-collector`
- Change namespace portion to `complytime-stage`

```bash
git diff README.md | grep "serviceaccount"
```

Expected: Shows service account namespace updates

- [ ] **Step 17: Commit README updates**

```bash
git add README.md
git commit -m "docs: update README to remove compass and rename to complytime"
```

---

## Task 14: Update Stage Sealed Secrets README

**Files:**
- Modify: `overlays/stage/sealed-secrets/README.md`

- [ ] **Step 1: Update namespace in sealed secrets commands**

Edit `overlays/stage/sealed-secrets/README.md`:
- Find all occurrences of `-n complybeacon-stage`
- Change to: `-n complytime-stage`

```bash
git diff overlays/stage/sealed-secrets/README.md
```

Expected: Shows all namespace parameter updates

- [ ] **Step 2: Commit sealed secrets README**

```bash
git add overlays/stage/sealed-secrets/README.md
git commit -m "docs: update sealed-secrets README namespace to complytime-stage"
```

---

## Task 15: Verify No Remaining References

**Files:**
- None (verification only)

- [ ] **Step 1: Search for remaining complybeacon references**

```bash
grep -r "complybeacon" /workspace --include="*.yaml" --include="*.yml" --include="*.md" --include="*.container" --include="*.network" --include="*.volume" 2>/dev/null || echo "PASS: No complybeacon references found"
```

Expected: Output shows "PASS: No complybeacon references found" (or only acceptable exceptions like git history)

- [ ] **Step 2: Search for remaining compass references**

```bash
grep -r "compass\|Compass" /workspace --include="*.yaml" --include="*.yml" --include="*.md" --include="*.container" 2>/dev/null | grep -v ".git/" | grep -v "docs/superpowers/plans/" || echo "PASS: No compass references found"
```

Expected: Output shows "PASS: No compass references found" (excluding this plan and git history)

- [ ] **Step 3: Search for remaining truthbeam references**

```bash
grep -r "truthbeam\|Truthbeam" /workspace --include="*.yaml" --include="*.yml" --include="*.md" 2>/dev/null | grep -v ".git/" | grep -v "docs/superpowers/plans/" || echo "PASS: No truthbeam references found"
```

Expected: Output shows "PASS: No truthbeam references found" (excluding this plan and git history)

- [ ] **Step 4: Verify kustomize builds successfully for local**

```bash
kubectl kustomize overlays/local > /dev/null && echo "PASS: Local overlay builds" || echo "FAIL: Local overlay has errors"
```

Expected: Output shows "PASS: Local overlay builds"

- [ ] **Step 5: Verify kustomize builds successfully for stage**

```bash
kubectl kustomize overlays/stage > /dev/null && echo "PASS: Stage overlay builds" || echo "FAIL: Stage overlay has errors"
```

Expected: Output shows "PASS: Stage overlay builds"

- [ ] **Step 6: Verify kustomize builds successfully for production**

```bash
kubectl kustomize overlays/production > /dev/null && echo "PASS: Production overlay builds" || echo "FAIL: Production overlay has errors"
```

Expected: Output shows "PASS: Production overlay builds"

---

## Task 16: Final Review and Summary

**Files:**
- None (review only)

- [ ] **Step 1: Review git log**

```bash
git log --oneline -20
```

Expected: Shows all commits from this refactoring with clear, descriptive messages

- [ ] **Step 2: Generate summary of changes**

```bash
echo "=== Refactoring Summary ==="
echo ""
echo "Truthbeam Processor: REMOVED"
echo "  - Removed from base/collector/otel-collector.yaml"
echo "  - Removed from overlays/local/configs/collector-local.yaml"
echo "  - Removed from overlays/stage/configs/collector-stage.yaml"
echo ""
echo "Compass Service: REMOVED"
echo "  - Deleted base/compass/ directory"
echo "  - Removed from all kustomizations"
echo "  - Removed authentication from collector"
echo "  - Deleted quadlet compass.container"
echo ""
echo "Project Rename: complybeacon → complytime"
echo "  - Namespaces: complytime-dev, complytime-stage, complytime-prod"
echo "  - Quadlet services: complytime-*"
echo "  - Network: complytime"
echo "  - Volumes: complytime-*-storage"
echo "  - S3 bucket: complytime-evidence"
echo ""
echo "All kustomize overlays verified to build successfully."
```

Expected: Displays complete summary of changes

- [ ] **Step 3: Verify working directory is clean**

```bash
git status
```

Expected: Output shows "working tree clean" with no uncommitted changes
