"""Translate rendered Helm manifests into one Docker Compose project per namespace.

Mapping:
- Deployment / StatefulSet -> long-running service (extra containers share its
  network namespace, as in a pod).
- Job -> one-shot service restarted on failure up to its backoffLimit.
- init container -> one-shot service the pod's main container waits for.
- Service -> network aliases (short name, .ns, .ns.svc, .ns.svc.cluster.local).
  They sit on the backing container when every Service port equals its
  container port; otherwise on the gateway (HTTP, routed by Host header) or a
  socat forwarder (TCP).
- VirtualService -> gateway route on host port 80. The gateway also answers
  those host names inside the network, so browser and containers use one URL.
- ConfigMap / Secret volumes -> files under out/files, bind-mounted.
- emptyDir / PVC / volumeClaimTemplate -> named volumes.

Each namespace becomes out/<ns>/compose.yaml (project <ns>) on one shared
network, so Service DNS still crosses namespaces as in the cluster. Within a
project each Helm (sub)chart becomes a compose profile. Secret values are kept in
state/secrets.json so a re-render never rotates a password the databases
already hold. Usage: gen.py rendered/<name>.yaml=<namespace> ...
"""

from __future__ import annotations

import base64
import json
import os
import re
import secrets
import shutil
import sys
from collections import defaultdict
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent.parent  # repo root
OUT = HERE / "out"
FILES = OUT / "files"
STATE = HERE / "state" / "secrets.json"

NETWORK = "openg2p"  # external, shared by every namespace project; stack.sh creates it
VOLUME_PREFIX = "openg2p_"  # pinned so moving a service between projects keeps its data
NS = "x-namespace"  # internal marker, stripped before writing
EDGE_NS = "commons"  # namespace project that owns the gateway
LOCAL_DOMAIN = "openg2p.localtest.me"
GATEWAY = "gateway"
GATEWAY_IMAGE = "nginx:1.27-alpine"
FORWARDER_IMAGE = "alpine/socat:1.8.0.1"
CLIENT_SECRETS_IMAGE = "alpine:3.20"
HOST_PORTS = {"commons-postgresql": {5432: 5433}}  # container port -> host port
WORKLOADS = ("Deployment", "StatefulSet", "Job")
# Jobs that only copy Keycloak client secrets back into Kubernetes Secrets via the
# API server; keycloak-init already applies the rendered values.
SKIP_JOBS = re.compile(r"client-secrets-sync")
# Hostnames the charts hard-code, rewritten to the local domain: the upstream
# subchart defaults (<svc>.<namespace>.openg2p.org) and the OAN dev environment
# the COSS charts pin (OAN_REMOTE_DOMAINS, comma separated, in the environment).
REMOTE_DOMAINS = [d.strip() for d in os.environ.get("OAN_REMOTE_DOMAINS", "development.oanstaging.com").split(",") if d.strip()]
_DOM = "|".join([r"[a-z0-9-]+\.openg2p\.org", *(re.escape(d) for d in REMOTE_DOMAINS)])
HOST_REWRITES = [(re.compile(rf"\b([a-z0-9-]+)\.(?:{_DOM})\b"), rf"\1.{LOCAL_DOMAIN}"),
                 (re.compile(rf"(?<![a-z0-9-])\.(?:{_DOM})\b"), f".{LOCAL_DOMAIN}")]
# Private registries the charts reference (AWS ECR), remapped to images a developer
# can pull or build: <prefix>/<product>/<role>:<tag>, digest dropped.
#   OAN_IMAGE_PREFIX  ghcr.io/centre-for-open-societal-systems (default) or "oan" for local builds
#   OAN_IMAGE_TAG     keep the chart's tag when empty; "local" for local builds
IMAGE_PREFIX = os.environ.get("OAN_IMAGE_PREFIX", "ghcr.io/centre-for-open-societal-systems")
IMAGE_TAG = os.environ.get("OAN_IMAGE_TAG", "")
PRIVATE_IMAGE = re.compile(r"^\d+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/(?:openg2p|gen2|oan)/(?P<product>[a-z0-9-]+)/(?P<role>[a-z0-9-]+)(?::(?P<tag>[^@]+))?(?:@sha256:[0-9a-f]+)?$")
remapped_images: dict[str, str] = {}
# images.yaml (repo root): explicit rewrites tried first, e.g. a private build of a
# commons service -> the published upstream image. {match: <regex>, replace: <repl>}
IMAGE_RULES: list[tuple[re.Pattern[str], str]] = []
if (HERE / "images.yaml").exists():
    for rule in (yaml.safe_load((HERE / "images.yaml").read_text(encoding="utf-8")) or {}).get("rewrites") or []:
        IMAGE_RULES.append((re.compile(rule["match"]), rule["replace"]))


