#!/usr/bin/env bash
# =============================================================================
#  pro-config for Rebecca  —  https://github.com/pdnczone/pro-config
#
#  Adds a professional, censorship-resistant set of configs to an EXISTING
#  Rebecca panel (https://github.com/rebeccapanel/Rebecca): REALITY (Vision /
#  XHTTP / gRPC), TLS (Vision / XHTTP), Cloudflare CDN (WS / HTTPUpgrade /
#  XHTTP + clean IPs), Hysteria2 with Salamander, post-quantum VLESS with
#  Sudoku, OpenVPN (UDP / TCP, tls-crypt, AES-256-GCM, EC P-384 certificates).
#  Fragment (FinalMask) where it helps.
#  Hardening: TLS 1.3 only on direct TLS, post-quantum ML-DSA-65 on REALITY,
#  ML-KEM-768 for the PQ config, per-config random paths / short IDs / keys.
#
#  ADD-ONLY: it never deletes or edits your existing inbounds, hosts, services
#  or users. Everything it creates is new: its own inbounds (tag pro-*), its own
#  hosts, ONE new service that holds only those hosts, and ONE new user in
#  that service. Your existing users do not get any new links.
#
#  Install (run on the Rebecca panel server, as root):
#    bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/install.sh)   # detects the panel; or install-rebecca.sh directly
#
#  Non-interactive:
#    bash install-rebecca.sh --yes --token <ADMIN_TOKEN> --domain my.example.com \
#                            --cdn cdn.example.com --configs all --clean 20
#  Options:
#    --token T       admin API token / JWT (otherwise it asks for username + password)
#    --panel URL     panel address if it cannot be found automatically
#    --domain D      domain pointing straight to this server (Cloudflare: DNS only / grey)
#    --cdn C         domain proxied by Cloudflare (orange) to this server
#    --configs L     comma list or "all":  rv,rx,rg,tv,tx,ws,hu,hy,pq,ov,ot
#    --clean N       how many Cloudflare clean-IP hosts to add (0-30, default 20)
#    --email E       username of the new user (default pro-xxxx)
#    --ports auto|ask   what to do when a port is busy (default: ask, or auto with --yes)
#    --no-mldsa      do not add the post-quantum ML-DSA-65 signature to REALITY (for old clients)
#    --no-bbr --no-test --yes --dry-run
#
#  Needs a full-access (or sudo) admin. Configs are created on the "master"
#  Xray, which must run on THIS server.
# =============================================================================
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "Please run as root (sudo -i)."; exit 1; }
for b in python3 curl openssl ss; do command -v "$b" >/dev/null || { echo "Missing: $b  (apt install -y $b)"; exit 1; }; done
REPO_RAW="https://raw.githubusercontent.com/pdnczone/pro-config/main"
TMPPY=$(mktemp /tmp/rb-pro.XXXXXX.py)
trap 'rm -f "$TMPPY"' EXIT
cat > "$TMPPY" <<'PYEOF'
import argparse, base64, glob, ipaddress, json, os, re, secrets, shutil, socket, string, subprocess, sys, time
import getpass
from urllib.parse import urlparse
import concurrent.futures as cfut

REPO_RAW = os.environ.get("REPO_RAW", "")
p = argparse.ArgumentParser()
for a in ("--domain", "--cdn", "--configs", "--email", "--token", "--clean", "--ports", "--panel"):
    p.add_argument(a)
for a in ("--no-bbr", "--no-test", "--yes", "--dry-run", "--no-mldsa"):
    p.add_argument(a, action="store_true")
A = p.parse_args()

G, Y, R, C, B, D, N = "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[1m", "\033[2m", "\033[0m"
def info(*a): print(G + "[+]" + N, *a, flush=True)
def warn(*a): print(Y + "[!]" + N, *a, flush=True)
def die(*a): print(R + "[x]" + N, *a, flush=True); sys.exit(1)
def head(t): print(f"\n{B}{C}── {t} {'─' * max(2, 60 - len(t))}{N}")
def sh(cmd, t=60):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout.strip()
    except Exception:
        return ""
try:
    TTY = open("/dev/tty")
except Exception:
    TTY = None
# answers are read from /dev/tty only; child commands must never eat the user's typed input
_null = os.open(os.devnull, os.O_RDONLY)
os.dup2(_null, 0)
INTERACTIVE = not A.yes and TTY is not None
def ask(q, default=""):
    if not INTERACTIVE:
        return default
    print(f"{B}?{N} {q}" + (f" {D}[{default}]{N}" if default != "" else "") + ": ", end="", flush=True)
    return TTY.readline().strip() or default
def yes(q, default=True):
    return ask(q + (" (Y/n)" if default else " (y/N)"), "y" if default else "n").lower().startswith("y")

# =========================================================================== panel
head("Panel")
ENV = {}
ENV_FILE = next((f for f in ("/opt/rebecca/.env", "/etc/opt/rebecca/.env") if os.path.exists(f)), "")
if ENV_FILE:
    for l in open(ENV_FILE):
        l = l.strip()
        if l and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1); ENV[k.strip()] = v.strip().strip("\"'")
if not ENV_FILE and not A.panel:
    die("Rebecca was not found on this server (no /opt/rebecca/.env). Run this on the panel server, or pass --panel URL.")
pport = int(ENV.get("UVICORN_PORT", "8000") or 8000)
CERTF, KEYF = ENV.get("UVICORN_SSL_CERTFILE", ""), ENV.get("UVICORN_SSL_KEYFILE", "")
phost = "127.0.0.1"
if CERTF and os.path.exists(CERTF):
    m = re.search(r"DNS:([A-Za-z0-9.-]+)", sh(f"openssl x509 -in '{CERTF}' -noout -ext subjectAltName 2>/dev/null"))
    phost = m.group(1) if m and not m.group(1).startswith("*") else "127.0.0.1"
if A.panel:
    PANEL = A.panel.rstrip("/")
    u = urlparse(PANEL); phost = u.hostname or phost; pport = u.port or (443 if u.scheme == "https" else 80)
else:
    PANEL = f"https://{phost}:{pport}" if CERTF else f"http://127.0.0.1:{pport}"
# the dashboard refuses bare IPs, so reach the panel by its domain but through this machine
RESOLVE = ["--resolve", f"{phost}:{pport}:127.0.0.1"] if re.search(r"[a-zA-Z]", phost) else []
TOKEN = A.token or ""

