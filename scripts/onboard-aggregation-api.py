"""Helper of scripts/onboard.sh for the aggregation-api component. Runs inside python:3.12-slim
(httpx and cryptography installed), with the repository mounted at /w and the oan-aggregation-api
checkout at /src.

  admin-password   print the Keycloak admin password pinned in state/secrets.json
  prep             let the staff realm's public client consent-manager-ui use the password grant
                   (register-aggregator.py logs in as a staff user through it; the chart's client
                   only allows the browser flow)
  pin              copy what register-aggregator.py produced into state/secrets.json
"""
import json
import os
import pathlib
import secrets
import sys

STATE = pathlib.Path("/w/state/secrets.json")
SIGNING = "commons/aggregation-api-signing-rsa-20261023"
RUNTIME = "commons/aggregation-api-runtime"
KC = os.environ.get("G2P_KEYCLOAK", "http://commons-keycloak.commons.svc.cluster.local")


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


def admin_password():
    return load()["commons/commons-keycloak"]["admin-password"]


def prep():
    import httpx
    t = httpx.post(KC + "/realms/master/protocol/openid-connect/token", timeout=20, data={
        "grant_type": "password", "client_id": "admin-cli",
        "username": "admin", "password": admin_password()})
    t.raise_for_status()
    h = {"Authorization": "Bearer " + t.json()["access_token"]}
    base = KC + "/admin/realms/staff/clients"
    found = httpx.get(base, headers=h, params={"clientId": "consent-manager-ui"}, timeout=20).json()
    if not found:
        raise SystemExit("client consent-manager-ui not found in realm staff (is the stack up?)")
    c = found[0]
    if c.get("directAccessGrantsEnabled"):
        print("consent-manager-ui already allows the password grant")
        return
    c["directAccessGrantsEnabled"] = True
    httpx.put(base + "/" + c["id"], headers=h, json=c, timeout=20).raise_for_status()
    print("consent-manager-ui: password grant enabled")


def env_value(path, key):
    for line in pathlib.Path(path).read_text().splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return ""


def pin():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.serialization import pkcs12
    p12 = pathlib.Path("/src/deploy/keys/aggregation-layer.p12")
    key, _cert, _ = pkcs12.load_key_and_certificates(p12.read_bytes(), None)
    state = load()
    signing = state.setdefault(SIGNING, {})
    # The chart reads the password from the Secret and always passes it; the script's own file
    # has none, so the pinned copy is the same key encrypted with the synthesized password.
    password = signing.get("password") or secrets.token_urlsafe(24)
    blob = pkcs12.serialize_key_and_certificates(
        b"aggregation-layer", key, None, None,
        serialization.BestAvailableEncryption(password.encode()))
    signing["password"] = password
    signing["aggregation.p12"] = blob.decode("latin-1")
    secret = env_value("/src/deploy/.env", "AGGREGATION_LAYER_CM_CLIENT_SECRET")
    if not secret:
        raise SystemExit("deploy/.env has no AGGREGATION_LAYER_CM_CLIENT_SECRET")
    state.setdefault(RUNTIME, {})["AGGREGATION_LAYER_CM_CLIENT_SECRET"] = secret
    save(state)
    print("pinned %s (password, aggregation.p12) and %s (CM client secret)" % (SIGNING, RUNTIME))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "admin-password":
        print(admin_password())
    elif mode == "prep":
        prep()
    elif mode == "pin":
        pin()
    else:
        raise SystemExit(__doc__)