def localize_image(image: str) -> str:
    for pattern, repl in IMAGE_RULES:
        if pattern.search(image):
            new = pattern.sub(repl, image)
            remapped_images[image] = new
            return new
    m = PRIVATE_IMAGE.match(image)
    if not m:
        return image
    tag = IMAGE_TAG or m["tag"] or "latest"
    new = f"{IMAGE_PREFIX}/{m['product']}/{m['role']}:{tag}"
    remapped_images[image] = new
    return new


warnings: list[str] = []
named: set[str] = set()  # compose named volumes


def warn(msg: str) -> None:
    warnings.append(msg)


# ── loading ──────────────────────────────────────────────────────────────────


def load(args: list[str]) -> list[dict]:
    docs = []
    for arg in args:
        path, ns = arg.split("=", 1)
        for d in yaml.safe_load_all(Path(path).read_text(encoding="utf-8")):
            if d:
                d.setdefault("metadata", {})["namespace"] = d["metadata"].get("namespace") or ns
                docs.append(d)
    return docs


def group_of(d: dict) -> str:
    labels = d["metadata"].get("labels") or {}
    chart = labels.get("helm.sh/chart") or labels.get("chart") or labels.get("app.kubernetes.io/instance") or "misc"
    chart = re.sub(r"-v?\d+\.\d+.*$", "", chart)
    return chart.removeprefix("openg2p-")


# ── secrets and config ───────────────────────────────────────────────────────


class Store:
    """ConfigMaps and Secrets by (namespace, name); Secret values pinned in state."""

    def __init__(self, docs: list[dict]) -> None:
        self.state: dict[str, dict[str, str]] = json.loads(STATE.read_text()) if STATE.exists() else {}
        self.cms: dict[tuple[str, str], dict[str, bytes]] = {}
        self.secrets: dict[tuple[str, str], dict[str, bytes]] = {}
        self.synthesized: list[str] = []
        for d in docs:
            key = (d["metadata"]["namespace"], d["metadata"]["name"])
            if d["kind"] == "ConfigMap":
                data = {k: v.encode() for k, v in (d.get("data") or {}).items()}
                data |= {k: base64.b64decode(v) for k, v in (d.get("binaryData") or {}).items()}
                self.cms[key] = data
            elif d["kind"] == "Secret":
                data = {k: base64.b64decode(v) for k, v in (d.get("data") or {}).items()}
                data |= {k: str(v).encode() for k, v in (d.get("stringData") or {}).items()}
                pinned = self.state.setdefault(f"{key[0]}/{key[1]}", {})
                for k, v in data.items():
                    if k in pinned:
                        data[k] = pinned[k].encode("latin-1")
                    else:
                        pinned[k] = v.decode("latin-1")
                self.secrets[key] = data

    def secret(self, ns: str, name: str, key: str, optional: bool) -> str | None:
        data = self.secrets.get((ns, name))
        if data is not None and key in data:
            return data[key].decode("latin-1")
        # Installers copy shared Secrets (database, MinIO, Keycloak admin) into each
        # registry namespace under the same name; read the original.
        for (other_ns, other), data in self.secrets.items():
            if other == name and other_ns != ns and key in data:
                return data[key].decode("latin-1")
        if optional:
            return None
        # Created at runtime on Kubernetes (by a job talking to the API server):
        # synthesize a stable value instead.
        pinned = self.state.setdefault(f"{ns}/{name}", {})
        if key not in pinned:
            pinned[key] = secrets.token_urlsafe(24)
        self.secrets.setdefault((ns, name), {})[key] = pinned[key].encode()
        self.synthesized.append(f"{ns}/{name}:{key}")
        return pinned[key]

    def cm(self, ns: str, name: str, key: str, optional: bool) -> str | None:
        data = self.cms.get((ns, name))
        if data is not None and key in data:
            return data[key].decode("utf-8", "replace")
        if not optional:
            warn(f"missing ConfigMap key {ns}/{name}:{key}")
        return None

    def save(self) -> None:
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(self.state, indent=2, sort_keys=True) + "\n")


def localize(s: str) -> str:
    """Local endpoints are plain HTTP behind the gateway."""
    for pattern, repl in HOST_REWRITES:
        s = pattern.sub(repl, s)
    return re.sub(rf"\b(https|wss)://([a-z0-9.-]*{re.escape(LOCAL_DOMAIN)})", lambda m: ("http" if m[1] == "https" else "ws") + "://" + m[2], s)


def esc(s: str) -> str:
    return s.replace("$", "$$")