def call(method, path, body=None, timeout=60, token=True):
    c = ["curl", "-sk", "-m", str(timeout), "-w", "\n%{http_code}", "-X", method] + RESOLVE
    if token:
        c += ["-H", f"Authorization: Bearer {TOKEN}"]
    if body is not None:
        c += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    out = subprocess.run(c + [PANEL + path], capture_output=True, text=True).stdout
    raw, _, code = out.rpartition("\n")
    try:
        data = json.loads(raw)
    except Exception:
        data = {"detail": raw[:200]}
    return int(code) if code.isdigit() else 0, data
def ok(code): return 200 <= code < 300
def err(data):
    d = data.get("detail") if isinstance(data, dict) else data
    return d if isinstance(d, str) else json.dumps(d)[:200]

def login(u, pw):
    global TOKEN
    code, d = call("POST", "/api/admin/token", {"username": u, "password": pw}, token=False)
    if not ok(code) or "access_token" not in d:
        die("Panel login failed:", err(d))
    TOKEN = d["access_token"]

code, _ = call("GET", "/api/admin") if TOKEN else (0, {})
if not ok(code):
    if code == 0 and not TOKEN:
        pass
    if not INTERACTIVE and not TOKEN:
        die("No admin token. Pass --token (or run without --yes to log in with username/password).")
    if TOKEN:
        die("The token was refused by", PANEL)
    print(f"  {D}Panel found at {PANEL}{N}")
    u = ask("Panel admin username (a full-access or sudo admin)")
    pw = getpass.getpass("? Panel admin password: ")
    login(u, pw)
code, me = call("GET", "/api/admin")
if not ok(code):
    die("Cannot talk to the Rebecca API at", PANEL, "-", err(me))
if me.get("role") not in ("sudo", "full_access"):
    die(f"Admin '{me.get('username')}' has role '{me.get('role')}'. A full-access or sudo admin is needed.")
code, runtime = call("GET", "/api/core")
XVER = (runtime or {}).get("version") or "?"
info(f"admin {me.get('username')} · xray {XVER} · {PANEL}")
if not str(XVER).startswith("26"):
    warn("Xray-core is not 26.x — FinalMask, Hysteria2 and Sudoku need it (Rebecca > Xray settings > update core).")
XRAY = ENV.get("XRAY_EXECUTABLE_PATH", "")
if not XRAY or not os.path.exists(XRAY):
    XRAY = next(iter(glob.glob("/var/lib/rebecca/xray-core/xray") + glob.glob("/var/lib/rebecca-node/xray-core/xray") + glob.glob("/usr/local/bin/xray") + glob.glob("/usr/bin/xray")), "")
if not XRAY:
    die("Could not find the Xray binary on this server. Rebecca's master Xray must run here.")
DBURL = ENV.get("SQLALCHEMY_DATABASE_URL", "")
DB = re.sub(r"^sqlite[^:]*:/+", "/", DBURL) if DBURL.startswith("sqlite") else ""
if not DB or not os.path.exists(DB):
    DB = next(iter(glob.glob("/var/lib/rebecca/db.sqlite3")), "") if DBURL.startswith("sqlite") or not DBURL else ""
code, inbs = call("GET", "/api/inbounds/full")
inbs = inbs if ok(code) and isinstance(inbs, list) else []
code, hosts_now = call("GET", "/api/hosts")
n_hosts_before = sum(len(v) for v in hosts_now.values()) if ok(code) and isinstance(hosts_now, dict) else 0
TARGET = "master"   # the panel's shared Xray config; nodes on "default" config inherit it
code, nodes = call("GET", "/api/nodes")
nodes = nodes if ok(code) and isinstance(nodes, list) else []
# reused below as "settings": only the panel's own certificate is known
settings = {"webCertFile": CERTF, "webKeyFile": KEYF}
status = {}

# =========================================================================== server facts
pub = status.get("publicIP") if isinstance(status.get("publicIP"), dict) else {}
PUB4 = (pub or {}).get("ipv4") or sh("curl -4 -s -m6 https://api.ipify.org")
PUB6 = ""
for l in sh("ip -6 addr show scope global").splitlines():
    m = re.search(r"inet6 ([0-9a-f:]+)/\d+ .*scope global", l)
    if m and "temporary" not in l and "deprecated" not in l and not m.group(1).startswith(("fd", "fc")):
        PUB6 = m.group(1); break
if PUB6 and not sh("curl -6 -s -m6 https://api64.ipify.org"):
    PUB6 = ""
CF_NETS = [ipaddress.ip_network(n) for n in (
    "173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 "
    "188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 "
    "131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 "
    "2c0f:f248::/32").split()]
def ips_of(d):
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(d, None)})
    except Exception:
        return []
is_cf = lambda ip: any(ipaddress.ip_address(ip) in n for n in CF_NETS if ipaddress.ip_address(ip).version == n.version)

def find_cert(d):
    cands = [(settings.get("webCertFile"), settings.get("webKeyFile")), (settings.get("subCertFile"), settings.get("subKeyFile")),
             (f"/root/cert/{d}/fullchain.pem", f"/root/cert/{d}/privkey.pem"),
             (f"/root/.acme.sh/{d}_ecc/fullchain.cer", f"/root/.acme.sh/{d}_ecc/{d}.key"),
             (f"/root/.acme.sh/{d}/fullchain.cer", f"/root/.acme.sh/{d}/{d}.key"),
             (f"/etc/letsencrypt/live/{d}/fullchain.pem", f"/etc/letsencrypt/live/{d}/privkey.pem")]
    for c, k in cands:
        if c and k and os.path.exists(c) and os.path.exists(k):
            names = sh(f"openssl x509 -in '{c}' -noout -ext subjectAltName 2>/dev/null")
            if f"DNS:{d}" in names or f"DNS:*.{d.split('.', 1)[-1]}" in names:
                if sh(f"openssl x509 -in '{c}' -noout -checkend 86400 >/dev/null && echo ok") == "ok":
                    return c, k
    return None, None

