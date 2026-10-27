# Images and seed data

## Where every image comes from

| Group | Source | Pullable without credentials |
| --- | --- | --- |
| Commons Base (Postgres, Keycloak, MinIO, Redis, Kafka, keycloak-init) | upstream chart defaults, Docker Hub `openg2p/*`, `bitnami`-derived | yes |
| Commons Services (IAM, Master Data, AWE, partner management, staff portal, ODK, eSignet, MOSIP) | upstream chart defaults, Docker Hub | yes |
| Master Data seed (ETH-OAN pack) | `ghcr.io/asmitonweb/master-data-db-seed:0.0.0-develop.118-oan.1` | yes |
| Every OAN-built image: registries (staff-api, partner-api, celery, db-seed, staff-ui), Consent Manager (api, ui, sanity), partner portal, aggregation API, dashboard APIs, dashboards | `ghcr.io/asmitonweb/<product>/<role>:latest`, built from COSS `develop` by the mirror workflow on the `asmitonweb` forks (`ci/fork-mirror-and-images.yml`, branch `oan-ci`); built locally from source when not published yet | yes |

`<product>/<role>` is the path the COSS charts use in their private ECR (`openg2p/farmer-registry/staff-api`,
`oan/commons/aggregation-api`, …) with the registry host replaced: `scripts/gen.py` rewrites every
ECR reference to `$OAN_IMAGE_PREFIX/<product>/<role>:$OAN_IMAGE_TAG`. Which repository builds
which product and roles is the catalogue, [`scripts/components.sh`](../scripts/components.sh):

| Component | COSS repository (`develop`) | Product | Roles |
| --- | --- | --- | --- |
| farmer | farmer-registry | farmer-registry | staff-api partner-api celery db-seed staff-ui |
| crop | cropsown-regsitry (sic) | cropsown-registry | same |
| live | livestock-registry | livestock-registry | same |
| consent-manager, consent-partner-portal | consent-management | commons | consent-manager-api consent-manager-ui consent-manager-sanity consent-partner-portal |
| aggregation-api | oan-aggregation-api | commons | aggregation-api |
| farmer-dashboard-api, crop-dashboard-api, live-dashboard-api | farmer-registry-dashboard-api, cropsown-registry-dashboard-api, livestock-registry-dashbaord-api (sic) | `<registry>` | dashboard-api |
| farmer-dashboard, crop-dashboard, live-dashboard | oan_farmerregistry_dashboard, oan_cropsown_dashboard, oan_livestock_dashboard | `<registry>` | dashboard |

CI for this repository checks that the compose files of every component render and validate, and
that every role above is published on GHCR.

## Tagging convention: OAN tracks `latest`

OpenG2P pins every image to a release version. OAN does not: images are consumed by their floating
`latest` tag, which the fork workflows move on every change of COSS `develop`. The same build is
also tagged `:develop` and with the 12-character commit sha (what the oan-helm charts pin), so a
developer who needs exactly what the dev cluster runs sets `OAN_IMAGE_TAG=<sha12>`. `docker pull`
picks up a moved `latest` only when asked: `./oan.sh pull` refreshes the selected components.

## GHCR (default) with build fallback

`OAN_IMAGE_SOURCE=ghcr` (the default) makes `gen.py` write `ghcr.io/asmitonweb/<product>/<role>:latest`.
`oan.sh up` pulls what is missing with `docker compose pull` (compose shows the layer progress); an image that is
not published yet is built from source with `scripts/build.sh` and tagged with the published name,
so the compose files never change and a later pull replaces it.

### Why forks, not the organisation