def expand(s: str, env: dict[str, str]) -> str:
    return re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)", lambda m: env.get(m[1], m[0]), s)


# ── pods ─────────────────────────────────────────────────────────────────────


def pod_spec(d: dict) -> dict:
    return d["spec"]["template"]["spec"]


def pod_name(d: dict) -> str:
    return d["metadata"]["name"] + ("-0" if d["kind"] == "StatefulSet" else "")


def mem(limit: str | None) -> str | None:
    if not limit:
        return None
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi|K|M|G)?", str(limit))
    if not m:
        return None
    n, unit = float(m[1]), (m[2] or "")
    factor = {"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3}[unit]
    return f"{int(n * factor / 1024**2)}m"


def resolve_env(c: dict, ns: str, pod: str, store: Store) -> dict[str, str]:
    env: dict[str, str] = {}
    for src in c.get("envFrom") or []:
        prefix = src.get("prefix", "")
        if "configMapRef" in src:
            ref = src["configMapRef"]
            data = store.cms.get((ns, ref["name"]))
            if data is None:
                if not ref.get("optional"):
                    warn(f"{pod}: envFrom ConfigMap {ref['name']} not rendered")
                continue
            env |= {prefix + k: v.decode() for k, v in data.items()}
        elif "secretRef" in src:
            ref = src["secretRef"]
            data = store.secrets.get((ns, ref["name"]))
            if data is None:
                if not ref.get("optional"):
                    warn(f"{pod}: envFrom Secret {ref['name']} not rendered")
                continue
            env |= {prefix + k: v.decode("latin-1") for k, v in data.items()}
    for e in c.get("env") or []:
        name = e["name"]
        if "value" in e:
            env[name] = expand(str(e["value"]), env)
            continue
        vf = e.get("valueFrom") or {}
        if "secretKeyRef" in vf:
            r = vf["secretKeyRef"]
            v = store.secret(ns, r["name"], r["key"], bool(r.get("optional")))
        elif "configMapKeyRef" in vf:
            r = vf["configMapKeyRef"]
            v = store.cm(ns, r["name"], r["key"], bool(r.get("optional")))
        elif "fieldRef" in vf:
            v = {
                "metadata.name": pod,
                "metadata.namespace": ns,
                "status.podIP": pod,
                "spec.nodeName": "local",
                "status.hostIP": "host-gateway",
            }.get(vf["fieldRef"]["fieldPath"])
            if v is None:
                warn(f"{pod}: unsupported fieldRef {vf['fieldRef']['fieldPath']} for {name}")
        else:
            v = None
            warn(f"{pod}: unsupported valueFrom for {name}")
        if v is not None:
            env[name] = v
    return {k: localize(v) for k, v in env.items()}


def write_files(base: Path, data: dict[str, bytes], items: list[dict] | None) -> None:
    base.mkdir(parents=True, exist_ok=True)
    pairs = [(i["key"], i["path"]) for i in items] if items else [(k, k) for k in data]
    for key, rel in pairs:
        if key not in data:
            warn(f"volume item {key} missing for {base.relative_to(OUT)}")
            continue
        f = base / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        raw = data[key]
        try:
            raw = localize(raw.decode("utf-8")).encode("utf-8")
        except UnicodeDecodeError:
            pass
        f.write_bytes(raw)


def pod_volumes(d: dict, ns: str, pod: str, store: Store, named: set[str]) -> dict[str, tuple[str, str]]:
    """volume name -> (kind, compose source). kind is 'bind' or 'volume'."""
    vols: dict[str, tuple[str, str]] = {}
    spec = pod_spec(d)
    for v in spec.get("volumes") or []:
        name = v["name"]
        target = FILES / pod / name
        if "configMap" in v:
            ref = v["configMap"]
            data = store.cms.get((ns, ref["name"]))
            if data is None:
                if not ref.get("optional"):
                    warn(f"{pod}: ConfigMap volume {ref['name']} not rendered")
                data = {}
            write_files(target, data, ref.get("items"))
            vols[name] = ("bind", target)
        elif "secret" in v:
            ref = v["secret"]
            data = store.secrets.get((ns, ref["secretName"]))
            if data is None:
                if not ref.get("optional"):
                    warn(f"{pod}: Secret volume {ref['secretName']} not rendered")
                data = {}
            write_files(target, data, ref.get("items"))
            vols[name] = ("bind", target)
        elif "projected" in v:
            for src in v["projected"].get("sources") or []:
                if "configMap" in src:
                    write_files(target, store.cms.get((ns, src["configMap"]["name"]), {}), src["configMap"].get("items"))
                elif "secret" in src:
                    write_files(target, store.secrets.get((ns, src["secret"]["name"]), {}), src["secret"].get("items"))
            target.mkdir(parents=True, exist_ok=True)
            vols[name] = ("bind", target)
        elif "emptyDir" in v:
            vname = f"{pod}--{name}"
            named.add(vname)
            vols[name] = ("volume", vname)
        elif "persistentVolumeClaim" in v:
            vname = f"pvc-{v['persistentVolumeClaim']['claimName']}"
            named.add(vname)
            vols[name] = ("volume", vname)
        else:
            warn(f"{pod}: unsupported volume {name} ({', '.join(k for k in v if k != 'name')})")
    for vct in d["spec"].get("volumeClaimTemplates") or [] if d["kind"] == "StatefulSet" else []:
        vname = f"{d['metadata']['name']}-{vct['metadata']['name']}"
        named.add(vname)
        vols[vct["metadata"]["name"]] = ("volume", vname)
    return vols


def mounts(c: dict, vols: dict[str, tuple[str, str]]) -> list[str]:
    out = []
    for m in c.get("volumeMounts") or []:
        if m["name"] not in vols:
            continue
        kind, src = vols[m["name"]]
        ro = ":ro" if m.get("readOnly") else ""
        if kind == "bind":
            path = Path(src) / m["subPath"] if m.get("subPath") else Path(src)
            if m.get("subPath") and not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"")
            out.append(f"./{path.relative_to(OUT).as_posix()}:{m['mountPath']}{ro}")
        else:
            sub = m.get("subPath")
            if sub:
                # A named volume cannot be mounted by sub-directory: give each
                # subPath its own volume (shared by every container that uses it).
                src = f"{src}--{re.sub(r'[^a-zA-Z0-9_.-]', '_', sub)}"
                named.add(src)
            out.append(f"{src}:{m['mountPath']}{ro}")
    return out