def issue_cert(d):
    """Let's Encrypt via acme.sh standalone (needs TCP 80 free and the domain pointing here)."""
    if sh("ss -H -tln 'sport = :80'"):
        warn("Port 80 is busy — cannot issue a certificate automatically."); return None, None
    acme = os.path.expanduser("~/.acme.sh/acme.sh")
    if not os.path.exists(acme):
        sh("curl -s https://get.acme.sh | sh -s email=admin@" + d, 180)
    if not os.path.exists(acme):
        warn("acme.sh could not be installed."); return None, None
    sh(f"{acme} --set-default-ca --server letsencrypt", 60)
    out = sh(f"{acme} --issue -d {d} --standalone --httpport 80 --keylength ec-256 --force", 240)
    os.makedirs(f"/root/cert/{d}", exist_ok=True)
    sh(f"{acme} --install-cert -d {d} --ecc --fullchain-file /root/cert/{d}/fullchain.pem "
       f"--key-file /root/cert/{d}/privkey.pem --reloadcmd 'x-ui restart'", 60)
    if os.path.exists(f"/root/cert/{d}/fullchain.pem"):
        info(f"certificate issued for {d}"); return f"/root/cert/{d}/fullchain.pem", f"/root/cert/{d}/privkey.pem"
    warn("certificate issue failed:", out[-200:]); return None, None

if len(nodes) > 1:
    warn(f"This panel has {len(nodes)} nodes. The new inbounds go into the shared 'master' Xray config, so every node")
    warn("that follows the master config will get them (the hosts still point to THIS server).")
    if not yes("Continue?", False):
        sys.exit(0)
# =========================================================================== 1. domain
head("1/4  Your domain (direct, Cloudflare grey cloud)")
print(f"  {D}Used for TLS configs and Hysteria2. Must point straight to this server ({PUB4}).{N}")
guess = A.domain or settings.get("webDomain") or settings.get("subDomain") or (phost if re.search(r"[a-z]", phost) else "")
if not guess:
    for d in glob.glob("/root/cert/*/fullchain.pem"):
        guess = d.split("/")[3]; break
DOMAIN = (A.domain if A.domain is not None else ask("Domain (Enter = none, only REALITY configs)", guess)).strip().lower()
CERT = KEY = None
if DOMAIN:
    ips = ips_of(DOMAIN)
    if not ips:
        warn(f"{DOMAIN} does not resolve. Fix DNS, then run again."); DOMAIN = ""
    elif any(is_cf(i) for i in ips):
        warn(f"{DOMAIN} is behind Cloudflare (orange). It must be DNS-only (grey) for direct configs.")
        warn("Turn the proxy off for it in Cloudflare, or use it as your CDN domain instead.")
        DOMAIN = ""
    else:
        if PUB4 not in ips and (not PUB6 or PUB6 not in ips):
            warn(f"{DOMAIN} points to {', '.join(ips)}, not to this server ({PUB4}).")
        CERT, KEY = find_cert(DOMAIN)
        if CERT:
            info(f"certificate found: {CERT}")
        elif yes(f"No valid certificate for {DOMAIN}. Issue one now with Let's Encrypt?", True):
            CERT, KEY = issue_cert(DOMAIN)
        if not CERT:
            warn("No certificate — TLS, CDN and Hysteria2 configs will be skipped.")
ADDR = DOMAIN or PUB4

# =========================================================================== 2. CDN domain
CDN = ""
if CERT:
    head("2/4  CDN domain (Cloudflare orange cloud)")
    print(f"  {D}A subdomain proxied by Cloudflare to this server, SSL/TLS mode = Full. Enter = skip CDN.{N}")
    CDN = (A.cdn if A.cdn is not None else ask("CDN domain", "")).strip().lower()
    if CDN:
        ips = ips_of(CDN)
        if not ips:
            warn(f"{CDN} does not resolve — CDN skipped."); CDN = ""
        elif not any(is_cf(i) for i in ips):
            warn(f"{CDN} is not proxied by Cloudflare (orange cloud is off) — CDN skipped."); CDN = ""
        else:
            info(f"{CDN} is behind Cloudflare")

# =========================================================================== 3. configs
CATALOG = [
    # key, name, needs, description
    ("rv", "⚡ Reality Vision", None, "fastest + stealthiest, main config"),
    ("rx", "🌀 Reality XHTTP", None, "REALITY over XHTTP, padding"),
    ("rg", "🔷 Reality gRPC", None, "REALITY over gRPC"),
    ("tv", "🔐 TLS Vision", "tls", "real certificate, + Fragment and IPv6 variants"),
    ("tx", "🛰 TLS XHTTP", "tls", "direct + CDN capable"),
    ("ws", "🌐 CDN WS", "cdn", "Cloudflare WebSocket + clean IPs"),
    ("hu", "🔗 CDN HTTPUpgrade", "cdn", "Cloudflare HTTPUpgrade"),
    ("hy", "🚄 Hysteria2", "tls", "UDP/QUIC, Salamander FinalMask (needs UDP open)"),
    ("pq", "🧬 PQ Sudoku", None, "post-quantum VLESS + Sudoku FinalMask (beta, Xray 26 clients)"),
    ("ov", "🛡 OpenVPN UDP", None, "classic OpenVPN: tls-crypt, AES-256-GCM, EC P-384 (easy to detect by DPI)"),
    ("ot", "🛡 OpenVPN TCP", None, "OpenVPN over TCP, for networks that block UDP"),
    # ("ss", ...) Shadowsocks-2022 is left out: Rebecca cannot add users to it at runtime (Xray needs clients at start-up)
]
avail = [c for c in CATALOG if c[2] is None or (c[2] == "tls" and CERT) or (c[2] == "cdn" and CDN)]
head("3/4  Which configs to add")
for n, (k, name, _, desc) in enumerate(avail, 1):
    print(f"  {B}{n:2d}{N}) {name:22s} {D}{desc}{N}")
skipped = [c[1] for c in CATALOG if c not in avail]
if skipped:
    print(f"  {D}not available (no domain/cert/CDN): {', '.join(skipped)}{N}")
if A.configs:
    sel_keys = [c[0] for c in avail] if A.configs.strip() == "all" else [x.strip() for x in A.configs.split(",")]
else:
    ans = ask("Numbers separated by comma, or 'all'", "all")
    if ans.strip().lower() == "all":
        sel_keys = [c[0] for c in avail]
    else:
        idx = {int(x) for x in re.findall(r"\d+", ans)}
        sel_keys = [avail[i - 1][0] for i in sorted(idx) if 1 <= i <= len(avail)]
SEL = [c for c in avail if c[0] in sel_keys]
if not SEL:
    die("Nothing selected.")
