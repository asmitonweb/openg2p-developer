# OAN commons services

Three components of kind `service` live in the COSS `openg2p-commons-services` chart (namespace
`commons`) and are switched on by a Helm value (field 11 of `scripts/components.sh`). They are
not registries: they have no project of their own and run in the `commons` Compose project.

| Component | What it is | Chart switch |
| --- | --- | --- |
| `consent-manager` | Consent Manager: staff API (`commons-services-cm-api`), partner API (`commons-services-cm-partner-api`), admin UI, sanity job. Part of commons; always rendered. | none |
| `aggregation-api` | Aggregation layer: one query over the registries, each hop authorised through the Consent Manager and signed with its own key. Host http://aggregation.openg2p.localtest.me | `aggregationApi.enabled=true` |
| `consent-partner-portal` | Portal for consent partners (`commons-services-cm-partner-portal`) | `consentPartnerPortal.enabled=true` |

`aggregation-api` and `consent-partner-portal` require `consent-manager`, which is pulled in
automatically.

## Selecting

```bash
./oan.sh select                              # checklist, saved to .env (OAN_COMPONENTS)
./oan.sh render farmer aggregation-api       # or name the components directly
```

The selection decides the `--set` flags passed to `helm template` for the commons-services chart.
The aggregation catalogue lists the registries it may query (farmer, livestock, crop sown); an
entry whose registry is not selected is simply unreachable.

## Images

Built from the forks of the COSS repositories (`consent-management`, `oan-aggregation-api`, branch
`develop`) and published as `ghcr.io/asmitonweb/commons/<role>:latest` (roles: `consent-manager-api`,
`consent-manager-sanity`, `consent-manager-ui`, `consent-partner-portal`, `aggregation-api`).
`images.yaml` and `docs/images-and-seed-data.md` describe how the chart's ECR references are
remapped; `./oan.sh build` builds a role from a local checkout.

## Objects the chart expects (extras)

The aggregation-api chart values mount three objects "provisioned outside the chart". The file
`extras/aggregation-api.yaml` supplies them; `scripts/render.sh` passes `extras/<component>.yaml`
of every selected component to `gen.py` in that component's namespace.

- ConfigMap `aggregation-api-catalog` (`registries.yaml`): upstream `deploy/registries.yaml` with the
  registry URLs set to the local service aliases (`<service>.<namespace>.svc.cluster.local`).
- Secret `aggregation-api-runtime`: the `AGGREGATION_LAYER_*` settings the chart does not set
  (Consent Manager token URL, client id, client secrets).
- Secret `aggregation-api-signing-rsa-20261023`: `password` and `aggregation.p12` (Ed25519 key).

Client secrets and the key start empty; the onboarding fills them (see below).

## Onboarding aggregation-api

The service cannot sign or call the Consent Manager until it exists as a partner. With the stack
running (`./oan.sh up`, Keycloak, Partner Management and the Consent Manager healthy):

```bash
./oan.sh onboard aggregation-api      # scripts/onboard.sh aggregation-api
```

It runs the upstream `scripts/register-aggregator.py` (checkout in `oan-workspace/oan-aggregation-api`, cloned
if missing) in a `python:3.12-slim` container on the `openg2p` network, so nothing is installed on
the host. The script is re-runnable. It:

1. creates the Keycloak client `aggregation-layer` (staff realm, role `CONSENT_MANAGER_ADMIN`);
2. generates the Ed25519 key `deploy/keys/aggregation-layer.p12` (once, never overwritten);
3. registers partner `PARTNER_AGGREGATION_LAYER` with key `agg-2026-01` in Partner Management;
4. creates one Consent Manager binding per catalogue entry and approves its own AWE tasks;
5. writes the client secret to `deploy/.env`.

Around it, `onboard.sh` lets the staff client `consent-manager-ui` use the password grant (the
script logs in as the seeded staff user `admin`; override with `OAN_STAFF_USER` and
`OAN_STAFF_PASSWORD`), then writes to `state/secrets.json`:

- `commons/aggregation-api-signing-rsa-20261023`: `aggregation.p12` (the generated key, re-encrypted with
  `password`, because the chart always passes a password and the script's file has none) and
  `password` (kept if already pinned, else generated);
- `commons/aggregation-api-runtime`: `AGGREGATION_LAYER_CM_CLIENT_SECRET`.

Finally it re-renders the selection and recreates `commons-services-aggregation-api--pod`. The Consent
Manager caches policies for up to 60 seconds, so wait before the first request.

Known limits: the staff search client `aggregation-layer-staff` is not created by the script, so
`AGGREGATION_LAYER_STAFF_API_CLIENT_SECRET` stays empty; the chart's `AGGREGATION_LAYER_CM_BASE_URL`
points at the CM partner API, and its Keycloak token URL for staff search uses the public host name.

## Partner realm

The partner-facing parts (consent partner portal, aggregation API partner tokens) use a Keycloak
realm named `partner` that the COSS chart expects to exist already. Locally
`values/commons-services.yaml` adds it to the commons-services `keycloak-init` job: a public
client `consent-partner-portal` with the local redirect URI and a test user `partner` (password
`partner`). This mirrors what was created by hand on the dev cluster and has not been verified
end-to-end against the portal yet; if the login still fails, compare the realm in
http://keycloak.openg2p.localtest.me with the portal's `config.json` in `out/files/`.
