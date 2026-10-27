# Developing a component

How to change an OAN registry (farmer, crop, live), a commons service (Consent Manager,
aggregation API, partner portal) or a dashboard with this stack: from the COSS source in
`oan-workspace/`, through a running local build of your change, to a pull request on COSS
`develop`. The rule behind every step is in [CONTRIBUTING.md](../CONTRIBUTING.md): the OpenG2P
platform is never modified; a registry is extended through metadata, configuration and its
extension package.

## What `up` and `dev` give you

`./oan.sh up` renders the selected components (`./oan.sh select`), **provisions every OAN
repository from COSS `develop` into `oan-workspace/<repo>`**, pulls the published images and
starts the selection. The whole codebase is there from the first run, next to the running system,
whether or not you intend to change it: the registries, Consent Manager (with the partner
portal), the aggregation API, the dashboards and their APIs, plus oan-helm (the charts this stack
renders) and openg2p-data (the Master Data packs). `./oan.sh src status` lists them.

| Mode | `OAN_IMAGE_SOURCE` | Images | For |
| --- | --- | --- | --- |
| **use** | `ghcr` (default) | `ghcr.io/asmitonweb/<product>/<role>:latest`, built hourly from COSS `develop` | running, testing someone else's change, demos |
| **develop** | `local` | `oan/<product>/<role>:local`, built from `oan-workspace/<repo>` | changing a component |

`./oan.sh dev` switches to develop mode: it writes `OAN_IMAGE_SOURCE=local` to `.env`, builds the
selection's images from the workspace and starts the stack (`./oan.sh dev <component>` adds that
component to the selection first; with nothing selected yet it opens the checklist). Mandatory
parts of commons, such as the Consent Manager, are always selected and cannot be removed. Commons (layers 1 and 2) are the same published images in both modes. To go back to
published images, set `OAN_IMAGE_SOURCE=ghcr` in `.env` and run `./oan.sh up`.

```
oan-workspace/
  farmer-registry/                 origin = https://github.com/Centre-for-Open-Societal-Systems/<repo>, branch develop
  cropsown-regsitry/  livestock-registry/  da-registry/
  consent-management/              Consent Manager api, ui, sanity and the partner portal
  oan-aggregation-api/
  farmer-registry-dashboard-api/  cropsown-registry-dashboard-api/  livestock-registry-dashbaord-api/
  oan_farmerregistry_dashboard/   oan_cropsown_dashboard/           oan_livestock_dashboard/
  oan-helm/                        charts (source kind: cloned, never run)
  openg2p-data/                    Master Data packs (source kind)
```

The scripts never modify a checkout that exists: no fetch, no reset, no branch switch. Git in
`oan-workspace/<repo>` is yours. To use a checkout you already have elsewhere, point
`OAN_<ID>_SRC` (`OAN_FARMER_SRC`, `OAN_CONSENT_MANAGER_SRC`, …) or `OAN_SRC_DIR` at it in `.env`.
On Windows the clones are made with `core.autocrlf=false`; a CRLF checkout breaks every container
entrypoint and `build` refuses it.

## The change loop

```bash
./oan.sh select && ./oan.sh dev              # 1. pick farmer, run it from source (first time: ~15 min of builds)
cd oan-workspace/farmer-registry
git switch -c odk-geo-codes                  # 2. your branch (see "Git flow" below)
#   ... edit metadata, widgets, extension package, seeds ...
cd -
./oan.sh reload farmer staff-api             # 3. rebuild the touched roles, restart their services
./oan.sh reload farmer db-seed               #    metadata or seed change: rebuild, then
./oan.sh rerun farmer-registry-db-seed       #    re-run the seed job (metadata is applied as a whole tree)
./oan.sh logs farmer-registry-staff-portal-api--pod   # container names = service names (./oan.sh ps)
./oan.sh src status                          # 4. every checkout: branch, distance from develop, dirty files
```

`reload` finds the services from the compose file, builds only the roles you name (all roles of
the component when you name none) and recreates the long-running services. Jobs are never
restarted automatically: `reload` prints the `rerun` command for them.

### Which role runs what (farmer; crop and live use the same roles with their own release prefix)

| Role | Service(s) | Rebuild when you change |
| --- | --- | --- |
| `staff-api` | `farmer-registry-staff-portal-api--pod` | the extension package (`*-extension/src`), API behaviour, Python dependencies |
| `partner-api` | `farmer-registry-partner-api--pod` | partner-facing API, connector code |
| `celery` | `farmer-registry-celery-worker`, `farmer-registry-celery-beat-producer` | tasks, schedules |
| `db-seed` | `farmer-registry-db-seed` (job), `farmer-registry-fr-reporting-views` (job) | register metadata, widgets, AWE metadata, seeds, reporting views |
| `staff-ui` | `farmer-registry-staff-portal-ui--pod` | UI widgets and translations |
| `dashboard-api` | `farmer-registry-dashboard-api` (component `farmer-dashboard-api`) | chart queries over the reporting views |
| `dashboard` | `farmer-registry-dashboard--pod` (component `farmer-dashboard`) | the Next.js dashboard |

Commons services: `consent-manager-api` → `commons-services-cm-api--pod` and `commons-services-cm-partner-api--pod`,
`consent-manager-ui` → `commons-services-cm-ui--pod`, `consent-partner-portal` → `commons-services-cm-partner-portal--pod`,
`aggregation-api` → `commons-services-aggregation-api--pod`. `./oan.sh components` lists every id.