MLDSA = False
if any(k in sel_keys for k in ("rv", "rx", "rg")) and not A.no_mldsa:
    print(f"  {D}REALITY can add a post-quantum signature (ML-DSA-65). It needs Xray 26 clients (v2rayNG / v2rayN recent).{N}")
    MLDSA = yes("Add the post-quantum ML-DSA-65 signature to REALITY?", True)
CLEAN_N = 0
if "ws" in sel_keys or "hu" in sel_keys or ("tx" in sel_keys and CDN):
    CLEAN_N = int(A.clean) if A.clean is not None else int(re.sub(r"\D", "", ask(
        "How many Cloudflare clean-IP configs to add (0-30)", "20")) or 0)
    CLEAN_N = max(0, min(30, CLEAN_N))

# =========================================================================== ports
owner_tcp, owner_udp = {}, {}
inbs = [i for i in inbs if isinstance(i, dict) and isinstance(i.get("port"), int) and i.get("protocol")]
for ib in inbs:
    st = ib.get("streamSettings")
    st = json.loads(st) if isinstance(st, str) and st else (st or {})
    label = f"inbound '{ib.get('tag')}'"
    if ib["protocol"] in ("hysteria", "wireguard", "amneziawg") or st.get("network") in ("kcp", "hysteria"):
        owner_udp[ib["port"]] = label
    else:
        owner_tcp[ib["port"]] = label
        if ib["protocol"] in ("shadowsocks", "mixed", "socks", "dokodemo-door", "tunnel"):
            owner_udp[ib["port"]] = label
for flag, dct in (("t", owner_tcp), ("u", owner_udp)):
    for l in sh(f"ss -H -{flag}lnp").splitlines():
        f = l.split()
        if len(f) < 5:
            continue
        m = re.search(r":(\d+)$", f[3])
        if m and int(m.group(1)) not in dct:
            pm = re.search(r'\(\("([^"]+)"', l)
            dct[int(m.group(1))] = f"process '{pm.group(1) if pm else '?'}'"
for k in ("subPort", "webPort"):
    if settings.get(k):
        owner_tcp.setdefault(int(settings[k]), "Rebecca panel")
owner_tcp.setdefault(int(pport), "Rebecca panel")

CF_HTTPS = [443, 2053, 2083, 2087, 2096, 8443]
PREF = {"rv": [443, 2443, 3443, 6443, 7443], "rx": [8443, 2443, 3443, 5443, 6443], "rg": [4443, 5443, 7443, 9444],
        "tv": [9443, 9444, 10444, 11444], "tx": [2087, 2053, 2083, 2096, 8443], "ws": [2053, 2083, 2087, 2096, 8443],
        "hu": [2083, 2053, 2087, 2096, 8443], "hy": [443, 8443, 4443, 2053, 10443], "pq": [10443, 11443, 12443, 13443],
        "ss": [8080, 8388, 18080, 28080], "ov": [1194, 1195, 2194, 4194], "ot": [1194, 993, 2195, 5195]}
UDP_ONLY = {"hy", "ov"}
BOTH = {"ss"}
CDN_KEYS = {"tx", "ws", "hu"}
MODE = A.ports or ("auto" if not INTERACTIVE else "ask")

PORT_BOTH = {"ov", "ot"}      # Rebecca refuses the same port number twice, even as TCP and UDP
def busy(pt, key):
    if key in PORT_BOTH:
        return owner_tcp.get(pt) or owner_udp.get(pt)
    t = pt in owner_tcp if key not in UDP_ONLY else False
    u = pt in owner_udp if (key in UDP_ONLY or key in BOTH) else False
    return (owner_tcp.get(pt) if t else None) or (owner_udp.get(pt) if u else None)
def claim(pt, key):
    if key in PORT_BOTH:
        owner_tcp[pt] = owner_udp[pt] = "new config"; return
    if key not in UDP_ONLY: owner_tcp[pt] = "new config"
    if key in UDP_ONLY or key in BOTH: owner_udp[pt] = "new config"
def free_from(lst, key):
    for pt in lst:
        if not busy(pt, key):
            return pt
    for pt in range(20000, 60000, 7):
        if not busy(pt, key) and not (key in CDN_KEYS):
            return pt
    return None

head("4/4  Ports")
PLAN = {}
ORIGIN_RULES = []
for key, name, _, _ in SEL:
    want = PREF[key][0]
    who = busy(want, key)
    if not who:
        PLAN[key] = {"port": want, "client_port": 0}; claim(want, key)
        print(f"  {name:22s} port {want}{'/udp' if key in UDP_ONLY else ''}")
        continue
    alt = free_from(PREF[key], key)
    cdn_note = key in CDN_KEYS and (alt is None or alt not in CF_HTTPS)
    print(f"  {Y}{name:22s} port {want} is used by {who}{N}")
    if key in CDN_KEYS and alt in CF_HTTPS:
        hint = f"Enter = use {alt} (a Cloudflare port)"
    elif key in CDN_KEYS:
        hint = "all Cloudflare ports (443 2053 2083 2087 2096 8443) are busy: o = Origin-Rule mode, s = skip"
    else:
        hint = f"Enter = use {alt}"
    if MODE == "auto":
        choice = "" if alt and not cdn_note else "s"
    else:
        print(f"    {D}Two inbounds can never share one port. Options:{N}")
        print(f"    {D}  Enter  use the next free port{'' if not cdn_note else ' (not possible here)'}{N}")
        print(f"    {D}  <num>  type your own port{N}")
        if key in CDN_KEYS:
            print(f"    {D}  o      Origin-Rule mode: clients use Cloudflare port 443, Cloudflare forwards to any free port{N}")
        print(f"    {D}  s      skip this config (your existing inbound stays as it is){N}")
        choice = ask(f"    {hint}", "")
    choice = choice.strip().lower()
    if choice == "s" or (choice == "" and (alt is None or cdn_note)):
        print(f"    → skipped"); continue
    if choice == "o" and key in CDN_KEYS:
        pt = free_from(range(30000, 60000, 11), "x")
        PLAN[key] = {"port": pt, "client_port": 443, "origin_rule": True}; claim(pt, key)
        print(f"    → Origin-Rule mode: server port {pt}, clients use 443"); continue
    if choice.isdigit():
        pt = int(choice)
        if busy(pt, key):
            warn(f"    port {pt} is also busy ({busy(pt, key)}) — skipped"); continue
        if key in CDN_KEYS and pt not in CF_HTTPS:
            warn("    Cloudflare only proxies 443 2053 2083 2087 2096 8443 — using Origin-Rule mode for this port")
            PLAN[key] = {"port": pt, "client_port": 443, "origin_rule": True}
        else:
            PLAN[key] = {"port": pt, "client_port": 0}
        claim(pt, key); print(f"    → port {pt}"); continue
    PLAN[key] = {"port": alt, "client_port": 0}; claim(alt, key)
    print(f"    → port {alt}")