def user_of(c: dict, spec: dict) -> tuple[str | None, list[str]]:
    psc, csc = spec.get("securityContext") or {}, c.get("securityContext") or {}
    uid = csc.get("runAsUser", psc.get("runAsUser"))
    gid = csc.get("runAsGroup", psc.get("runAsGroup"))
    user = None if uid is None else (f"{uid}:{gid}" if gid is not None else str(uid))
    groups = [str(psc["fsGroup"])] if "fsGroup" in psc else []
    return user, groups


def container_service(c: dict, spec: dict, ns: str, pod: str, store: Store, vols, profile: str) -> dict:
    env = resolve_env(c, ns, pod, store)
    svc: dict = {"image": localize_image(c["image"]), "profiles": [profile], NS: ns}
    if c.get("command"):
        svc["entrypoint"] = [esc(localize(expand(str(x), env))) for x in c["command"]]
    if c.get("args"):
        svc["command"] = [esc(localize(expand(str(x), env))) for x in c["args"]]
    if env:
        svc["environment"] = {k: esc(v) for k, v in env.items()}
    if c.get("workingDir"):
        svc["working_dir"] = c["workingDir"]
    vm = mounts(c, vols)
    if vm:
        svc["volumes"] = vm
    user, groups = user_of(c, spec)
    if user:
        svc["user"] = user
    if groups:
        svc["group_add"] = groups
    limit = mem(((c.get("resources") or {}).get("limits") or {}).get("memory"))
    if limit:
        svc["mem_limit"] = limit
    return svc


def add_fsgroup_init(name: str, spec: dict, profile: str, inits: list[str], services: dict) -> None:
    """Kubernetes makes pod volumes writable through fsGroup; Docker creates named
    volumes root-owned. Chown them to the pod's user before anything else runs."""
    psc = spec.get("securityContext") or {}
    csc = next((c.get("securityContext") for c in spec.get("containers") or [] if c.get("securityContext")), {}) or {}
    uid = csc.get("runAsUser", psc.get("runAsUser"))
    gid = psc.get("fsGroup", csc.get("runAsGroup", psc.get("runAsGroup", uid)))
    if uid is None and gid is None:
        return
    members = [*inits, *(n for n in services if n == name or n.startswith(f"{name}--") and "--init-" not in n)]
    vols = sorted({v.split(":")[0] for n in members for v in services[n].get("volumes") or [] if not v.startswith("./")})
    if not vols:
        return
    first_member = members[0]
    owner = f"{uid if uid is not None else 0}:{gid if gid is not None else 0}"
    pname = f"{name}--init-fsgroup"
    services[pname] = {
        "image": "busybox:1.36",
        "user": "0:0",
        "entrypoint": ["sh", "-c", f"chown -R {owner} /v && chmod -R g+rwX /v"],
        "volumes": [f"{v}:/v/{i}" for i, v in enumerate(vols)],
        "restart": "no",
        "profiles": [profile],
        "networks": [NETWORK],
        "labels": {"openg2p.local/kind": "init"},
        NS: services[first_member][NS],
    }
    first = inits[0] if inits else name
    services[first].setdefault("depends_on", {})[pname] = {"condition": "service_completed_successfully"}