### Tests

Run the repository's own tests before you open a pull request. They live in the repository and
its CI (`.github/workflows/checks.yml`, `Jenkinsfile`) is the reference for what is checked. For
the farmer registry:

```bash
cd oan-workspace/farmer-registry
python -m pytest -q                                     # pytest.ini: tests/unit, PYTHONPATH farmer-extension/src
python -m ruff check --select E9,F63,F7,F82 oan-extension/src oan-extension/tests
bash ci/validation/validate.sh                          # schema / metadata / delivery-boundary validation
```

The staff-api image is a faithful runtime for the extension tests, so you can also run them where
CI does:

```bash
docker run --rm -v "$PWD:/repo:ro" -w /repo/oan-extension --entrypoint sh oan/farmer-registry/staff-api:local \
  -c 'pip install --quiet pytest && python -m pytest -q -p no:cacheprovider tests'
```

Crop and livestock ship a `docker/sanity-tests/Dockerfile` for the same purpose. A metadata change
is tested by `./oan.sh rerun <release>-db-seed` finishing with exit code 0 and the form behaving as
intended in the staff UI; add a schema or sanity test for it in the repository's test folder.

## Git flow: fork, branch, pull request

The stack clones the COSS repository itself and stops there; the rest is ordinary git and GitHub,
done by you. The expected flow for someone without push rights on the COSS repository:

1. **Fork** the repository on GitHub (the Fork button on `Centre-for-Open-Societal-Systems/<repo>`),
   once. Then, in `oan-workspace/<repo>`:

   ```bash
   git remote rename origin upstream                      # COSS: fetched from, never pushed to
   git remote add origin https://github.com/<you>/<repo>.git
   git fetch upstream develop
   ```

   With push rights on COSS you may skip the fork and push branches to `origin` directly; a fork
   still keeps the shared branch list clean.

2. **Branch** from the newest `develop`, one change per branch:

   ```bash
   git fetch upstream develop && git switch -c odk-geo-codes upstream/develop
   ```

   Branch names describe the change (`odk-geo-codes`, `intake-photo-section`,
   `livestock-species-list`): no ticket keys, no personal prefixes. Never commit on `develop`.

3. **Commit** with a short imperative subject (under 72 characters) and a body that says what
   changed and why, not how it was produced. No ticket keys, no tool attributions, no
   `Co-Authored-By` trailers for tools. Squash fix-up commits before the PR, or ask for a squash merge.

4. **Rebase** before you push, resolve conflicts in the checkout, then `./oan.sh reload` to run
   the rebased code:

   ```bash
   git fetch upstream develop && git rebase upstream/develop
   ```

5. **Push and open the pull request** against the COSS repository's `develop`:

   ```bash
   git push -u origin odk-geo-codes
   # then on GitHub: Compare & pull request, base develop (or: gh pr create --repo Centre-for-Open-Societal-Systems/<repo> --base develop)
   ```

   Describe the behaviour and how you verified it against the local stack, list the metadata or
   roles touched, link the upstream issue if the change works around a platform gap. The
   repository's CI must be green. The delivery pipeline promotes `develop → testing → staging → release`.

6. **A chart change** (new env var, job, volume) goes to [oan-helm](https://github.com/Centre-for-Open-Societal-Systems/oan-helm)
   in the same review cycle. Once the chart is released, bump its pin in `versions.env` here.

7. **Merged?** `git fetch upstream develop && git merge --ff-only upstream/develop` on your
   `develop`, and within an hour the published `:latest` image carries it, so `ghcr` users get it
   on their next `./oan.sh pull`.

## What you must not do

The complete list is in [CONTRIBUTING.md](../CONTRIBUTING.md). The ones that come up most:

- editing files of the upstream `openg2p-registry` packages or the upstream staff UI, even inside
  a Dockerfile `RUN` step (the known `patch-*.js` and `core-patches` are debts, not patterns);
- changing the pinned platform version (`RP_VERSION`, `FARMER_VERSION`) as a side effect of a feature;
- applying one metadata file by hand with `psql`: the seed job applies the whole tree and resets
  partial changes;
- adding a "finalize" shortcut that bypasses the approval workflow (AWE);
- committing anything generated: `out/`, `state/`, `oan-workspace/` and `.env` are git-ignored
  here, and the repositories ignore their build outputs.

## Several components, several developers

Commons is shared; registries are independent Compose projects; services and dashboards join
them. `./oan.sh dev crop` next to a running farmer registry adds the crop project and clones
`oan-workspace/cropsown-regsitry` (the COSS repository name is spelled that way). Two people never
share an `oan-workspace/`; each has their own checkouts and their own fork.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `exec /…/entrypoint.sh: no such file or directory` in a container | CRLF checkout | the message printed by `build` gives the three git commands |
| `reload needs OAN_IMAGE_SOURCE=local` | you are in ghcr mode | `./oan.sh dev <component>` |
| images rebuilt but the UI shows the old behaviour | browser cache for the staff UI, or the seed job was not re-run | hard reload the page; `./oan.sh rerun <release>-db-seed` |
| `not on GHCR (yet)` during `up` | a package is not published or not public | the stack builds from source instead; see docs/images-and-seed-data.md |