if not PLAN:
    die("Nothing left to add.")

# =========================================================================== REALITY targets + clean IPs
def tls13_h2(sni):
    out = sh(f"echo | timeout 6 openssl s_client -connect {sni}:443 -servername {sni} -alpn h2 -tls1_3 2>/dev/null", 10)
    return "TLSv1.3" in out and "ALPN protocol: h2" in out
SNI_POOL = ["dl.google.com", "addons.mozilla.org", "www.samsung.com", "www.nvidia.com", "www.speedtest.net",
            "www.amd.com", "www.asus.com", "www.lovelive-anime.jp"]
if any(k in PLAN for k in ("rv", "rx", "rg")):
    with cfut.ThreadPoolExecutor(8) as ex:
        okmap = dict(zip(SNI_POOL, ex.map(tls13_h2, SNI_POOL)))
    GOOD_SNI = [s for s in SNI_POOL if okmap[s]] or SNI_POOL
else:
    GOOD_SNI = SNI_POOL
sni = lambda i: GOOD_SNI[i % len(GOOD_SNI)]

CLEAN = []
if CLEAN_N and CDN:
    lst = sh(f"curl -fsSL -m10 {REPO_RAW}/clean-ips.txt") if REPO_RAW else ""
    cand = [l.split("#")[0].strip() for l in lst.splitlines() if l.split("#")[0].strip()]
    if not cand:
        cand = __FALLBACK_CLEAN__
    cdn_port = next((PLAN[k]["port"] for k in ("ws", "hu", "tx") if k in PLAN and not PLAN[k].get("origin_rule")), None)
    if not cdn_port and any(PLAN.get(k, {}).get("origin_rule") for k in ("ws", "hu", "tx")):
        cdn_port = 443          # Origin-Rule mode: clients reach Cloudflare on 443
    if cdn_port:
        def via_cf(a):
            ip = a if re.match(r"^[\d.]+$", a) else (next((x for x in ips_of(a) if ":" not in x), "") or "")
            if not ip or not is_cf(ip):
                return None
            r = sh(f"curl -s -o /dev/null -m6 -w '%{{http_code}} %{{time_connect}}' --resolve {CDN}:{cdn_port}:{ip} "
                   f"https://{CDN}:{cdn_port}/", 10)
            code, _, t = r.partition(" ")
            return (a, float(t or 9)) if code and code != "000" else None
        info(f"checking {len(cand)} Cloudflare clean IPs / domains against {CDN} ...")
        with cfut.ThreadPoolExecutor(16) as ex:
            res = [r for r in ex.map(via_cf, cand) if r]
        CLEAN = [a for a, _ in res][:CLEAN_N]
        info(f"{len(CLEAN)} clean addresses ready")

# =========================================================================== summary + confirm
head("Plan")
print(f"  address {ADDR}" + (f" · IPv6 {PUB6}" if PUB6 else "") + (f" · CDN {CDN}" if CDN else ""))
for key, name, _, _ in SEL:
    if key in PLAN:
        pl = PLAN[key]
        print(f"  {G}+{N} {name:22s} port {pl['port']}{'/udp' if key in UDP_ONLY else ''}"
              + (f"  (Origin Rule → clients use 443)" if pl.get("origin_rule") else ""))
if CLEAN:
    print(f"  {G}+{N} {len(CLEAN)} clean-IP CDN configs")
print(f"  {D}existing inbounds kept untouched: {len(inbs)}{N}")
if A.dry_run:
    info("Dry run — nothing changed."); sys.exit(0)
if not yes("Start?", True):
    sys.exit(0)

# =========================================================================== builders
hx = secrets.token_hex
def x25519():
    d = {}
    for l in sh(f"{XRAY} x25519").splitlines():
        k, _, v = l.partition(":"); d[k.strip()] = v.strip()
    return d.get("PrivateKey") or d.get("Private key"), \
        d.get("Password (PublicKey)") or d.get("Password") or d.get("PublicKey") or d.get("Public key")
def vlessenc():
    out = sh(f"{XRAY} vlessenc").splitlines()
    for needle in ("ML-KEM-768", "X25519"):          # post-quantum authentication first
        for n, l in enumerate(out):
            if needle in l and n + 2 < len(out) and '"' in out[n + 1]:
                return out[n + 1].split('"')[3], out[n + 2].split('"')[3]
    raise RuntimeError("this Xray has no 'vlessenc' (update Xray-core)")
# Rebecca stores plain Xray inbounds: no 3x-ui extras (externalProxy, client-side blocks) and no clients here;
# users get their credentials from the service.
def reality(network, target, extra):
    priv, _ = x25519()
    rs = {"show": False, "xver": 0, "target": f"{target}:443", "serverNames": [target],
          "privateKey": priv, "shortIds": [hx(4), hx(6), hx(8)], "maxTimeDiff": 60000}
    if MLDSA:
        d = {}
        for l in sh(f"{XRAY} mldsa65").splitlines():
            k, _, v = l.partition(":"); d[k.strip().lower()] = v.strip()
        if d.get("seed") and d.get("verify"):
            rs["mldsa65Seed"], rs["mldsa65Verify"] = d["seed"], d["verify"]
        else:
            warn("this Xray has no 'mldsa65' — REALITY without the post-quantum signature")
    s = {"network": network, "security": "reality", "realitySettings": rs}
    s.update(extra); return s
def tls(alpn, strict=False):
    # strict = direct (not behind Cloudflare): TLS 1.3 only and no answer to unknown server names
    t = {"serverName": DOMAIN, "minVersion": "1.3" if strict else "1.2", "maxVersion": "1.3", "alpn": alpn,
         "certificates": [{"certificateFile": CERT, "keyFile": KEY}]}
    if strict:
        t["rejectUnknownSni"] = True
    return t
