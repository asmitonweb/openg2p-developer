# OAN developer stack

One-command local environment for OpenAgriNet (OAN) development, for OAN and COSS developers.
It runs the same layers as the shared dev cluster, from the same Helm charts, on Docker Compose,
and puts the source of everything you run into `oan-workspace/`:

```
┌──────────────────────────────────────────────────────────────────────┐
│ 4. add-ons           farmer | crop | live dashboards                  │  COSS charts oan-helm
├──────────────────────────────────────────────────────────────────────┤
│ 3. registries        farmer | crop | live | da   (pick any)           │  COSS charts oan-helm
├──────────────────────────────────────────────────────────────────────┤
│ 2. Commons Services  IAM · Master Data · AWE · Partner Mgmt ·        │  COSS chart  oan-helm
│                      Consent Manager · aggregation API · partner     │  (vendors upstream + OAN config)
│                      portal · eSignet · ODK · staff portal           │
├──────────────────────────────────────────────────────────────────────┤
│ 1. Commons Base      Postgres · Keycloak · MinIO · Redis · Kafka     │  upstream OpenG2P, unmodified
└──────────────────────────────────────────────────────────────────────┘
```

The charts are **rendered, not re-implemented**: `helm template` produces the Kubernetes
manifests and `scripts/gen.py` translates them into one Compose project per namespace. A version
bump is a change to `versions.env` and a re-render, never a hand-ported compose file.

## Requirements

- Docker Desktop (or Docker Engine + Compose v2) with about 8 GB of memory for commons + one registry.
- Git. On Windows, Git for Windows (its bash runs the scripts; `oan.cmd` wraps it).
- Nothing else: helm and python run inside a small tools image built on first use.

## Quick start

```bash
git clone -b oan-developer https://github.com/asmitonweb/openg2p-developer.git oan-developer
cd oan-developer
./oan.sh select                # Windows: oan.cmd select   — pick what runs, in the terminal
./oan.sh dev                   # build the selection from source and start it
```

The checklist (space toggles, enter saves to `.env`; dependencies follow automatically and the
mandatory parts of commons are fixed):

```
Select components  space toggle  ↑↓/jk move  enter save  q cancel
 ▶ [x] farmer                   registry  Farmer registry
   [ ] crop                     registry  Crop sown registry
   [ ] live                     registry  Livestock registry
   [ ] da                       registry  DA registry (empty stub upstream: renders nothing yet)
   [x] consent-manager          service   Consent Manager (OAN build; always part of commons) always
   [ ] aggregation-api          service   Aggregation layer over the OAN services
   [ ] consent-partner-portal   service   Consent partner portal
   [x] farmer-dashboard-api     feature   Farmer dashboard API (reads the registry database)
   [x] farmer-dashboard         addon     Farmer dashboard (Next.js)
   ...
```

`dev` then does everything a developer needs for that selection:

1. renders the charts into Compose projects;
2. clones **every OAN repository** (`develop`) into `oan-workspace/`: the registries, Consent
   Manager, the aggregation API, the dashboards and their APIs, oan-helm and openg2p-data, so the
   whole codebase is next to the running system whatever you selected;
3. builds the selected components' images from their checkouts (about 15 minutes the first time
   for a registry) and pulls the commons images;
4. starts everything in Helm release order: infrastructure, database init jobs, Keycloak init,
   the services, and finally the seed jobs.

A second run takes seconds. `./oan.sh up` does the same with the **published** images
(`ghcr.io/asmitonweb/...:latest`, rebuilt hourly from COSS `develop`) and still provisions the
workspace. Existing checkouts are never touched: branches, remotes and uncommitted work in
`oan-workspace/` are yours. `./oan.sh select` again changes what runs; `./oan.sh dev crop` adds
a component to the selection on the way.

Then open:

| What | URL |
| --- | --- |
| Registry staff UI | http://farmer-registry.openg2p.localtest.me (crop-registry…, livestock-registry…) |
| Registry dashboard | http://farmer-registry-dashboard.openg2p.localtest.me |
| Staff portal (app launcher) | http://staff-portal.openg2p.localtest.me |
| Keycloak | http://keycloak.openg2p.localtest.me |
| Master Data UI · AWE | http://master-data-ui.openg2p.localtest.me · http://awe.openg2p.localtest.me |
| Postgres from the host | `127.0.0.1:5433` |

`*.openg2p.localtest.me` resolves to 127.0.0.1 without any hosts-file change. Every gateway host
is listed in `out/REPORT.md` after a render. Seeded staff users and their passwords are in
`out/files/*keycloak-init*/config/clients.yaml`; generated admin passwords (Keycloak, Postgres)
are pinned in `state/secrets.json`, which is git-ignored.

## The developer loop

