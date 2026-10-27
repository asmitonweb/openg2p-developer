# Contributing

This guide covers two things: contributing to **this repository** (the developer stack) and
contributing to an **OAN registry** using it. The second part is the important one.

## The rule that shapes everything: the platform is not ours to change

OAN registries are extensions of the OpenG2P registry platform. Everything OAN-specific lives in
the registry's own repository and reaches the running system through the extension points the
platform provides. We **never**:

- modify, fork-and-patch, or rebuild an upstream image (`openg2p/*`, Keycloak, MOSIP, …);
- edit files inside upstream Python packages or the upstream staff UI at image build time;
- vendor a changed copy of an upstream chart's templates beyond what oan-helm already does for
  commons-services (configuration, additional templates, no edits to vendored ones);
- open pull requests against OpenG2P repositories to carry OAN behaviour.

If something cannot be done through an extension point, the answer is a change request to
OpenG2P (upstream owns the platform) or a documented gap, not a patch. Platform behaviour is
defined by [docs.openg2p.org](https://docs.openg2p.org); when the docs and an image disagree,
the docs decide what we ask upstream for.

### How a registry is extended

| You want to | You change | Not |
| --- | --- | --- |
| Add or change a register, section, field, enum | `register-metadata` (JSON/SQL seed in the extension) | Python models |
| Change what staff see on a tab or in a form | widget metadata (`widgets`, `show/hide` rules, header sections) | the staff UI source |
| Validate a coded value | Master Data code lists (country pack, `domains`) + `REGISTRY_CORE_VALIDATE_ATTRIBUTE_VALUES` | custom validators |
| Add geography | the Master Data country pack (openg2p-data `packs/ETH-OAN`) | SQL into the registry DB |
| Add an approval step | AWE policy/stage/approver metadata (`awe_meta_data`) | code in the approval flow |
| Add a derived table for reporting | the registry's reporting views (`fr_rpt_*`, `cs_rpt_*`, `lr_rpt_*`) | queries from a dashboard against core tables |
| Add behaviour that truly needs code | the extension package (`*-extension/`), through the platform's extension module hooks | the platform package |
| Change how it is deployed | the registry's chart in oan-helm (values, additional templates) | the upstream `openg2p-registry` subchart |

Registry images are **layers on the published platform images**: `FROM openg2p/openg2p-registry-<role>:<version>`
(or the farmer images on top of `openg2p/openg2p-farmer-registry-<role>`), adding the extension
package, metadata and seeds. The platform version is a pinned build argument; bumping it is a
deliberate, reviewed change (`RP_VERSION` / `FARMER_VERSION` in the Dockerfiles, and the matching
`openg2p-registry` dependency in the chart).

Known exceptions in today's images (celery task patches in crop, `core-patches` in livestock,
UI `patch-*.js` files, farmer deleting base AWE SQL) are debts, not patterns. Each needs an
upstream issue or a metadata-driven replacement; do not add new ones.

### Workflow for a registry change

The step-by-step version with commands is [docs/developing-a-registry.md](docs/developing-a-registry.md).

1. `./oan.sh dev <component>`: the COSS repository is cloned into `oan-workspace/<repo>` (branch
   `develop`), the images are built from it and the stack starts.
2. Fork the repository on GitHub, make the fork `origin` and COSS `upstream`, and branch from the
   newest `develop`; never commit on `develop`. Plain git, in `oan-workspace/<repo>`.
3. Edit the source there (or point `OAN_<ID>_SRC` at a checkout of your own).
4. `./oan.sh reload <component> <role...>` rebuilds the images you touched and restarts their
   services; for metadata/seed changes also `./oan.sh rerun <release>-db-seed`.
   Metadata is applied as a **whole tree** by the seed job; never apply one file by hand.
5. Add or update tests in the repository (schema/metadata validation, sanity tests) and run them
   the way the repository's CI does.
6. Commit, rebase onto `upstream/develop`, push to your fork and open the pull request against the
   COSS repository's `develop`. Describe the behaviour, not the ticket number. The delivery
   pipeline promotes `develop → testing → staging → release`.
7. If the change needs a chart change (new env var, new job), make the oan-helm change in the
   same review cycle and bump the chart pin here (`versions.env`) once it is released.

Every register change in every registry goes through the approval workflow (AWE). Do not add
"finalize" shortcuts that bypass it.

## Contributing to this repository

Keep the stack a faithful rendering of the charts. Prefer, in this order:

0. **`scripts/components.sh`**: a new selectable thing (a registry, a commons service switched on
   by a chart value, an add-on chart). One line: chart, release, namespace, COSS repository,
   image product and roles with their Dockerfiles, the Helm values that enable it, what it
   requires. Then `values/<id>.yaml` for an add-on, `<ID>_VERSION` in `versions.env`, and
   `ci/install-fork-workflow.sh <id>` to publish its images from a fork.
1. **`versions.env`**: a new chart version. Run `./oan.sh render`, start a registry, check
   `out/REPORT.md` for new warnings or skipped objects, commit the pin.
2. **`values/<layer>.yaml`**: a value the chart exposes (hostname, toggle, env var). This is also
   what the dev cluster would set, so the local stack stays comparable.
3. **`images.yaml`**: an image that exists only in the private registry and has a public
   equivalent.
4. **`overrides/<ns>.yaml`**: Compose-only, local-resource tweaks (worker counts, heap sizes,
   single-node Kafka). Nothing behavioural goes here.
5. **`scripts/gen.py`**: a Kubernetes construct the translator does not handle. Add it generically
   (for every chart), document the rule in the docstring, and add the object to the report if it
   is skipped rather than silently dropping it.

Never commit `out/`, `rendered/`, `.cache/`, `state/` or `oan-workspace/` (git-ignored). `state/secrets.json`
holds generated passwords for your volumes; `out/files` holds rendered secrets.

Scripts must stay POSIX-bash compatible with Git for Windows bash and LF line endings
(`.gitattributes` enforces it). Anything that runs inside a container is bind-mounted from
`out/files`, so a CRLF file breaks silently at runtime.

Pull requests to this repository go to `oan-developer`. CI renders every registry and checks
that the compose files validate, that no private host or image leaks into them, and that every
referenced image either is a local build target or is publicly pullable.

Commit messages describe the change; no ticket keys, no tool attributions.