def tls_stream(network, extra, alpn, strict=False):
    s = {"network": network, "security": "tls", "tlsSettings": tls(alpn, strict)}; s.update(extra); return s
TCP = {"tcpSettings": {"header": {"type": "none"}}}
XH = lambda: {"path": "/" + hx(5), "host": "", "mode": "auto", "xPaddingBytes": "100-1000"}
VL = lambda flow=False: {"clients": [], "decryption": "none", **({"flow": "xtls-rprx-vision"} if flow else {})}
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"], "metadataOnly": False, "routeOnly": True}
PATHS = {}
def ws_stream():
    PATHS["ws"] = "/" + hx(5)
    return tls_stream("ws", {"wsSettings": {"path": PATHS["ws"], "host": "", "headers": {}, "heartbeatPeriod": 30}}, ["http/1.1"])
def hu_stream():
    PATHS["hu"] = "/" + hx(5)
    return tls_stream("httpupgrade", {"httpupgradeSettings": {"path": PATHS["hu"], "host": "", "headers": {}}}, ["http/1.1"])
def tx_stream():
    x = XH(); PATHS["tx"] = x["path"]
    return tls_stream("xhttp", {"xhttpSettings": x}, ["h2", "http/1.1"])
def pq():
    dec, enc = vlessenc()
    return ({"clients": [], "decryption": dec, "encryption": enc},
            {"network": "tcp", "security": "none", **TCP,
             "finalmask": {"tcp": [{"type": "sudoku", "settings": {"password": hx(16), "ascii": "prefer_entropy",
                                                                    "paddingMin": 2, "paddingMax": 7}}]}})
def ov_pki():
    """A private CA + server certificate (EC P-384). The CA key is thrown away: the panel only needs the server side."""
    import tempfile
    d = tempfile.mkdtemp(prefix="rb-ov-")
    try:
        san = f"IP:{PUB4}" + (f",DNS:{DOMAIN}" if DOMAIN else "")
        with open(f"{d}/ext", "w") as f:
            f.write(f"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName={san}\n")
        cmds = [
            f"openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -sha384 -days 3650 -keyout {d}/ca.key -out {d}/ca.crt "
            f"-subj '/CN=pro-config CA {hx(3)}' -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign",
            f"openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -keyout {d}/srv.key -out {d}/srv.csr -subj '/CN=pro-config-{hx(3)}'",
            f"openssl x509 -req -in {d}/srv.csr -CA {d}/ca.crt -CAkey {d}/ca.key -CAcreateserial -out {d}/srv.crt -days 3650 -sha384 -extfile {d}/ext",
        ]
        for c in cmds:
            r = subprocess.run(c, shell=True, capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError("openssl failed: " + r.stderr[-120:])
        rd = lambda n: open(f"{d}/{n}").read().strip() + "\n"
        return rd("ca.crt"), rd("srv.crt"), rd("srv.key")
    finally:
        shutil.rmtree(d, ignore_errors=True)
def free_local_port():
    for pt in range(41940, 42800):
        if pt not in owner_tcp and pt not in owner_udp:
            owner_tcp[pt] = owner_udp[pt] = "OpenVPN tunnel"; return pt
    raise RuntimeError("no free local port for the OpenVPN tunnel")
USED_POOLS = {str((i.get("settings") or {}).get("ipv4_pool_cidr", "")) for i in inbs if isinstance(i.get("settings"), dict)}
def ov(transport):
    pool = next(f"10.{n}.0.0/16" for n in range(66, 120) if f"10.{n}.0.0/16" not in USED_POOLS)
    USED_POOLS.add(pool)
    ca, crt, key = ov_pki()
    tc = "-----BEGIN OpenVPN Static key V1-----\n" + "\n".join(hx(16) for _ in range(16)) + "\n-----END OpenVPN Static key V1-----\n"
    return ({"transport": transport, "device": "tun", "ipv4_pool_cidr": pool, "dns_servers": ["1.1.1.1", "9.9.9.9"],
             "ca": ca, "server_certificate": crt, "server_key": key, "tls_crypt": tc, "cipher": "AES-256-GCM",
             "redirect_gateway": True, "tunnel_port": free_local_port(), "extra_client_config": "tls-version-min 1.3"}, None)
BUILD = {
    "rv": ("vless", lambda: (VL(True), reality("tcp", sni(0), TCP))),
    "rx": ("vless", lambda: (VL(), reality("xhttp", sni(1), {"xhttpSettings": XH()}))),
    "rg": ("vless", lambda: (VL(), reality("grpc", sni(2), {"grpcSettings": {"serviceName": hx(4), "multiMode": True}}))),
    "tv": ("vless", lambda: (VL(True), tls_stream("tcp", TCP, ["h2", "http/1.1"], True))),
    "tx": ("vless", lambda: (VL(), tx_stream())),
    "ws": ("vless", lambda: (VL(), ws_stream())),
    "hu": ("vless", lambda: (VL(), hu_stream())),
    "hy": ("hysteria", lambda: ({"version": 2, "clients": []},
                                {"network": "hysteria", "security": "tls", "tlsSettings": tls(["h3"], True),
                                 "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60,
                                                      "masquerade": {"type": "proxy", "url": "https://www.bing.com",
                                                                     "rewriteHost": True}},
                                 "finalmask": {"udp": [{"type": "salamander", "settings": {"password": hx(16)}}],
                                               "quicParams": {"congestion": "bbr"}}})),
    "pq": ("vless", pq),
    "ov": ("openvpn", lambda: ov("udp")),
    "ot": ("openvpn", lambda: ov("tcp")),
    "ss": ("shadowsocks", lambda: ({"method": "2022-blake3-aes-256-gcm", "password": base64.b64encode(secrets.token_bytes(32)).decode(),
                                    "network": "tcp,udp", "clients": []},
                                   {"network": "tcp", "security": "none", **TCP})),
}
# FRAG goes through Rebecca's own validated host field (length,interval,packets)
FRAG = "10-30,5-15,tlshello"
def host(remark, addr, port=None, sni_=None, hhdr=None, frag=False, tls_=False, fp="chrome"):
    return {"remark": remark, "address": addr, "port": port, "sni": sni_, "host": hhdr, "path": None,
            "security": "tls" if tls_ else "inbound_default", "alpn": "none", "fingerprint": fp,
            "is_disabled": False, "mux_enable": False, "fragment_setting": FRAG if frag else None}