# ── services and routing ─────────────────────────────────────────────────────


def pod_container(name: str) -> str:
    return f"{name}--pod"


def dns_names(name: str, ns: str) -> list[str]:
    return [name, f"{name}.{ns}", f"{name}.{ns}.svc", f"{name}.{ns}.svc.cluster.local"]


def main(argv: list[str]) -> None:
    docs = load(argv)
    store = Store(docs)
    if FILES.exists():
        shutil.rmtree(FILES)
    services: dict[str, dict] = {}
    pods: list[tuple[dict, str]] = []  # (workload doc, main service name)
    skipped: list[str] = []
    profiles: dict[str, list[str]] = defaultdict(list)

    for d in docs:
        kind, name, ns = d["kind"], d["metadata"]["name"], d["metadata"]["namespace"]
        if kind not in WORKLOADS or (kind == "Job" and SKIP_JOBS.search(name)):
            if kind in ("CronJob", "Pod", "DaemonSet", "Job"):
                skipped.append(f"{kind} {name}")
            continue
        profile = group_of(d)
        pod = pod_name(d)
        spec = pod_spec(d)
        vols = pod_volumes(d, ns, pod, store, named)
        hook = (d["metadata"].get("annotations") or {}).get("helm.sh/hook", "")

        inits = []
        for i, c in enumerate(spec.get("initContainers") or []):
            iname = f"{name}--init-{i}-{c['name']}"
            s = container_service(c, spec, ns, pod, store, vols, profile)
            s["restart"] = "no"
            s["networks"] = [NETWORK]
            if inits:
                s["depends_on"] = {inits[-1]: {"condition": "service_completed_successfully"}}
            services[iname] = s
            inits.append(iname)
            profiles[profile].append(iname)

        for i, c in enumerate(spec.get("containers") or []):
            sname = name if i == 0 else f"{name}--{c['name']}"
            s = container_service(c, spec, ns, pod, store, vols, profile)
            if kind == "Job":
                retries = d["spec"].get("backoffLimit", 6)  # Docker reads on-failure:0 as unlimited
                s["restart"] = f"on-failure:{retries}" if retries else "no"
                s["labels"] = {"openg2p.local/kind": "job", **({"openg2p.local/hook": hook} if hook else {})}
            else:
                s["restart"] = "unless-stopped"
                s["labels"] = {"openg2p.local/kind": kind.lower()}
            if i == 0:
                s["container_name"] = name
                if kind == "StatefulSet":  # Deployment pod names are random; Docker DNS would register this
                    s["hostname"] = pod
                s["networks"] = {NETWORK: {"aliases": []}}
                if inits:
                    s["depends_on"] = {inits[-1]: {"condition": "service_completed_successfully"}}
            else:
                s["network_mode"] = f"service:{name}"
                s["depends_on"] = {name: {"condition": "service_started"}}
            services[sname] = s
            profiles[profile].append(sname)
        add_fsgroup_init(name, spec, profile, inits, services)
        if kind != "Job":
            pods.append((d, name))

    # Service -> aliases / gateway / forwarders
    gateway_http: dict[int, list[tuple[list[str], str, int]]] = defaultdict(list)
    forwarders: dict[str, dict] = {}
    renamed: set[str] = set()  # workloads reached through the gateway or a forwarder
    svc_index: dict[tuple[str, str], tuple[str, dict[int, int]]] = {}  # (ns, svc) -> (backend, port map)
    vs_docs = [d for d in docs if d["kind"] == "VirtualService"]
    vs_targets = {
        (d["metadata"]["namespace"], r["destination"]["host"].split(".")[0])
        for d in vs_docs
        for h in d["spec"].get("http") or []
        for r in h.get("route") or []
    }

    for d in docs:
        if d["kind"] != "Service":
            continue
        name, ns = d["metadata"]["name"], d["metadata"]["namespace"]
        sel = (d["spec"] or {}).get("selector")
        if not sel:
            skipped.append(f"Service {name} (no selector)")
            continue
        backend = None
        for w, main_svc in pods:
            if w["metadata"]["namespace"] == ns and sel.items() <= (w["spec"]["template"]["metadata"].get("labels") or {}).items():
                backend = (w, main_svc)
                break
        if not backend:
            skipped.append(f"Service {name} (selects no rendered workload)")
            continue
        w, main_svc = backend
        cports = {p.get("name"): p["containerPort"] for c in pod_spec(w)["containers"] for p in c.get("ports") or []}
        portmap: dict[int, int] = {}
        httpish = (ns, name) in vs_targets
        for p in d["spec"].get("ports") or []:
            tp = p.get("targetPort", p["port"])
            target = cports.get(tp) if isinstance(tp, str) else int(tp)
            if target is None:
                target = p["port"]
                warn(f"Service {name}: targetPort {tp} not found, assuming {target}")
            portmap[p["port"]] = target
            httpish |= any("http" in str(x).lower() for x in (p.get("name"), tp, p.get("appProtocol")))
        svc_index[(ns, name)] = (main_svc, portmap)
        headless = d["spec"].get("clusterIP") == "None"
        aliases = dns_names(name, ns)
        if headless or all(k == v for k, v in portmap.items()):
            services[main_svc]["networks"][NETWORK]["aliases"] += aliases
            if headless and w["kind"] == "StatefulSet":
                services[main_svc]["networks"][NETWORK]["aliases"] += [f"{pod_name(w)}.{a}" for a in aliases]
        elif httpish:
            renamed.add(main_svc)
            for port, target in portmap.items():
                gateway_http[port].append((aliases, pod_container(main_svc), target))
        else:
            renamed.add(main_svc)
            fname = f"fwd-{name}"
            loops = " & ".join(f"socat TCP-LISTEN:{p},fork,reuseaddr TCP:{pod_container(main_svc)}:{t}" for p, t in portmap.items())
            forwarders[fname] = {
                "image": FORWARDER_IMAGE,
                "entrypoint": ["sh", "-c", f"{loops} & wait"],
                "restart": "unless-stopped",
                "profiles": services[main_svc]["profiles"],
                "networks": {NETWORK: {"aliases": aliases}},
                "labels": {"openg2p.local/kind": "forwarder"},
                NS: ns,
            }
    services |= forwarders
    # Docker DNS answers a container's own name before any alias, and a
    # Deployment is usually named like its Service: rename the backends that sit
    # behind the gateway or a forwarder so the Service name reaches the proxy.
    for old in renamed:
        new = pod_container(old)
        services[new] = services.pop(old)
        services[new]["container_name"] = new
    for s in services.values():
        if "depends_on" in s:
            s["depends_on"] = {(pod_container(k) if k in renamed else k): v for k, v in s["depends_on"].items()}
        if s.get("network_mode", "").removeprefix("service:") in renamed:
            s["network_mode"] = f"service:{pod_container(s['network_mode'].removeprefix('service:'))}"
    svc_index = {k: ((pod_container(b) if b in renamed else b), pm) for k, (b, pm) in svc_index.items()}

    for name, host_ports in HOST_PORTS.items():
        if name in services:
            services[name]["ports"] = [f"127.0.0.1:{h}:{c}" for c, h in host_ports.items()]

    # VirtualService -> external routes (host -> [(match, rewrite, backend, port)])
    routes: dict[str, list[dict]] = defaultdict(list)
    for d in vs_docs:
        ns = d["metadata"]["namespace"]
        for host in d["spec"].get("hosts") or []:
            host = localize(host)
            if not host.endswith(LOCAL_DOMAIN):
                warn(f"VirtualService {d['metadata']['name']}: host {host} outside {LOCAL_DOMAIN}")
            for h in d["spec"].get("http") or []:
                dest = (h.get("route") or [{}])[0].get("destination") or {}
                dhost = dest.get("host", "")
                dns = dhost.split(".")[1] if dhost.count(".") >= 1 and not dhost.endswith(LOCAL_DOMAIN) else ns
                idx = svc_index.get((dns, dhost.split(".")[0]))
                if not idx:
                    warn(f"VirtualService {d['metadata']['name']}: destination {dhost} not rendered")
                    continue
                backend, portmap = idx
                port = (dest.get("port") or {}).get("number") or next(iter(portmap), 80)
                target = portmap.get(port, port)
                matches = h.get("match") or [{}]
                for m in matches:
                    uri = m.get("uri") or {"prefix": "/"}
                    routes[host].append({"uri": uri, "rewrite": (h.get("rewrite") or {}).get("uri"), "backend": backend, "port": target})

    services[GATEWAY] = gateway_service(gateway_http, routes, store)
    client_secret_job(store, services)

    check_namespaces(services)
    report(services, profiles, skipped, store, routes)
    write_projects(services)
    store.save()


