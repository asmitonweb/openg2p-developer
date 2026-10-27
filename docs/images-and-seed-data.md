# Images and seed data

## Where every image comes from

| Group | Source | Pullable without credentials |
| --- | --- | --- |
| Commons Base (Postgres, Keycloak, MinIO, Redis, Kafka, keycloak-init) | upstream chart defaults, Docker Hub `openg2p/*`, `bitnami`-derived | yes |
| Commons Services (IAM, Master Data, AWE, partner management, staff portal, ODK, eSignet, MOSIP) | upstream chart defaults, Docker Hub | yes |
| Master Data seed (ETH-OAN pack) | `ghcr.io/asmitonweb/master-data-db-seed:0.0.0-develop.118-oan.1` | yes |
| Consent Manager | COSS chart pins a private dev build; `images.yaml` maps it to upstream `openg2p/consent-manager-*:1.0.2` | yes |
| Aggregation API, consent partner portal | COSS additions, private ECR only; disabled in `values/commons-services.yaml` | no public image yet |
| Registry images (staff-api, partner-api, celery, db-seed, staff-ui) | COSS CI pushes to private ECR only | **no** → built locally (default) or GHCR once published |

CI for this repository checks that every image referenced by the rendered compose files is either
an `oan/*:local` build target or publicly resolvable with `docker manifest inspect`.

## Registry images: local builds (default)

`OAN_IMAGE_SOURCE=local` (the default) makes `gen.py` write `oan/<product>/<role>:local` and
`oan.sh up` builds any that are missing with `scripts/build.sh`, which reproduces each repo's CI
build: same Dockerfiles, repo root as context, default build args.

| Registry | Dockerfiles | Roles built |
| --- | --- | --- |
| farmer | `docker/oan/<role>.Dockerfile` | staff-api, partner-api, celery, db-seed, staff-ui |
| crop, live | `docker/<role>/Dockerfile` | staff-api, partner-api, celery, db-seed, staff-ui |

Builds need network access to Docker Hub (base images), PyPI, and for farmer's staff-ui also
GitHub and npm (it builds the platform UI at a pinned commit with the OAN overlay). The
sanity-tests image is not built; the sanity job is disabled in the local values.

## Registry images: GHCR (when published)

The COSS repositories publish only to ECR today. To let developers pull instead of build, each
registry repository needs a GitHub Actions workflow that pushes to GHCR under the COSS
organisation. A ready-to-adopt workflow is in [`ci/ghcr-images.yml`](../ci/ghcr-images.yml):
it builds the same roles with the same Dockerfiles on pushes to `develop` and tags
`ghcr.io/centre-for-open-societal-systems/<product>/<role>:<12-char sha>` and `:develop`.

Once that runs, `OAN_IMAGE_SOURCE=ghcr` in `.env` is enough: the chart's tag is already the
12-character source commit, so the pins line up with no further change. If the workflow cannot
live in the COSS organisation, the same file works in a fork with
`OAN_IMAGE_PREFIX=ghcr.io/<fork-owner>`.

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