def cdn_host(name, addr, key):
    cp = PLAN[key].get("client_port", 0)
    return host(name, addr, cp or None, CDN, CDN, frag=True, tls_=True)
def HOSTS(key):
    v6 = lambda n, **kw: [host(f"6️⃣ {n} · IPv6", PUB6, **kw)] if PUB6 else []
    if key == "rv": return [host("⚡ Reality Vision · Main", ADDR)] + v6("Reality Vision")
    if key == "rx": return [host("🌀 Reality XHTTP", ADDR)] + v6("Reality XHTTP")
    if key == "rg": return [host("🔷 Reality gRPC", ADDR)]
    if key == "tv": return [host("🔐 TLS Vision", ADDR, sni_=DOMAIN, tls_=True),
                            host("🧩 TLS Vision · Fragment", ADDR, sni_=DOMAIN, frag=True, tls_=True)] + v6("TLS Vision", sni_=DOMAIN, tls_=True)
    if key == "tx":
        h = [] if PLAN["tx"].get("origin_rule") else [host("🛰 TLS XHTTP", ADDR, sni_=DOMAIN, hhdr=DOMAIN, tls_=True)]
        return h + ([cdn_host("☁️ CDN XHTTP · Fragment", CDN, "tx")] if CDN else [])
    if key == "ws": return [cdn_host("☁️ CDN WS · Fragment", CDN, "ws")]
    if key == "hu": return [cdn_host("☁️ CDN HTTPUpgrade · Fragment", CDN, "hu")]
    if key == "hy": return [host("🚄 Hysteria2 · UDP", ADDR, sni_=DOMAIN, tls_=True, fp="none")]
    if key == "pq": return [host("🧬 PQ Sudoku · Beta", ADDR)]
    if key == "ov": return [host("🛡 OpenVPN · UDP", ADDR)]
    if key == "ot": return [host("🛡 OpenVPN · TCP", ADDR)]
    if key == "ss": return [host("🛟 Shadowsocks · Backup", ADDR)]
    return []
REMARK = {"rv": "reality-vision", "rx": "reality-xhttp", "rg": "reality-grpc", "tv": "tls-vision", "tx": "tls-xhttp",
          "ws": "cdn-ws", "hu": "cdn-httpupgrade", "hy": "hysteria2", "pq": "pq-sudoku", "ov": "openvpn-udp", "ot": "openvpn-tcp", "ss": "shadowsocks"}

# =========================================================================== apply
head("Adding")
bak = ""
if DB and os.path.exists(DB):
    bak = f"{DB}.bak-pro-{int(time.time())}"; shutil.copy(DB, bak); info("database backup:", bak)
else:
    warn("Rebecca uses MySQL/MariaDB (or the database file was not found) — no automatic backup was made.")
    warn("Everything added here is new and can be removed from the panel (Hosts / Services / Users / Inbounds).")
def listening(pt, udp, who="xray"):
    return who in sh(f"ss -H -{'u' if udp else 't'}lnp 'sport = :{pt}'")