A package published under the COSS organisation can only be made public by someone with admin on
it, which an org package inherits from the repository: repository admins, not maintainers. A
workflow was tried in `farmer-registry` (PR #139) and reverted (PR #140) for that reason. Each
fork `asmitonweb/<repo>` therefore carries, on its default branch `oan-ci`, the workflow in
[`ci/fork-mirror-and-images.yml`](../ci/fork-mirror-and-images.yml): every hour it force-mirrors
COSS `develop` (and `staging` where it exists) into the fork and builds the images from COSS
`develop`, skipping commits already published, so an idle run takes seconds. The fork's `develop`
is always identical to COSS `develop`; nothing OAN-specific is committed to it.

[`ci/install-fork-workflow.sh <component>...`](../ci/install-fork-workflow.sh) writes that
workflow to a fork (creating the fork when missing), fills in the repository, product, branch and
the role/Dockerfile/context matrix from the catalogue, makes `oan-ci` the default branch and
dispatches a first run. Two manual steps remain in the GitHub UI, once per fork: enable Actions if
the API refused, and set each new package to **public** (profile → Packages → package settings →
change visibility). Most COSS repositories keep an empty `main`; all code is on `develop`, which
is why every mirror follows `develop`.

When the organisation allows public packages, switch `OAN_IMAGE_PREFIX` back to
`ghcr.io/centre-for-open-societal-systems` and adopt `ci/ghcr-images.yml` in the COSS repos.

## Local builds

`OAN_IMAGE_SOURCE=local` (what `./oan.sh dev` sets) makes `gen.py` write `oan/<product>/<role>:local`
and `oan.sh up` builds what is missing with `scripts/build.sh <component> [role...]`, which reproduces
each repository's CI build: same Dockerfile, same build context (repository root, or `ui/` and
`partner-portal/` for the two Consent Manager SPAs), default build args. Builds need network access
to Docker Hub, PyPI and npm; farmer's staff-ui also fetches the platform UI from GitHub at a pinned
commit. The registries' sanity-tests images are not built; the sanity jobs are disabled locally.

## Seed data

- The **Master Data** seed image is the only place geography enters the system. It is built from
  the openg2p-data repository (`docker/master-data-db-seed/Dockerfile`, a copy of the upstream seed
  image with the repository's `packs/` replacing the baked-in data) by the tag-triggered workflow
  `master-data-db-seed/<tag>`. The COSS `openg2p-data` repository carries the same workflow but has
  no tags yet, so the published image is the fork's. Pushing a tag on the COSS repository publishes
  `ghcr.io/centre-for-open-societal-systems/master-data-db-seed:<tag>`; then change the image in
  oan-helm's commons-services values, release the chart, and bump `COMMONS_SERVICES_VERSION` here.
- **Registry seeds** are inside each registry's db-seed image (metadata tree, AWE metadata, DCI
  templates, sample SQL). They run once as a job; `./oan.sh rerun <release>-db-seed` re-applies
  the whole tree.
- Seed images are built on the upstream seed image, which already contains an `openg2p-data`
  clone; only the OAN packs and the registry's own seed differ.

### Master Data is a catalogue: drafts are invisible until published

Master Data versions everything (maker-checker). The pack loader creates a DRAFT geography and
one draft per code list; only *publishing* fills the legacy tables (`g2p_geo_levels`,
`g2p_geo_level_values`, the attribute value tables) that the registries and their seeds read.
The COSS commons-services chart sets `geoSeed.publishInitial: false` because the dev cluster was
seeded once by hand and approved in the Master Data UI (role `MASTER_DATA_APPROVER`). A fresh
database has nothing to protect, so `values/commons-services.yaml` sets `publishInitial: true`;
the loader's own default is the same. Symptoms when it is missing: the geo-seed log ends with
`geography: version 1 left as DRAFT` and `geography version in effect: -`, Master Data shows
74 lists awaiting approval, and the farmer seed dies with `list index out of range` in
`load_geo_indexes` (empty leaf list). Re-running the loader does not help: it refuses to touch an
open draft. Either approve the drafts in Master Data or publish them with the functions the loader
uses (`g2p_catalogue_publish_geo`, `g2p_catalogue_publish_list` with `p_allow_draft = true`).

Later loads of a *changed* pack still produce drafts for approval, as on the cluster;
`geoSeed.autoPublish` would publish those too and is development-only.

### Sample farmers are off

The farmer db-seed can submit sample households through the intake API
(`dbSeed.loadSampleData`). The loader is upstream's (`/seed/load_sample_data.py` in
`openg2p/openg2p-farmer-registry-db-seed`) and sends the PREFIX *display* text (`Mr`, `Ms`), while
every country pack codes the list as `MR`, `MRS`, `MISS`, `MS`. OAN validates attribute values
against Master Data (`REGISTRY_CORE_VALIDATE_ATTRIBUTE_VALUES=true`), so the first household is
rejected with `REQ-VAL-001`. The COSS chart ships `loadSampleData: false` for the same reason, and
so does `values/farmer.yaml`. The fix belongs upstream (the loader must send codes); until then,
create farmers through the staff UI or ODK. Note also that the OAN seed overlay prefers sample
people from Master Data (`g2p_sample_individuals`), which are only there when the Master Data
seed loads the pack's `samples/` (`geoSeed.load.samples`, off in the COSS chart).
