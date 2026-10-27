# Developing a registry

How to change an OAN registry (farmer, crop, live, da) with this stack: from a fork of the COSS
repository, through a running local build of your branch, to a pull request on COSS `develop`.
The rule behind every step is in [CONTRIBUTING.md](../CONTRIBUTING.md): the OpenG2P platform is
never modified; a registry is extended through metadata, configuration and its extension package.

## The two image sources

| Mode | `OAN_IMAGE_SOURCE` | Registry images | For |
| --- | --- | --- | --- |
| **use** | `ghcr` (default) | `ghcr.io/asmitonweb/<product>/<role>:latest`, built every 30 minutes from COSS `develop` | running a registry, testing someone else's change, demos |
| **develop** | `local` | `oan/<product>/<role>:local`, built from the checkout in `src/<repo>` | changing a registry |

`./oan.sh dev <registry>` switches to develop mode: it writes `OAN_IMAGE_SOURCE=local` to `.env`,
creates the source checkout if it is missing, builds the images from it and starts the stack.
Commons (layers 1 and 2) are the same published images in both modes. To go back to published
images, set `OAN_IMAGE_SOURCE=ghcr` in `.env` and run `./oan.sh up <registry>`.

## One-time setup

1. Decide where your branches will be pushed. A fork is **not required**; `clone` picks `origin`
   in this order:
   - [GitHub CLI](https://cli.github.com) logged in (`gh auth login`): your fork, created for you
     if it does not exist;
   - `OAN_GITHUB_USER=<you>` in `.env` and a fork at `github.com/<you>/<repo>` (create it with
     the **Fork** button on the COSS repository): that fork, no gh needed;
   - neither: the COSS repository itself. This works if you have push rights there (COSS
     maintainers do). Otherwise create a fork in the browser later and run
     `./oan.sh src fork <registry> <you>`; it only re-points `origin`, your branches stay.
2. Make sure your Git has no CRLF conversion for these checkouts. The scripts clone with
   `core.autocrlf=false`; a CRLF checkout breaks every container entrypoint, and `build` refuses
   to build one.
3. First start, which also forks and clones (about 15 minutes for the image builds):

```bash
./oan.sh dev farmer          # Windows: oan.cmd dev farmer
```

What `dev` does to the source:

```
src/farmer-registry/
  origin    https://github.com/<you>/farmer-registry             your fork, where branches are pushed
  upstream  https://github.com/Centre-for-Open-Societal-Systems/farmer-registry   read-only for you
  develop   tracks upstream/develop; never commit on it
```

With push rights on the COSS repository you may push branches there directly (`origin` =
`upstream`); a fork is still the recommended default because it keeps the shared branch list
clean. `./oan.sh src status` shows which one you have.

To work from a checkout you already have, point `OAN_FARMER_SRC` (`OAN_CROP_SRC`,
`OAN_LIVE_SRC`) or `OAN_SRC_DIR` at it in `.env`. The scripts never modify a checkout they did not
create, apart from the git operations you ask for (`branch`, `sync`, `pr`).

## The change loop

```bash
./oan.sh src branch farmer odk-geo-codes     # 1. branch from the newest upstream develop
#   ... edit src/farmer-registry ...          # 2. metadata, widgets, extension package, seeds
./oan.sh reload farmer staff-api             # 3. rebuild the touched roles, restart their services
./oan.sh reload farmer db-seed               #    metadata or seed change: rebuild, then
./oan.sh rerun farmer-registry-db-seed       #    re-run the seed job (metadata is applied as a whole tree)
./oan.sh logs farmer-registry-staff-portal-api--pod   # container names = service names (./oan.sh ps)
./oan.sh src status                          # 4. what branch, how far from upstream, uncommitted files
git -C src/farmer-registry add -p && git -C src/farmer-registry commit
./oan.sh src sync farmer                     # 5. rebase onto upstream develop before you push
./oan.sh src pr farmer                       # 6. push to your fork, open the PR on COSS develop
```

### Which role runs what

| Role | Service(s) in the farmer project | Rebuild when you change |
| --- | --- | --- |
| `staff-api` | `farmer-registry-staff-portal-api--pod` | the extension package (`*-extension/src`), API behaviour, Python dependencies |
| `partner-api` | `farmer-registry-partner-api--pod` | partner-facing API, connector code |
| `celery` | `farmer-registry-celery-worker`, `farmer-registry-celery-beat-producer` | tasks, schedules |
| `db-seed` | `farmer-registry-db-seed` (job), `farmer-registry-fr-reporting-views` (job) | register metadata, widgets, AWE metadata, seeds, reporting views |
| `staff-ui` | `farmer-registry-staff-portal-ui--pod` | UI widgets and translations |

`reload` finds the services from the compose file, so the table is only an orientation. Crop and
livestock use the same roles with their own release prefix (`cropsown-registry-…`,
`livestock-registry-…`). Jobs are never restarted automatically: `reload` prints the `rerun`
command for them.

### Tests

Run the registry's own tests before you open a pull request. They live in the registry repository
and its CI (`.github/workflows/checks.yml`, `Jenkinsfile`) is the reference for what is checked:

```bash
cd src/farmer-registry
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

Crop and livestock ship a `docker/sanity-tests/Dockerfile` for the same purpose. A metadata change is tested by `./oan.sh rerun <release>-db-seed` finishing with
exit code 0 and the form behaving as intended in the staff UI; add a schema or sanity test for it
in the repository's test folder.

## Branches, commits, pull requests

- **Branch names** describe the change: `odk-geo-codes`, `intake-photo-section`,
  `livestock-species-list`. No ticket keys, no personal prefixes.
- **One change per branch.** A metadata change and an unrelated extension fix are two pull
  requests; reviewers and the delivery pipeline treat them independently.
- **Commits** have a short imperative subject (under 72 characters) and a body that says what
  changed and why, not how it was produced. No ticket keys, no tool attributions, no
  `Co-Authored-By` trailers for tools. Squash fix-up commits before the PR, or ask for a squash merge.
- **Never commit on `develop`**, and never push to `upstream`. `./oan.sh src sync` keeps your
  fork's `develop` equal to upstream's and rebases your branch onto it; resolve conflicts in
  `src/<repo>` and continue the rebase there.
- **Pull requests** target the COSS repository's `develop` (`./oan.sh src pr` sets base and head).
  Describe the behaviour and how you verified it against the local stack, list the metadata or
  roles touched, and link the upstream issue if the change works around a platform gap. The
  repository's CI must be green. The delivery pipeline promotes `develop → testing → staging → release`.
- **A chart change** (new env var, job, volume) goes to [oan-helm](https://github.com/Centre-for-Open-Societal-Systems/oan-helm)
  in the same review cycle. Once the chart is released, bump its pin in `versions.env` here.
- **Merged?** `./oan.sh src sync <registry>` brings the merged commit back, and within 30 minutes
  the published `:latest` image carries it, so `OAN_IMAGE_SOURCE=ghcr` users get it on their next
  `./oan.sh pull <registry>`.

## What you must not do

The complete list is in [CONTRIBUTING.md](../CONTRIBUTING.md). The ones that come up most:

- editing files of the upstream `openg2p-registry` packages or the upstream staff UI, even inside
  a Dockerfile `RUN` step (the known `patch-*.js` and `core-patches` are debts, not patterns);
- changing the pinned platform version (`RP_VERSION`, `FARMER_VERSION`) as a side effect of a feature;
- applying one metadata file by hand with `psql`: the seed job applies the whole tree and resets
  partial changes;
- adding a "finalize" shortcut that bypasses the approval workflow (AWE);
- committing anything generated: `out/`, `state/`, `src/` and `.env` are git-ignored here, and the
  registry repositories ignore their build outputs.

## Several registries, several developers

Commons is shared; registries are independent Compose projects. `./oan.sh dev crop` next to a
running farmer registry adds the crop project and clones `src/cropsown-regsitry` (the COSS
repository name is spelled that way). `./oan.sh src status` shows every checkout at once. Two
people never share a `src/` folder; each clone has its own fork as `origin`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `exec /…/entrypoint.sh: no such file or directory` in a container | CRLF checkout | the message printed by `build` gives the three git commands |
| `reload` says `nothing rendered` | you are in ghcr mode or never started this registry | `./oan.sh dev <registry>` |
| `rebase stopped on a conflict` | your branch and upstream changed the same file | resolve in `src/<repo>`, `git rebase --continue`, then `./oan.sh reload` |
| images rebuilt but the UI shows the old behaviour | browser cache for the staff UI, or the seed job was not re-run | hard reload the page; `./oan.sh rerun <release>-db-seed` |
| `no fork found: origin is Centre-for-Open-Societal-Systems/… itself` | no gh session and no `OAN_GITHUB_USER` fork | fine with push rights; otherwise fork in the browser, then `./oan.sh src fork <registry> <you>` |
| `src pr` fails on push | `origin` is COSS and you have no push rights | same: fork in the browser, `./oan.sh src fork <registry> <you>`, run `pr` again |
