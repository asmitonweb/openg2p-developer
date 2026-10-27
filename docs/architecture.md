# Architecture

## Four layers of Helm releases, one Compose project per namespace

The shared OAN dev cluster installs the Helm releases in order, each into a namespace:

| Order | Release | Namespace | Chart | Owner |
| --- | --- | --- | --- | --- |
| 1 | `commons` | `commons` | `openg2p-commons-base` (upstream) | OpenG2P |
| 2 | `commons-services` | `commons` | `openg2p-commons-services` (COSS, vendors upstream) | COSS / OAN |
| 3 | `<registry>-registry` | `farmer`, `crop`, `live`, `da` | `openg2p-<registry>-registry` (COSS wrapper of upstream `openg2p-registry`) | COSS / OAN |
| 4 | `<registry>-registry-dashboard` | the registry's namespace | `<registry>-registry-dashboard` (oan-helm add-on) | COSS / OAN |

The OAN services inside release 2 (Consent Manager, aggregation API, consent partner portal) and
the dashboard API inside release 3 are chart switches. This repository models all of it as
*components* (`scripts/components.sh`): registries, services (a `--set` on commons-services),
features (a `--set` on a registry chart) and add-ons (their own chart). `./oan.sh select` picks
them; the render applies the switches and charts of the selection.

This repository reproduces exactly that. `scripts/render.sh` downloads the charts at the
versions in `versions.env`, runs `helm template` with `values/<release>.yaml`, and
`scripts/gen.py` turns each namespace's manifests into `out/<namespace>/compose.yaml`. All
projects share one Docker network named `openg2p`, so in-cluster names such as
`commons-postgresql` or `commons-keycloak.commons.svc.cluster.local` resolve across projects
exactly as they do across namespaces.

`scripts/stack.sh up <registry>` replays Helm's release order, which Compose has no notion of:
infrastructure first, then every `postgres-init` job, then the base `keycloak-init` job (realm
and admin), then the other `keycloak-init` jobs, then the applications and their jobs (IAM
registration, db-seed). Jobs that already exited 0 are skipped.

## What the translator does (gen.py)

- Deployments and StatefulSets become services; extra containers in a pod share the main
  container's network namespace (`network_mode: service:`).
- Jobs become one-shot services restarted on failure up to their `backoffLimit`; init containers
  become one-shot services chained with `service_completed_successfully`. Post-install hook jobs
  (`helm.sh/hook`) depend on the release's workloads and on lower-weight hooks of the same
  release, get at least 15 attempts, and `stack.sh` starts them last, because what they call
  (IAM, for example) may live in another project.
- CronJobs become a service that runs the job's command in a sleep loop at the schedule's
  interval: the materialized reporting views behind the dashboards stay fresh. A CronJob whose
  container has no explicit command is skipped and listed in the report.
- Services become network aliases. When a Service port differs from the container port, the alias
  moves to the nginx gateway (HTTP) or a socat forwarder (TCP), and the backend container gets a
  `--pod` suffix.
- Istio VirtualServices become gateway routes on host port 80; the gateway answers the same host
  names inside the network, so browser and containers see one issuer
  (`http://keycloak.openg2p.localtest.me/realms/staff`).
- ConfigMaps and Secrets become files under `out/files/`; PVCs and emptyDirs become named volumes
  `openg2p_<name>`; `fsGroup` is emulated by a chown init container.
- Each Helm subchart becomes a Compose profile, so `up esignet` or `up odk-central` starts only
  that part.
- Generated secrets are pinned in `state/secrets.json` so a re-render never rotates a password the
  databases already hold. Only token-like values (letters, digits, `+/=_-`) are pinned; URLs,
  JSON and certificate blocks follow the chart (and `extras/`) on every render. Delete an entry
  from the file to take the chart's value again.

Two translations are specific to the OAN charts, which are pinned to the shared dev cluster:

- **Hosts.** `*.development.oanstaging.com` (and the upstream subchart defaults
  `*.<ns>.openg2p.org`) are rewritten to `*.openg2p.localtest.me`, and `https` to `http`. The
  domain list is `OAN_REMOTE_DOMAINS`.
- **Images.** Private ECR references are rewritten to `$OAN_IMAGE_PREFIX/<product>/<role>:<tag>`
  with the digest dropped (`oan/…:local` for local builds, `ghcr.io/…` for published images),
  after any explicit rule in `images.yaml`. `out/REPORT.md` lists every remap.

The rest of the charts render unmodified. The one exception is documented in
[registries.md](registries.md): the crop and livestock charts carry a template that fails every
render on purpose, and the renderer removes it from the local copy.

## Why render charts instead of writing compose files

- The dev cluster and a laptop run the same configuration, so "works locally" means something.
- A platform or chart upgrade is a one-line pin change. Differences surface as render warnings or
  as skipped objects in `out/REPORT.md`, not as silently stale compose files.
- Values files are the same kind of artefact the cluster uses; a local fix that belongs in the
  chart is visible as such.

## Versions

`versions.env` pins:

- `COMMONS_BASE_VERSION`: newest **release candidate** in `OpenG2P/versions/commons/CHANGELOG.md`
  (develop builds are rebuilt in place and are not used).
- `COMMONS_SERVICES_VERSION`, `<REGISTRY>_VERSION`: newest entries in the oan-helm
  `repository/index.yaml`. The COSS commons-services chart records the upstream version it vendors
  in its `appVersion` (2.3.4-rc.247 for 1.0.0-dev.24), which should match `COMMONS_BASE_VERSION`.

`./oan.sh versions` rewrites the pins from those sources; review the diff, re-render, start a
registry, and commit.

## Resource footprint

Commons core + commons services + one registry is roughly 4 to 5 GB of container memory. Kafka,
eSignet, ODK Central, Superset and Inji Certify are separate profiles and are not started by the
default bundle. `./oan.sh ram` shows memory per project.
