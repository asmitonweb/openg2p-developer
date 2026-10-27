# OAN developer stack

One-command local environment for OpenAgriNet (OAN) registry development, for OAN and COSS
developers. It runs the same three layers as the shared dev cluster, from the same Helm charts,
on Docker Compose:

```
┌──────────────────────────────────────────────────────────────────────┐
│ 3. <registry>        farmer | crop | live | da   (pick one, or more)  │  COSS chart  oan-helm
├──────────────────────────────────────────────────────────────────────┤
│ 2. Commons Services  IAM · Master Data · AWE · Partner Mgmt ·        │  COSS chart  oan-helm
│                      Consent Manager · eSignet · ODK · staff portal  │  (vendors upstream + OAN config)
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
./oan.sh up farmer        # or: crop | live        (Windows: oan.cmd up farmer)
```

The first run builds the tools image, renders the charts, pulls the registry's images from GHCR
(`:latest`; while a registry is not published there yet it is built from its COSS source
repository, cloned into `src/`, about 15 minutes), pulls the commons images, then starts
everything in Helm release order: infrastructure, database init jobs, Keycloak init, the
services, and finally the registry's seed job. A second `up` takes seconds.

Then open:

| What | URL |
| --- | --- |
| Registry staff UI | http://farmer-registry.openg2p.localtest.me (crop-registry…, livestock-registry…) |
| Staff portal (app launcher) | http://staff-portal.openg2p.localtest.me |
| Keycloak | http://keycloak.openg2p.localtest.me |
| Master Data UI · AWE | http://master-data-ui.openg2p.localtest.me · http://awe.openg2p.localtest.me |
| Postgres from the host | `127.0.0.1:5433` |

`*.openg2p.localtest.me` resolves to 127.0.0.1 without any hosts-file change. Every gateway host
is listed in `out/REPORT.md` after a render. Seeded staff users and their passwords are in
`out/files/*keycloak-init*/config/clients.yaml`; generated admin passwords (Keycloak, Postgres)
are pinned in `state/secrets.json`, which is git-ignored.

## Everyday commands

```bash
./oan.sh up crop                       # add or switch to another registry (commons is shared)
./oan.sh stop farmer                   # stop one registry's containers; data volumes stay
./oan.sh stop all                      # stop everything
./oan.sh build farmer staff-api        # rebuild one image after editing src/farmer-registry
./oan.sh rerun farmer-registry-db-seed # run a finished job again (fresh seed)
./oan.sh ps | ram | logs <container>   # status, memory per project, follow logs
./oan.sh render                        # re-render after changing versions.env or values/
./oan.sh versions                      # move versions.env to the newest published charts
./oan.sh down                          # remove containers (volumes kept)
```

Profiles beyond the default bundle (eSignet, ODK Central, Superset, Kafka, …) start on request:
`./oan.sh up esignet farmer`. Names are in `out/REPORT.md`.

## Changing a registry

`up` runs the published images. To change a registry, run it from your own source instead:

```bash
./oan.sh dev farmer                      # fork + clone COSS farmer-registry into src/, build, start
./oan.sh src branch farmer my-change     # branch from the newest upstream develop
#  ... edit src/farmer-registry ...
./oan.sh reload farmer staff-api         # rebuild the roles you touched, restart their services
./oan.sh src sync farmer                 # rebase onto upstream develop
./oan.sh src pr farmer                   # push to your fork, open the pull request on COSS develop
```

`dev` sets `OAN_IMAGE_SOURCE=local` in `.env`, so every later command builds from `src/`. The
checkout has your fork as `origin` and the COSS repository as `upstream`; `gh` (GitHub CLI) creates
the fork when you have none. The full loop, test commands, branch and commit conventions and what
must never be changed are in [docs/developing-a-registry.md](docs/developing-a-registry.md).

## Where things come from

| Layer | Chart | Version source | Images |
| --- | --- | --- | --- |
| Commons Base | `openg2p-commons-base` from openg2p.github.io/openg2p-helm | newest release candidate in [OpenG2P/versions](https://github.com/OpenG2P/versions) | upstream Docker Hub |
| Commons Services | `openg2p-commons-services` from the COSS [oan-helm](https://github.com/Centre-for-Open-Societal-Systems/oan-helm) repository | oan-helm `repository/index.yaml` | upstream Docker Hub, plus the ETH-OAN Master Data seed on GHCR |
| Registry | `openg2p-<registry>-registry` from oan-helm | oan-helm index | `ghcr.io/asmitonweb/<product>/<role>:latest`, built from COSS `develop` by the fork mirror workflow (OAN tracks a floating tag); built from source when not published yet, or always with `OAN_IMAGE_SOURCE=local` |

Details: [docs/architecture.md](docs/architecture.md), [docs/registries.md](docs/registries.md),
[docs/images-and-seed-data.md](docs/images-and-seed-data.md),
[docs/developing-a-registry.md](docs/developing-a-registry.md). How to contribute without touching
the platform: [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

```
oan.sh / oan.cmd        entry point
versions.env            chart pins (the only thing a version bump touches)
values/<layer>.yaml     Helm values for the local environment, per release
overrides/<ns>.yaml     hand-kept Compose tweaks (worker counts, local Kafka), per project
images.yaml             explicit image rewrites applied during translation
scripts/render.sh       fetch charts -> helm template -> gen.py
scripts/gen.py          Kubernetes manifests -> Compose (mapping rules in its docstring)
scripts/stack.sh        start/stop in Helm release order
scripts/build.sh        build a registry's images from its source repo, as its CI does
scripts/src.sh          fork / clone / branch / sync / pull request for src/<repo>
scripts/latest.sh       refresh versions.env from the published indexes
out/, rendered/, .cache/, state/, src/   generated or local; git-ignored
```

This branch (`oan-developer`) is the default branch of the `asmitonweb/openg2p-developer` fork.
The `main` branch tracks upstream [OpenG2P/openg2p-developer](https://github.com/OpenG2P/openg2p-developer),
which is the native (non-Docker) setup for the upstream products and is unrelated to this stack.

## License

[Mozilla Public License 2.0](LICENSE)