def check_namespaces(services: dict) -> None:
    for name, s in services.items():
        for dep in s.get("depends_on") or {}:
            if services[dep][NS] != s[NS]:
                warn(f"{name} depends on {dep} in another namespace; compose cannot express that")


def write_projects(services: dict) -> None:
    by_ns: dict[str, dict[str, dict]] = defaultdict(dict)
    for name, s in services.items():
        by_ns[s[NS]][name] = s
    for old in OUT.glob("*/compose.yaml"):
        old.unlink()
    (OUT / "compose.yaml").unlink(missing_ok=True)  # single-project layout before the split
    for ns, svcs in sorted(by_ns.items()):
        used: set[str] = set()
        for s in svcs.values():
            s.pop(NS)
            s.setdefault("labels", {})["openg2p.local/namespace"] = ns
            # bind mounts are relative to out/; this file sits one level down
            s["volumes"] = [f"../{v[2:]}" if v.startswith("./") else v for v in s.get("volumes") or []] or None
            if s["volumes"] is None:
                del s["volumes"]
            used |= {v.split(":")[0] for v in s.get("volumes") or [] if v.split(":")[0] in named}
        compose = {
            "name": ns,
            "services": dict(sorted(svcs.items())),
            "networks": {NETWORK: {"name": NETWORK, "external": True}},
            "volumes": {v: {"name": f"{VOLUME_PREFIX}{v}"} for v in sorted(used)},
        }
        path = OUT / ns / "compose.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "# Generated by gen.py from rendered OpenG2P RC charts. Do not edit; re-run ./render.sh.\n"
            + yaml.safe_dump(compose, sort_keys=False, width=200),
            encoding="utf-8",
        )


