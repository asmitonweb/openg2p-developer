# Registries

| id | Chart (oan-helm) | Release name | Source repository (COSS) | Staff UI (local) | State |
| --- | --- | --- | --- | --- | --- |
| `farmer` | `openg2p-farmer-registry` | `farmer-registry` | `farmer-registry` | http://farmer-registry.openg2p.localtest.me | runs; promotion-ready upstream |
| `crop` | `openg2p-cropsown-registry` | `cropsown-registry` | `cropsown-regsitry` (sic) | http://crop-registry.openg2p.localtest.me | runs; chart marked not promotion-ready |
| `live` | `openg2p-livestock-registry` | `livestock-registry` | `livestock-registry` | http://livestock-registry.openg2p.localtest.me | runs; chart marked not promotion-ready |
| `da` | `openg2p-da-registry` | `da-registry` | `da-registry` | — | placeholder: empty repository, chart has every component disabled |

The table is the `registry` kind in `scripts/components.sh`; adding a registry means one line
there, one `<ID>_VERSION` in `versions.env`, one `values/<id>.yaml`, and optionally
`overrides/<id>.yaml`. Its dashboard API (`<id>-dashboard-api`, a chart switch) and dashboard
(`<id>-dashboard`, an add-on chart) are separate components that require it.

Each registry is its own Compose project (`out/<id>/compose.yaml`) and can run alongside the
others on the shared commons. Per registry you get the platform services (`staff-portal-api`,
`partner-api`, `staff-portal-ui`, `celery-worker`, `celery-beat-producer`, `id-generator`, a
Redis) plus the jobs the chart defines (`postgres-init`, `keycloak-init`, `iam-register`,
`db-seed`, farmer's `fr-reporting-views`).

## Images and the platform pin

All registry images are **layers** on published OpenG2P images. The build argument in each
Dockerfile pins the platform version:

| Registry | Base image | Pin (develop, 2026-10-27) |
| --- | --- | --- |
| farmer | `openg2p/openg2p-farmer-registry-<role>` | `FARMER_VERSION=1.2.1-rc.192`; staff-ui builds from `registry-platform` at a pinned commit |
| crop | `openg2p/openg2p-registry-<role>` | `RP_VERSION=1.2.2-rc.544` |
| live | `openg2p/openg2p-registry-<role>` | `RP_VERSION=1.2.2-rc.544` |

The chart's `openg2p-registry` dependency (1.2.2-rc.557 for farmer/crop/live) is a separate pin
and should track the same platform release as the images. Both are reviewed changes in the
registry repository and oan-helm; this stack only consumes them.

## The promotion gate (crop and livestock)

The COSS crop and livestock charts contain `templates/refactor-promotion-gate.yaml`, a template
that unconditionally fails rendering with a message that the refactor is incomplete. On the dev
cluster that blocks an accidental deploy. On a developer machine it would block the very work it
protects, so `scripts/render.sh` deletes that one file from the downloaded chart copy before
`helm template` and prints a note. Nothing else is changed. When the charts are promoted upstream
the file disappears and the note stops appearing.

## Seed data

- **Geography** for every registry comes from Master Data, which the commons-services chart
  seeds from the `ETH-OAN` country pack (`ghcr.io/asmitonweb/master-data-db-seed`, built from the
  openg2p-data fork). The registry seeds run with `loadGeoData: false`.
- **Sample records** are enabled locally (`loadSampleData: true` in `values/<id>.yaml`). The farmer
  seed builds its sample people from Master Data; crop and livestock ship SQL sample sets in
  `docker/db-seed/sample-data/`. Crop and livestock additionally apply their own Ethiopia geo SQL
  to the Master Data database (`LOAD_ETHIOPIA_GEO`, default true in their entrypoints).
- **Templates** (DCI/VC) load with `loadTemplates: true`.
- Re-seed with `./oan.sh rerun <release>-db-seed`; the seed applies the metadata tree as a whole.

## Developing against a registry

```bash
./oan.sh dev farmer                                  # clones oan-workspace/farmer-registry, builds, starts
# edit oan-workspace/farmer-registry/oan-extension/...
./oan.sh reload farmer db-seed && ./oan.sh rerun farmer-registry-db-seed    # metadata / seed
./oan.sh reload farmer staff-api                     # rebuild + restart the staff API
```

To build from your own checkout rather than `oan-workspace/`, set `OAN_FARMER_SRC=/path/to/farmer-registry`
(`OAN_CROP_SRC`, `OAN_LIVE_SRC`) in `.env`. The scripts never modify an existing checkout. The
full loop is in [developing-a-registry.md](developing-a-registry.md).

## DA registry

`Centre-for-Open-Societal-Systems/da-registry` contains a README only, and the oan-helm chart
`openg2p-da-registry` disables every component with empty image fields. The stack renders it
(so its database and Keycloak plumbing appear once enabled) but `./oan.sh up da` stops with a
message because there is nothing to run. When the repository gains Dockerfiles, add its roles to
`scripts/build.sh` and enable the components in `values/da.yaml`.