def wait_listening(pt, udp, secs=45, who="xray"):
    for _ in range(secs // 2):
        time.sleep(2)
        if listening(pt, udp, who):
            return True
    return False

added = []                       # (key, tag)
for key, name, _, _ in SEL:
    if key not in PLAN:
        continue
    pt = PLAN[key]["port"]; proto, build = BUILD[key]
    try:
        st, stream = build()
    except Exception as e:
        warn(f"{name}: {e} — skipped"); continue
    tag = f"pro-{key}-{hx(2)}"
    body = {"tag": tag, "port": pt, "protocol": proto, "settings": st, "targets": [TARGET]}
    if stream is not None:                       # OpenVPN is a "virtual tunnel": no Xray stream / sniffing
        body.update({"streamSettings": stream, "sniffing": SNIFF})
    code, r = call("POST", "/api/inbounds", body)
    if not ok(code):
        warn(f"{name}: panel refused ({err(r)}) — skipped"); continue
    is_ov = key in ("ov", "ot")
    if is_ov:
        info(f"{name}: waiting for the node to install and start OpenVPN (first time can take a few minutes) ...")
    if wait_listening(pt, key in UDP_ONLY, 300 if is_ov else 45, "openvpn" if is_ov else "xray"):
        added.append((key, tag)); info(f"added {name:22s} port {pt}")
    else:
        warn(f"{name}: nothing started listening on {pt} on this server — removed again")
        call("DELETE", f"/api/inbounds/{tag}"); time.sleep(3)
if not added:
    die("Nothing could be added.")

# one new host list per new inbound (PUT /api/hosts only touches the inbound tags that are in the request)
payload = {}
clean_key = next((k for k in ("ws", "hu", "tx") if any(k == a for a, _ in added) and not PLAN[k].get("origin_rule")), None) \
    or next((k for k in ("ws", "hu", "tx") if any(k == a for a, _ in added)), None)
for key, tag in added:
    hosts = HOSTS(key)
    if key == clean_key and CLEAN:
        hosts += [cdn_host(f"🧊 Clean {i:02d} · {a}", a, key) for i, a in enumerate(CLEAN, 1)]
    payload[tag] = [h for h in hosts if h["address"]]
code, grouped = call("PUT", "/api/hosts", payload)
if not ok(code):
    for _, tag in added:
        call("DELETE", f"/api/inbounds/{tag}")
    die("Could not create the hosts:", err(grouped))
host_ids = []
for key, tag in added:
    by_remark = {h.get("remark"): h.get("id") for h in grouped.get(tag, [])}
    host_ids += [by_remark[h["remark"]] for h in payload[tag] if by_remark.get(h["remark"])]
n_links = len(host_ids)

# one NEW service that holds only these hosts, and one NEW user in it: existing users are never touched
code, svc = call("POST", "/api/v2/services", {"name": f"pro-config-{hx(2)}", "description": "created by pro-config",
                                               "hosts": [{"host_id": i, "sort": n} for n, i in enumerate(host_ids)]})
if not ok(code) or not svc.get("id"):
    die("Could not create the service:", err(svc), "(hosts and inbounds were kept; add them to a service in the panel)")
EMAIL = A.email or f"pro-{hx(2)}"
code, user = call("POST", "/api/user", {"username": EMAIL, "service_id": svc["id"], "status": "active"})
if not ok(code):
    die("Could not create the user:", err(user), f"(service {svc['id']} was kept)")
SUB = user.get("subscription_url") or ""
if SUB.startswith("/"):
    SUB = PANEL + SUB

# firewall + BBR
ufw = sh("ufw status 2>/dev/null | head -1")
if "Status: active" in ufw:
    for key, _ in added:
        pt = PLAN[key]["port"]
        if key not in UDP_ONLY: sh(f"ufw allow {pt}/tcp")
        if key in UDP_ONLY or key in BOTH: sh(f"ufw allow {pt}/udp")
    info("ufw: ports opened")
if not A.no_bbr and "bbr" not in sh("sysctl -n net.ipv4.tcp_congestion_control"):
    if yes("Enable BBR (faster TCP)?", True):
        open("/etc/sysctl.d/99-bbr.conf", "w").write("net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n")
        sh("modprobe tcp_bbr; sysctl --system")
        info("BBR:", sh("sysctl -n net.ipv4.tcp_congestion_control"))

# =========================================================================== test
passed = total = 0
JSUB = ""
if not A.no_test and XRAY and SUB:
    head("Testing every config (client → this server → internet)")
    time.sleep(8)                                    # let the panel push the new user to Xray
    sp = urlparse(SUB).path.rstrip("/")
    JSUB = SUB.rstrip("/") + "/v2ray-json"
    subs = []
    for _ in range(3):
        c, d = call("GET", sp + "/v2ray-json", token=False)
        if ok(c) and isinstance(d, (list, dict)) and d:
            subs = d if isinstance(d, list) else [d]; break
        time.sleep(5)
    if not subs:
        warn("could not read the JSON subscription — test skipped (the configs themselves were still added)")
    ins, outs, rules, meta = [], [], [], []
    for n, cfg in enumerate(subs):
        o = next((x for x in cfg.get("outbounds", []) if x.get("tag") == "proxy"), None)
        if not o:
            continue
        s = o.get("settings", {})
        via_cdn = CDN and (o.get("streamSettings", {}).get("tlsSettings") or {}).get("serverName") == CDN
        def fix(a):
            if via_cdn: return a                                    # really go through Cloudflare
            return "::1" if PUB6 and a == PUB6 else "127.0.0.1"
        for k in ("vnext", "servers"):
            for srv in s.get(k, []) or []: srv["address"] = fix(srv.get("address"))
        if "address" in s: s["address"] = fix(s["address"])
        o["tag"] = f"p{n}"; outs.append(o)
        ins.append({"tag": f"s{n}", "listen": "127.0.0.1", "port": 23000 + n, "protocol": "socks", "settings": {"udp": True}})
        rules.append({"type": "field", "inboundTag": [f"s{n}"], "outboundTag": f"p{n}"})
        meta.append((cfg.get("remarks", f"#{n}"), 23000 + n))
    if outs:
        json.dump({"log": {"loglevel": "none"}, "inbounds": ins, "outbounds": outs + [{"protocol": "freedom", "tag": "d"}],
                   "routing": {"rules": rules}}, open("/tmp/.rb-pro-e2e.json", "w"))
        pr = subprocess.Popen([XRAY, "run", "-c", "/tmp/.rb-pro-e2e.json"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3)
        def probe(m):
            name, pt = m
            for _ in range(2):
                if sh(f"curl -s -o /dev/null -m 15 -w '%{{http_code}}' --socks5-hostname 127.0.0.1:{pt} "
                      "https://www.google.com/generate_204", 20) == "204":
                    return name, True
            return name, False
        try:
            with cfut.ThreadPoolExecutor(6) as ex:
                for name, okk in ex.map(probe, meta):
                    total += 1; passed += okk
                    print(f"  {G + 'OK  ' + N if okk else R + 'FAIL' + N} {name}")
        finally:
            pr.terminate()
            try: os.remove("/tmp/.rb-pro-e2e.json")
            except Exception: pass
        info(f"{passed}/{total} configs work")

# =========================================================================== done
head("Done")
print(f"  user         {B}{EMAIL}{N}   (service '{svc.get('name')}', {len(added)} inbounds, {n_links} links)")
print(f"  subscription {B}{SUB}{N}")
if JSUB:
    print(f"  JSON sub     {B}{JSUB}{N}  {D}(use this one for FinalMask / Fragment configs){N}")
ports_txt = ", ".join(f"{PLAN[k]['port']}/{'udp' if k in UDP_ONLY else ('tcp+udp' if k in BOTH else 'tcp')}" for k, _ in added)
print(f"\n  Open in your cloud firewall (IPv4 + IPv6): {ports_txt}")
if CDN:
    print(f"  Cloudflare: {CDN} = proxied (orange) · {DOMAIN} = DNS only (grey) · SSL/TLS = Full")
rules_needed = [(k, PLAN[k]["port"]) for k, _ in added if PLAN[k].get("origin_rule")]
if rules_needed:
    print(f"\n  {Y}Cloudflare Origin Rules needed{N} (Rules > Origin Rules > Create):")
    for k, pt in rules_needed:
        print(f"    if Hostname = {CDN} AND URI Path starts with {PATHS.get(k, '/')}  →  Destination port = {pt}")
print(f"  {D}existing inbounds ({len(inbs)}) and hosts ({n_hosts_before}) were not changed{N}")
if bak:
    print(f"\n  backup: {bak}\n")
PYEOF

FALLBACK='time.is creativecommons.org www.digitalocean.com www.canva.com www.npmjs.com www.udemy.com cdnjs.com
172.67.153.64 141.101.120.172 104.19.214.18 104.16.165.243 188.114.98.19 172.66.160.120 190.93.246.88 188.114.99.132
104.17.24.19 104.21.114.162 104.24.68.75 188.114.97.156 162.159.140.108 141.101.121.20 104.21.63.243 188.114.97.251
104.27.49.141 190.93.244.210 104.25.60.147 104.16.77.102 188.114.96.74 104.27.96.96 104.18.29.233 104.19.44.112'
python3 - "$TMPPY" "$FALLBACK" <<'FIX'
import sys
p, fb = sys.argv[1], sys.argv[2]
s = open(p).read().replace("__FALLBACK_CLEAN__", repr([x for x in fb.split() if x]))
open(p, "w").write(s)
FIX
REPO_RAW="$REPO_RAW" python3 -I "$TMPPY" "$@"