def gateway_service(http: dict[int, list], routes: dict[str, list[dict]], store: Store) -> dict:
    lines = [
        "resolver 127.0.0.11 valid=10s ipv6=off;",
        "map $http_upgrade $connection_upgrade { default upgrade; '' close; }",
        # The UIs send `upgrade-insecure-requests`; with only plain HTTP here the browser
        # would rewrite every request to https and fail. Drop just that directive.
        "map $upstream_http_content_security_policy $local_csp {",
        "  '~^(?<pre>.*?);?\\s*upgrade-insecure-requests\\s*;?(?<post>.*)$' '$pre;$post';",
        "  default $upstream_http_content_security_policy;",
        "}",
        "proxy_hide_header Content-Security-Policy;",
        "add_header Content-Security-Policy $local_csp always;",
        "server_names_hash_bucket_size 256;",
        "server_names_hash_max_size 8192;",
        "client_max_body_size 200m;",
        "proxy_read_timeout 300s;",
        "proxy_http_version 1.1;",
        "proxy_set_header Upgrade $http_upgrade;",
        "proxy_set_header Connection $connection_upgrade;",
        "proxy_set_header Host $host;",
        "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
        "proxy_set_header X-Forwarded-Proto $scheme;",
        "proxy_set_header X-Forwarded-Host $host;",
        "proxy_buffer_size 64k;",
        "proxy_buffers 8 64k;",
        "large_client_header_buffers 8 64k;",
        "",
    ]
    ports = sorted(set(http) | {80})
    for port in ports:
        lines.append(f"server {{ listen {port} default_server; return 502 'no route for $host:{port}\\n'; }}")
    aliases: list[str] = []
    for port, entries in sorted(http.items()):
        for names, backend, target in entries:
            aliases += names
            lines.append(
                f"server {{ listen {port}; server_name {' '.join(names)}; "
                f"location / {{ set $u http://{backend}:{target}; proxy_pass $u; }} }}"
            )
    for host, rs in sorted(routes.items()):
        aliases.append(host)
        body = []
        seen = set()
        for r in rs:
            uri = r["uri"]
            kind, path = next(iter(uri.items()))
            loc = {"prefix": f"location {path}", "exact": f"location = {path}", "regex": f"location ~ {path}"}.get(kind)
            if not loc or loc in seen:
                continue
            seen.add(loc)
            rw = ""
            if r["rewrite"] is not None and kind == "prefix":
                # after `set`: `break` ends the rewrite-module phase, `set` included
                rw = f"rewrite ^{re.escape(path)}(.*)$ {r['rewrite']}$1 break; "
            body.append(f"  {loc} {{ set $u http://{r['backend']}:{r['port']}; {rw}proxy_pass $u; }}")
        lines.append(f"server {{\n  listen 80; server_name {host};\n" + "\n".join(body) + "\n}")
    conf = FILES / GATEWAY / "default.conf"
    conf.parent.mkdir(parents=True, exist_ok=True)
    conf.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {
        "image": GATEWAY_IMAGE,
        "container_name": GATEWAY,
        "restart": "unless-stopped",
        "ports": ["80:80"],
        "volumes": [f"./{conf.relative_to(OUT).as_posix()}:/etc/nginx/conf.d/default.conf:ro"],
        "networks": {NETWORK: {"aliases": sorted(set(aliases))}},
        "labels": {"openg2p.local/kind": "gateway"},
        NS: EDGE_NS,
    }