```bash
./oan.sh dev                           # the selection from oan-workspace/ (sets OAN_IMAGE_SOURCE=local)
#   ... edit oan-workspace/farmer-registry on your own branch ...
./oan.sh reload farmer staff-api       # rebuild the roles you touched, restart the services running them
./oan.sh reload farmer db-seed && ./oan.sh rerun farmer-registry-db-seed    # metadata / seed changes
./oan.sh src status                    # every checkout: branch, distance from develop, uncommitted files
```

Forking, branching, rebasing and opening the pull request on COSS `develop` are ordinary git and
GitHub, done by you; [docs/developing-a-registry.md](docs/developing-a-registry.md) walks through
the expected flow, the tests each repository's CI runs, the commit conventions and what must
never be changed (the platform). The same loop works for every component:
`./oan.sh dev consent-manager`, `./oan.sh dev farmer-dashboard`, …

## Everyday commands

```bash
./oan.sh up                            # start the selection (./oan.sh select); up crop adds a registry
./oan.sh stop farmer | stop all        # stop one registry's containers, or everything; volumes stay
./oan.sh rerun farmer-registry-db-seed # run a finished job again (fresh seed)
./oan.sh pull                          # fetch newer published images (latest moved on GHCR)
./oan.sh ps | ram | logs <container>   # status, memory per project, follow logs
./oan.sh render                        # re-render after changing versions.env or values/
./oan.sh versions                      # move versions.env to the newest published charts
./oan.sh components                    # the catalogue and the current selection
./oan.sh down                          # remove containers (volumes kept)
```

Profiles beyond the selection (eSignet, ODK Central, Superset, Kafka, …) start on request through
`scripts/stack.sh up esignet`; names are in `out/REPORT.md`.

## Where things come from

| Layer | Chart | Version source | Images |
| --- | --- | --- | --- |
| Commons Base | `openg2p-commons-base` from openg2p.github.io/openg2p-helm | newest release candidate in [OpenG2P/versions](https://github.com/OpenG2P/versions) | upstream Docker Hub |
| Commons Services | `openg2p-commons-services` from the COSS [oan-helm](https://github.com/Centre-for-Open-Societal-Systems/oan-helm) repository | oan-helm `repository/index.yaml` | upstream Docker Hub; the OAN services (Consent Manager, aggregation API, partner portal) and the ETH-OAN Master Data seed from GHCR |
| Registries | `openg2p-<registry>-registry` from oan-helm | oan-helm index | `ghcr.io/asmitonweb/<product>/<role>:latest` |
| Dashboards | `<registry>-registry-dashboard` from oan-helm | oan-helm index | `ghcr.io/asmitonweb/<registry>-registry/dashboard:latest` |

Every OAN image is built from COSS `develop` by a mirror workflow on the `asmitonweb` forks (OAN
tracks a floating `latest` tag); what is not published yet is built from `oan-workspace/`, and
`OAN_IMAGE_SOURCE=local` always builds. The catalogue of components, their repositories, images
and chart switches is [`scripts/components.sh`](scripts/components.sh).

Details: [docs/architecture.md](docs/architecture.md), [docs/registries.md](docs/registries.md),
[docs/services.md](docs/services.md), [docs/images-and-seed-data.md](docs/images-and-seed-data.md),
[docs/developing-a-registry.md](docs/developing-a-registry.md). How to contribute without touching
the platform: [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

```
oan.sh / oan.cmd        entry point (select, up, dev, reload, src, ...)
versions.env            chart pins (the only thing a version bump touches)
scripts/components.sh   the catalogue: registries, services, features, add-ons
values/<id>.yaml        Helm values for the local environment, per release
overrides/<ns>.yaml     hand-kept Compose tweaks (worker counts, local Kafka), per project
extras/<id>.yaml        objects a chart expects from outside (e.g. the aggregation API's catalogue)
images.yaml             explicit image rewrites applied during translation
scripts/render.sh       fetch charts -> helm template -> gen.py
scripts/gen.py          Kubernetes manifests -> Compose (mapping rules in its docstring)
scripts/stack.sh        start/stop in Helm release order
scripts/build.sh        build a component's images from oan-workspace/, as its CI does
scripts/src.sh          the checkouts in oan-workspace/ (clone, status, dir)
scripts/latest.sh       refresh versions.env from the published indexes
ci/                     the fork mirror-and-publish workflow and its installer
oan-workspace/          every OAN repository (COSS develop), provisioned by up; yours, git-ignored
out/, rendered/, .cache/, state/   generated or local; git-ignored
```

This branch (`oan-developer`) is the default branch of the `asmitonweb/openg2p-developer` fork.
The `main` branch tracks upstream [OpenG2P/openg2p-developer](https://github.com/OpenG2P/openg2p-developer),
which is the native (non-Docker) setup for the upstream products and is unrelated to this stack.

## License

[Mozilla Public License 2.0](LICENSE)