def client_secret_job(store: Store, services: dict) -> None:
    """Kubernetes creates some client-secret Secrets at runtime (a job copies them
    out of Keycloak via the API server). Here the values are synthesized up front,
    so set them on the Keycloak clients instead."""
    clients = sorted({s.split(":")[0].split("/", 1)[1] for s in store.synthesized if s.endswith(":client_secret")})
    if not clients:
        return
    admin = store.secret("commons", "commons-keycloak", "admin-password", True) or "admin"
    pairs = " ".join(f"{c}={store.secret('commons', c, 'client_secret', False)}" for c in clients)
    script = r"""
apk add --no-cache curl jq >/dev/null
KC=http://commons-keycloak:80
for pair in $PAIRS; do
  cid=${pair%%=*}; val=${pair#*=}; done_=""
  for attempt in $(seq 1 60); do
    tok=$(curl -sf -d client_id=admin-cli -d username=admin -d "password=$ADMIN" -d grant_type=password $KC/realms/master/protocol/openid-connect/token | jq -r .access_token) || tok=""
    for realm in staff partner; do
      id=$(curl -sf -H "Authorization: Bearer $tok" "$KC/admin/realms/$realm/clients?clientId=$cid" | jq -r '.[0].id // empty') || id=""
      if [ -n "$id" ]; then
        curl -sf -X PUT -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "{\"secret\":\"$val\"}" "$KC/admin/realms/$realm/clients/$id" && echo "set $realm/$cid" && done_=1
        break
      fi
    done
    [ -n "$done_" ] && break
    echo "waiting for client $cid ($attempt/60)"; sleep 10
  done
  [ -n "$done_" ] || echo "WARN: client $cid never appeared"
done
"""
    services["local-client-secrets"] = {
        "image": CLIENT_SECRETS_IMAGE,
        "entrypoint": ["sh", "-c", esc(script)],
        "environment": {"PAIRS": esc(pairs), "ADMIN": esc(admin)},
        "restart": "on-failure:3",
        "profiles": ["keycloak-init"],
        "networks": [NETWORK],
        "labels": {"openg2p.local/kind": "job"},
        NS: EDGE_NS,
    }


def report(services: dict, profiles: dict, skipped: list[str], store: Store, routes: dict) -> None:
    by_profile: dict[str, list[str]] = defaultdict(list)
    for name, s in services.items():
        for p in s.get("profiles") or ["(always)"]:
            by_profile[p].append(name)
    lines = ["# Generated local stack", "", "## Profiles (project: profile)", ""]
    for p, names in sorted(by_profile.items(), key=lambda kv: (services[kv[1][0]][NS], kv[0])):
        for ns in sorted({services[n][NS] for n in names}):
            lines.append(f"- {ns}: **{p}**: {', '.join(sorted(n for n in names if services[n][NS] == ns))}")
    lines += ["", "## Browser hosts (gateway, port 80)", ""] + [f"- http://{h}" for h in sorted(routes)]
    lines += ["", "## Skipped objects", ""] + [f"- {s}" for s in sorted(set(skipped))]
    lines += ["", "## Synthesized secrets (created at runtime on Kubernetes)", ""] + [f"- {s}" for s in sorted(set(store.synthesized))]
    lines += ["", "## Remapped images (private registry -> local/GHCR)", ""] + [f"- `{a}` -> `{b}`" for a, b in sorted(remapped_images.items())]
    lines += ["", "## Warnings", ""] + [f"- {w}" for w in sorted(set(warnings))]
    (OUT / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    # namespace, profile, service, kind: stack.sh reads this to order releases and skip finished jobs.
    rows = sorted(
        (s[NS], p, name, (s.get("labels") or {}).get("openg2p.local/kind", ""))
        for name, s in services.items()
        for p in s.get("profiles") or ["-"]
    )
    (OUT / "services.tsv").write_text("".join(f"{ns}\t{p}\t{n}\t{k}\n" for ns, p, n, k in rows), encoding="utf-8", newline="\n")
    print(f"{len(services)} services, {len(by_profile)} profiles, {len(set(warnings))} warnings -> out/<namespace>/compose.yaml, out/REPORT.md")


if __name__ == "__main__":
    main(sys.argv[1:])
