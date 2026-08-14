#!/usr/bin/env bash
#############################################################################
#                                                                           #
#   InfraPortal - Infrastructure Access Directory                           #
#   One-shot deployment script for Red Hat Enterprise Linux 10              #
#                                                                           #
#   What it builds:                                                         #
#     * A Python 3 (standard library only) web application + SQLite store   #
#     * systemd service listening on 127.0.0.1:8081                         #
#     * Apache httpd + mod_ssl in front of it, HTTPS only, HTTP redirected  #
#     * Self-signed certificate with correct SAN entries                    #
#     * 7 teams x ~10 sample entries, 8 user accounts, random passwords     #
#     * SELinux + firewalld configuration and a nightly database backup     #
#                                                                           #
#   Usage:   sudo ./deploy-infraportal.sh                                   #
#                                                                           #
#   Optional environment overrides:                                         #
#     PORTAL_SERVER_NAME=portal.corp.local   ServerName / cert CN           #
#     PORTAL_SERVER_IP=10.20.30.40           extra IP SAN on the cert       #
#     PORTAL_CERT_FILE=/path/to/server.crt   use a corporate certificate    #
#     PORTAL_KEY_FILE=/path/to/server.key    ...and its private key         #
#     PORTAL_CHAIN_FILE=/path/to/chain.pem   ...and its intermediate chain  #
#     PORTAL_FORCE_CERT=1                    regenerate the self-signed cert#
#                                                                           #
#   Safe to re-run: existing data, users and certificates are preserved.    #
#                                                                           #
#############################################################################

set -euo pipefail

# --------------------------------------------------------------------------
# Tunables
# --------------------------------------------------------------------------
PORTAL_USER="infraportal"
APP_DIR="/opt/infraportal"
DATA_DIR="/var/lib/infraportal"
BACKUP_DIR="${DATA_DIR}/backups"
APP_PORT="8081"
CRED_FILE="/root/infraportal-credentials.txt"
HTTPD_CONF="/etc/httpd/conf.d/infraportal.conf"
UNIT_FILE="/etc/systemd/system/infraportal.service"
CERT_DAYS="3650"

# Every lookup below is allowed to come back empty rather than abort the run;
# the pre-flight step turns a missing hostname into a readable error.
SERVER_NAME="${PORTAL_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '')}"
SERVER_SHORT="$(hostname -s 2>/dev/null || echo "${SERVER_NAME%%.*}")"
# Every address on the host, so browsing by IP works on any NIC without a
# certificate name mismatch. PORTAL_SERVER_IP may list several, space separated.
SERVER_IPS="${PORTAL_SERVER_IP:-$(hostname -I 2>/dev/null || true)}"
SERVER_IP="$(printf '%s' "$SERVER_IPS" | awk '{print $1}')"
CERT_FILE="${PORTAL_CERT_FILE:-/etc/pki/tls/certs/infraportal.crt}"
KEY_FILE="${PORTAL_KEY_FILE:-/etc/pki/tls/private/infraportal.key}"
CHAIN_FILE="${PORTAL_CHAIN_FILE:-}"

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%02d]%s %s%s%s\n' \
         "$C_BLUE" "$STEP" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
ok()   { printf '     %s+%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
info() { printf '     %s-%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
warn() { printf '     %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
die()  { printf '\n%sFAILED:%s %s\n\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

emit_asset() {
  local dest="$1" mode="${2:-0644}" owner="${3:-root:root}"
  install -d -m 0755 "$(dirname "$dest")"
  cat > "$dest"
  chown "$owner" "$dest"
  chmod "$mode" "$dest"
  ok "wrote ${dest}"
}

printf '%s\n' "$C_BOLD"
cat <<'BANNER'
   ___       __        ___          _        _
  |_ _|_ _  / _|_ _ __| _ \___ _ _ | |_ __ _| |
   | || ' \|  _| '_/ _|  _/ _ \ '_||  _/ _` | |
  |___|_||_|_| |_| \__|_| \___/_|   \__\__,_|_|

  Infrastructure Access Directory - RHEL 10 deployment
BANNER
printf '%s\n' "$C_RESET"

# --------------------------------------------------------------------------
step "Pre-flight checks"
# --------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This script must run as root (use sudo)."

if [ -r /etc/os-release ]; then
  . /etc/os-release
  info "detected: ${PRETTY_NAME:-unknown}"
  case "${ID:-} ${ID_LIKE:-}" in
    *rhel*|*fedora*|*centos*) : ;;
    *) warn "not an RHEL-family system - continuing, but untested here." ;;
  esac
  case "${VERSION_ID:-}" in
    10*) : ;;
    9*|8*) warn "built for RHEL 10; ${VERSION_ID} should work but is untested." ;;
    *) warn "unrecognised release ${VERSION_ID:-?} - continuing." ;;
  esac
else
  warn "/etc/os-release not readable - continuing."
fi

[ -n "$SERVER_NAME" ] || die "Could not determine a hostname; set PORTAL_SERVER_NAME."
info "ServerName ......: ${SERVER_NAME}"
info "Server IPs ......: ${SERVER_IPS:-<none detected>}"
ok "pre-flight checks passed"

# --------------------------------------------------------------------------
step "Installing packages from the configured repositories"
# --------------------------------------------------------------------------
NEEDED=""
for pkg in httpd mod_ssl openssl python3; do
  rpm -q "$pkg" >/dev/null 2>&1 || NEEDED="$NEEDED $pkg"
done

if [ -n "$NEEDED" ]; then
  info "installing:${NEEDED}"
  if ! dnf -y install $NEEDED; then
    warn "dnf install failed - checking whether the essentials are present anyway"
  fi
else
  ok "httpd, mod_ssl, openssl and python3 are already installed"
fi

command -v httpd    >/dev/null 2>&1 || die "httpd is not installed and could not be installed."
command -v python3  >/dev/null 2>&1 || die "python3 is not installed and could not be installed."
command -v openssl  >/dev/null 2>&1 || die "openssl is not installed and could not be installed."

PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
info "python3 version .: ${PY_VER}"
python3 -c 'import sqlite3, wsgiref, hashlib, secrets, csv, json' \
  || die "This python3 is missing standard modules the portal needs (sqlite3?)."
ok "runtime dependencies satisfied - no pip packages required"

if ! rpm -q policycoreutils-python-utils >/dev/null 2>&1; then
  dnf -y install policycoreutils-python-utils >/dev/null 2>&1 \
    && ok "installed policycoreutils-python-utils (for semanage)" \
    || info "policycoreutils-python-utils unavailable - will use an SELinux boolean instead"
fi

# --------------------------------------------------------------------------
step "Creating the service account and directory layout"
# --------------------------------------------------------------------------
if ! getent passwd "$PORTAL_USER" >/dev/null; then
  useradd --system --home-dir "$DATA_DIR" --create-home \
          --shell /sbin/nologin --comment "InfraPortal service account" \
          "$PORTAL_USER"
  ok "created system user ${PORTAL_USER}"
else
  ok "system user ${PORTAL_USER} already exists"
fi

install -d -m 0755 -o root -g root "$APP_DIR"
install -d -m 0755 -o root -g root "$APP_DIR/web"
install -d -m 0750 -o "$PORTAL_USER" -g "$PORTAL_USER" "$DATA_DIR"
install -d -m 0750 -o "$PORTAL_USER" -g "$PORTAL_USER" "$BACKUP_DIR"
ok "directories ready: ${APP_DIR}, ${DATA_DIR}"

# --------------------------------------------------------------------------
step "Writing the application"
# --------------------------------------------------------------------------
emit_asset "$APP_DIR/app.py" 0755 root:root <<'__INFRAPORTAL_ASSET_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
InfraPortal - Infrastructure Access Directory
=============================================
A dependency-free (Python standard library only) WSGI application that serves a
per-team catalogue of infrastructure tools: URLs, IPs/FQDNs, jump servers,
which credential to use and whether MFA is required.

  * View access  : public, no login required.
  * Edit access  : authenticated only, scoped to the user's own team.
  * Super user   : may edit every team.

Runs behind Apache httpd (mod_proxy) which terminates TLS.

CLI:
  app.py serve                       Run the WSGI server (default)
  app.py init                        Create schema + seed data, print credentials
  app.py listusers                   List portal users
  app.py passwd <user> <password>    Set a password
  app.py resetpw <user>              Generate and print a new password
  app.py adduser <user> <team|super> Create a user with a generated password
"""

import csv
import hashlib
import hmac
import io
import json
import logging
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.cookies import SimpleCookie
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

# --------------------------------------------------------------------------
# Configuration (all overridable through the systemd unit's Environment=)
# --------------------------------------------------------------------------
APP_ROOT = os.environ.get("PORTAL_ROOT", "/opt/infraportal")
WEB_DIR = os.environ.get("PORTAL_WEB", os.path.join(APP_ROOT, "web"))
DB_PATH = os.environ.get("PORTAL_DB", "/var/lib/infraportal/portal.db")
BIND_HOST = os.environ.get("PORTAL_BIND", "127.0.0.1")
BIND_PORT = int(os.environ.get("PORTAL_PORT", "8081"))
SESSION_HOURS = int(os.environ.get("PORTAL_SESSION_HOURS", "8"))
COOKIE_SECURE = os.environ.get("PORTAL_COOKIE_SECURE", "1") != "0"
MAX_FAILED_LOGINS = int(os.environ.get("PORTAL_MAX_FAILED_LOGINS", "5"))
LOCKOUT_MINUTES = int(os.environ.get("PORTAL_LOCKOUT_MINUTES", "15"))
MIN_PW_LEN = int(os.environ.get("PORTAL_MIN_PW_LEN", "12"))

PBKDF2_ITERATIONS = 240000
SESSION_COOKIE = "ipsid"
CSRF_COOKIE = "ipcsrf"
MAX_BODY = 8 * 1024 * 1024  # 8 MB, generous enough for a CSV bulk import

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
LOG = logging.getLogger("infraportal")

# --------------------------------------------------------------------------
# Controlled vocabularies. Adding a value here is all that is needed for it to
# become selectable in the UI - the front end reads these from /api/bootstrap.
# --------------------------------------------------------------------------
ENVIRONMENTS = ["Prod", "UAT", "DR"]
ACCESS_FROM = ["Laptop", "Jump Server", "Both"]
ACCESS_IDS = ["UID", "ADM ID", "Both", "Service Account"]
MFA_VALUES = ["Yes", "No"]
CATEGORIES = [
    "Admin Console", "Monitoring", "Automation", "Patching", "Backup",
    "Scheduler", "Database", "Cloud", "Security", "Storage", "Networking",
    "Logging", "Ticketing", "Documentation",
]

# Import/export column order. Also the canonical CSV header.
CSV_FIELDS = [
    "tool_name", "category", "environment", "url", "host",
    "jump_server", "jump_port", "access_from", "access_id", "mfa",
]

# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS teams (
    id          INTEGER PRIMARY KEY,
    slug        TEXT UNIQUE NOT NULL,
    name        TEXT NOT NULL,
    icon        TEXT NOT NULL DEFAULT '',
    color       TEXT NOT NULL DEFAULT '#6366f1',
    description TEXT NOT NULL DEFAULT '',
    sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS users (
    id             INTEGER PRIMARY KEY,
    username       TEXT UNIQUE NOT NULL COLLATE NOCASE,
    display_name   TEXT NOT NULL DEFAULT '',
    role           TEXT NOT NULL CHECK (role IN ('super','team')),
    team_id        INTEGER REFERENCES teams(id) ON DELETE CASCADE,
    salt           TEXT NOT NULL,
    pw_hash        TEXT NOT NULL,
    iterations     INTEGER NOT NULL,
    active         INTEGER NOT NULL DEFAULT 1,
    must_change_pw INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL DEFAULT '',
    last_login     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS entries (
    id          INTEGER PRIMARY KEY,
    team_id     INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    tool_name   TEXT NOT NULL,
    category    TEXT NOT NULL DEFAULT '',
    environment TEXT NOT NULL DEFAULT 'Prod',
    url         TEXT NOT NULL DEFAULT '',
    host        TEXT NOT NULL DEFAULT '',
    jump_server TEXT NOT NULL DEFAULT '',
    jump_port   TEXT NOT NULL DEFAULT '',
    access_from TEXT NOT NULL DEFAULT 'Laptop',
    access_id   TEXT NOT NULL DEFAULT 'UID',
    mfa         TEXT NOT NULL DEFAULT 'No',
    sort_order  INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT NOT NULL DEFAULT '',
    updated_by  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_entries_team ON entries(team_id, sort_order);

CREATE TABLE IF NOT EXISTS sessions (
    token      TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    csrf       TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    ip         TEXT NOT NULL DEFAULT '',
    ua         TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS audit (
    id         INTEGER PRIMARY KEY,
    ts         TEXT NOT NULL,
    username   TEXT NOT NULL DEFAULT '',
    team_id    INTEGER,
    team_slug  TEXT NOT NULL DEFAULT '',
    action     TEXT NOT NULL,
    entry_id   INTEGER,
    entry_name TEXT NOT NULL DEFAULT '',
    details    TEXT NOT NULL DEFAULT '',
    ip         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_audit_team ON audit(team_id, id DESC);

CREATE TABLE IF NOT EXISTS login_attempts (
    id       INTEGER PRIMARY KEY,
    username TEXT NOT NULL,
    ip       TEXT NOT NULL DEFAULT '',
    ts       TEXT NOT NULL,
    ok       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_attempts ON login_attempts(username, id DESC);
"""

_local = threading.local()


def db():
    """One SQLite connection per worker thread."""
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, timeout=20.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA busy_timeout=20000")
        _local.conn = conn
    return conn


def rows(sql, args=()):
    return [dict(r) for r in db().execute(sql, args).fetchall()]


def row(sql, args=()):
    r = db().execute(sql, args).fetchone()
    return dict(r) if r else None


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# Passwords and sessions
# --------------------------------------------------------------------------
PW_ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789@#%+=?"


def gen_password(length=16):
    return "".join(secrets.choice(PW_ALPHABET) for _ in range(length))


def hash_password(password, salt=None, iterations=PBKDF2_ITERATIONS):
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), bytes.fromhex(salt), iterations
    )
    return salt, dk.hex(), iterations


def verify_password(password, salt, expected, iterations):
    try:
        _, candidate, _ = hash_password(password, salt, iterations)
    except ValueError:
        return False
    return hmac.compare_digest(candidate, expected)


def create_session(user_id, ip, ua):
    token = secrets.token_urlsafe(32)
    csrf = secrets.token_urlsafe(24)
    expires = datetime.now(timezone.utc) + timedelta(hours=SESSION_HOURS)
    conn = db()
    conn.execute(
        "INSERT INTO sessions (token,user_id,csrf,created_at,expires_at,ip,ua)"
        " VALUES (?,?,?,?,?,?,?)",
        (token, user_id, csrf, now_iso(),
         expires.strftime("%Y-%m-%dT%H:%M:%SZ"), ip, ua[:200]),
    )
    conn.commit()
    return token, csrf


def load_session(token):
    if not token:
        return None
    r = row(
        "SELECT s.token, s.csrf, s.expires_at, u.id, u.username, u.display_name,"
        "       u.role, u.team_id, u.must_change_pw, u.active"
        "  FROM sessions s JOIN users u ON u.id = s.user_id"
        " WHERE s.token = ?",
        (token,),
    )
    if not r or not r["active"]:
        return None
    if r["expires_at"] < now_iso():
        db().execute("DELETE FROM sessions WHERE token=?", (token,))
        db().commit()
        return None
    return r


def is_locked_out(username):
    if MAX_FAILED_LOGINS <= 0:
        return False
    since = (datetime.now(timezone.utc) - timedelta(minutes=LOCKOUT_MINUTES)
             ).strftime("%Y-%m-%dT%H:%M:%SZ")
    r = row(
        "SELECT COUNT(*) AS n FROM login_attempts"
        " WHERE username=? AND ok=0 AND ts>?"
        "   AND id > COALESCE((SELECT MAX(id) FROM login_attempts"
        "                       WHERE username=? AND ok=1), 0)",
        (username, since, username),
    )
    return bool(r and r["n"] >= MAX_FAILED_LOGINS)


def record_attempt(username, ip, ok):
    conn = db()
    conn.execute(
        "INSERT INTO login_attempts (username,ip,ts,ok) VALUES (?,?,?,?)",
        (username, ip, now_iso(), 1 if ok else 0),
    )
    conn.commit()


def audit(req, action, team_id=None, team_slug="", entry_id=None,
          entry_name="", details=""):
    conn = db()
    conn.execute(
        "INSERT INTO audit (ts,username,team_id,team_slug,action,entry_id,"
        "entry_name,details,ip) VALUES (?,?,?,?,?,?,?,?,?)",
        (now_iso(), (req.user or {}).get("username", ""), team_id, team_slug,
         action, entry_id, entry_name, details, req.client_ip),
    )
    conn.commit()


# --------------------------------------------------------------------------
# HTTP plumbing
# --------------------------------------------------------------------------
class HttpError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def esc(value):
    return (str(value).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;").replace("'", "&#39;"))


class Req:
    def __init__(self, environ):
        self.environ = environ
        self.method = environ.get("REQUEST_METHOD", "GET").upper()
        self.path = environ.get("PATH_INFO", "/") or "/"
        self.query = parse_qs(environ.get("QUERY_STRING", ""), keep_blank_values=True)
        self.user = None
        self.session = None
        self._body = None
        # Apache appends the real peer to any X-Forwarded-For the client sent,
        # so the LAST element is the trustworthy one. Taking the first would
        # let a caller forge the address recorded in the audit trail.
        fwd = environ.get("HTTP_X_FORWARDED_FOR", "")
        self.client_ip = (fwd.split(",")[-1].strip()
                          if fwd else environ.get("REMOTE_ADDR", ""))
        self.cookies = SimpleCookie()
        try:
            self.cookies.load(environ.get("HTTP_COOKIE", ""))
        except Exception:
            self.cookies = SimpleCookie()

    def q(self, key, default=None):
        return self.query.get(key, [default])[0]

    def cookie(self, name):
        morsel = self.cookies.get(name)
        return morsel.value if morsel else None

    @property
    def body(self):
        if self._body is None:
            try:
                length = int(self.environ.get("CONTENT_LENGTH") or 0)
            except (TypeError, ValueError):
                length = 0
            length = max(0, min(length, MAX_BODY))
            self._body = (self.environ["wsgi.input"].read(length)
                          if length else b"")
        return self._body

    def json_body(self):
        if not self.body:
            return {}
        try:
            data = json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise HttpError("400 Bad Request", "Malformed JSON body")
        if not isinstance(data, dict):
            raise HttpError("400 Bad Request", "Expected a JSON object")
        return data

    def form_body(self):
        try:
            text = self.body.decode("utf-8")
        except UnicodeDecodeError:
            raise HttpError("400 Bad Request", "Malformed form body")
        return {k: v[0] for k, v in parse_qs(text, keep_blank_values=True).items()}


def response(body, status="200 OK", ctype="text/html; charset=utf-8",
             headers=None):
    if isinstance(body, str):
        body = body.encode("utf-8")
    hdrs = [("Content-Type", ctype), ("Content-Length", str(len(body)))]
    if headers:
        hdrs.extend(headers)
    return status, hdrs, body


def json_response(payload, status="200 OK", headers=None):
    return response(json.dumps(payload), status,
                    "application/json; charset=utf-8",
                    (headers or []) + [("Cache-Control", "no-store")])


def redirect(location, headers=None):
    return response(b"", "303 See Other", "text/plain",
                    (headers or []) + [("Location", location)])


def cookie_header(name, value, max_age=None, http_only=True):
    parts = ["%s=%s" % (name, value), "Path=/", "SameSite=Lax"]
    if http_only:
        parts.append("HttpOnly")
    if COOKIE_SECURE:
        parts.append("Secure")
    if max_age is not None:
        parts.append("Max-Age=%d" % max_age)
    return ("Set-Cookie", "; ".join(parts))


def render_template(filename, mapping):
    with open(os.path.join(WEB_DIR, filename), "r", encoding="utf-8") as fh:
        html = fh.read()
    for key, value in mapping.items():
        html = html.replace("{{%s}}" % key, value)
    return html


# --------------------------------------------------------------------------
# Authorisation helpers
# --------------------------------------------------------------------------
def require_login(req):
    if not req.user:
        raise HttpError("401 Unauthorized", "Authentication required")
    return req.user


def require_csrf(req):
    token = (req.environ.get("HTTP_X_CSRF_TOKEN", "")
             or (req.query.get("csrf", [""])[0]))
    if not req.session or not hmac.compare_digest(token, req.session["csrf"]):
        raise HttpError("403 Forbidden", "Invalid or missing CSRF token")


def can_edit(user, team_id):
    if not user:
        return False
    if user["role"] == "super":
        return True
    return user["team_id"] == team_id


def require_edit(req, team_id):
    require_login(req)
    if not can_edit(req.user, team_id):
        raise HttpError("403 Forbidden",
                        "Your account may only edit its own team")


def team_by_slug(slug):
    t = row("SELECT * FROM teams WHERE slug=?", (slug or "",))
    if not t:
        raise HttpError("404 Not Found", "Unknown team")
    return t


def team_by_id(team_id):
    t = row("SELECT * FROM teams WHERE id=?", (team_id,))
    if not t:
        raise HttpError("404 Not Found", "Unknown team")
    return t


# --------------------------------------------------------------------------
# Entry validation
# --------------------------------------------------------------------------
SAFE_URL = re.compile(r"^https?://", re.I)


def clean(value, limit=200):
    return re.sub(r"[\x00-\x1f\x7f]", "", str(value or "")).strip()[:limit]


def validate_entry(payload):
    out = {}
    out["tool_name"] = clean(payload.get("tool_name"), 120)
    if not out["tool_name"]:
        raise HttpError("400 Bad Request", "Tool name is required")

    out["category"] = clean(payload.get("category"), 40)
    out["host"] = clean(payload.get("host"), 200)
    out["jump_server"] = clean(payload.get("jump_server"), 200)

    url = clean(payload.get("url"), 500)
    if url and not SAFE_URL.match(url):
        raise HttpError("400 Bad Request",
                        "URL must start with http:// or https://")
    out["url"] = url

    port = clean(payload.get("jump_port"), 5)
    if port and (not port.isdigit() or not 1 <= int(port) <= 65535):
        raise HttpError("400 Bad Request", "Jump port must be 1-65535")
    out["jump_port"] = port

    for field, allowed, default in (
        ("environment", ENVIRONMENTS, "Prod"),
        ("access_from", ACCESS_FROM, "Laptop"),
        ("access_id", ACCESS_IDS, "UID"),
        ("mfa", MFA_VALUES, "No"),
    ):
        value = clean(payload.get(field), 20) or default
        if value not in allowed:
            raise HttpError("400 Bad Request",
                            "%s must be one of: %s" % (field, ", ".join(allowed)))
        out[field] = value

    if not out["host"] and not out["url"]:
        raise HttpError("400 Bad Request",
                        "Provide at least a URL or an IP/FQDN")
    return out


# --------------------------------------------------------------------------
# Handlers
# --------------------------------------------------------------------------
def h_shell(req, *_args):
    with open(os.path.join(WEB_DIR, "index.html"), "rb") as fh:
        return response(fh.read(), headers=[("Cache-Control", "no-cache")])


def h_health(req, *_args):
    counts = row("SELECT (SELECT COUNT(*) FROM teams) AS teams,"
                 " (SELECT COUNT(*) FROM entries) AS entries,"
                 " (SELECT COUNT(*) FROM users) AS users")
    return json_response({"status": "ok", "time": now_iso(), "counts": counts})


STATIC_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".png": "image/png",
    ".webmanifest": "application/manifest+json",
}


def h_static(req, name):
    if "/" in name or ".." in name:
        raise HttpError("404 Not Found", "Not found")
    ext = os.path.splitext(name)[1].lower()
    if ext not in STATIC_TYPES:
        raise HttpError("404 Not Found", "Not found")
    path = os.path.join(WEB_DIR, name)
    if not os.path.isfile(path):
        raise HttpError("404 Not Found", "Not found")
    stat = os.stat(path)
    etag = '"%x-%x"' % (int(stat.st_mtime), stat.st_size)
    if req.environ.get("HTTP_IF_NONE_MATCH") == etag:
        return "304 Not Modified", [("ETag", etag)], b""
    with open(path, "rb") as fh:
        data = fh.read()
    return response(data, ctype=STATIC_TYPES[ext],
                    headers=[("ETag", etag),
                             ("Cache-Control", "public, max-age=300")])


def safe_next(value):
    if value and value.startswith("/") and not value.startswith("//"):
        return value
    return "/"


def h_login_page(req, *_args):
    if req.user:
        return redirect(safe_next(req.q("next")))
    token = secrets.token_urlsafe(24)
    html = render_template("login.html", {
        "ERROR": "",
        "CSRF": esc(token),
        "NEXT": esc(safe_next(req.q("next"))),
        "NOTICE": "",
    })
    return response(html, headers=[
        cookie_header(CSRF_COOKIE, token, max_age=1800, http_only=False),
        ("Cache-Control", "no-store"),
    ])


def h_login_post(req, *_args):
    form = req.form_body()
    posted = form.get("csrf", "")
    cookie = req.cookie(CSRF_COOKIE) or ""
    username = clean(form.get("username"), 64)
    password = form.get("password", "")
    nxt = safe_next(form.get("next"))

    def fail(message):
        token = secrets.token_urlsafe(24)
        html = render_template("login.html", {
            "ERROR": esc(message),
            "CSRF": esc(token),
            "NEXT": esc(nxt),
            "NOTICE": "",
        })
        return response(html, "401 Unauthorized", headers=[
            cookie_header(CSRF_COOKIE, token, max_age=1800, http_only=False),
            ("Cache-Control", "no-store"),
        ])

    if not posted or not hmac.compare_digest(posted, cookie):
        return fail("Session expired, please try again.")
    if not username or not password:
        return fail("Username and password are required.")
    if is_locked_out(username):
        LOG.warning("login locked out user=%s ip=%s", username, req.client_ip)
        return fail("Too many failed attempts. Try again in %d minutes."
                    % LOCKOUT_MINUTES)

    user = row("SELECT * FROM users WHERE username=? AND active=1", (username,))
    ok = bool(user) and verify_password(
        password, user["salt"], user["pw_hash"], user["iterations"])
    record_attempt(username, req.client_ip, ok)
    if not ok:
        LOG.warning("login failed user=%s ip=%s", username, req.client_ip)
        return fail("Invalid username or password.")

    token, _csrf = create_session(user["id"], req.client_ip,
                                  req.environ.get("HTTP_USER_AGENT", ""))
    conn = db()
    conn.execute("UPDATE users SET last_login=? WHERE id=?",
                 (now_iso(), user["id"]))
    conn.commit()
    req.user = user
    audit(req, "login", user["team_id"], "", None, "", "signed in")
    LOG.info("login ok user=%s ip=%s", username, req.client_ip)
    target = "/account?first=1" if user["must_change_pw"] else nxt
    return redirect(target, headers=[
        cookie_header(SESSION_COOKIE, token, max_age=SESSION_HOURS * 3600),
    ])


def h_logout(req, *_args):
    if req.session:
        conn = db()
        conn.execute("DELETE FROM sessions WHERE token=?",
                     (req.session["token"],))
        conn.commit()
    return redirect("/", headers=[cookie_header(SESSION_COOKIE, "", max_age=0)])


def h_account_page(req, *_args):
    if not req.user:
        return redirect("/login?next=/account")
    notice = ""
    if req.q("first") or req.user["must_change_pw"]:
        notice = ("This account is still using its generated password. "
                  "Please choose a new one before editing anything.")
    if req.q("done"):
        notice = "Password updated successfully."
    team = ("All teams" if req.user["role"] == "super"
            else (team_by_id(req.user["team_id"])["name"]
                  if req.user["team_id"] else "-"))
    html = render_template("account.html", {
        "ERROR": "",
        "NOTICE": esc(notice),
        "CSRF": esc(req.session["csrf"]),
        "USERNAME": esc(req.user["username"]),
        "ROLE": esc("Super user" if req.user["role"] == "super" else "Team editor"),
        "TEAM": esc(team),
        "MINLEN": str(MIN_PW_LEN),
    })
    return response(html, headers=[("Cache-Control", "no-store")])


def h_password_post(req, *_args):
    user = require_login(req)
    form = req.form_body()
    if not hmac.compare_digest(form.get("csrf", ""), req.session["csrf"]):
        raise HttpError("403 Forbidden", "Invalid CSRF token")
    current = form.get("current", "")
    new = form.get("new", "")
    confirm = form.get("confirm", "")

    def fail(message):
        html = render_template("account.html", {
            "ERROR": esc(message),
            "NOTICE": "",
            "CSRF": esc(req.session["csrf"]),
            "USERNAME": esc(user["username"]),
            "ROLE": esc("Super user" if user["role"] == "super"
                        else "Team editor"),
            "TEAM": esc("All teams" if user["role"] == "super"
                        else (team_by_id(user["team_id"])["name"]
                              if user["team_id"] else "-")),
            "MINLEN": str(MIN_PW_LEN),
        })
        return response(html, "400 Bad Request",
                        headers=[("Cache-Control", "no-store")])

    full = row("SELECT * FROM users WHERE id=?", (user["id"],))
    if not verify_password(current, full["salt"], full["pw_hash"],
                           full["iterations"]):
        return fail("Current password is incorrect.")
    if len(new) < MIN_PW_LEN:
        return fail("New password must be at least %d characters." % MIN_PW_LEN)
    if new != confirm:
        return fail("New password and confirmation do not match.")
    if new == current:
        return fail("New password must be different from the current one.")

    salt, digest, iterations = hash_password(new)
    conn = db()
    conn.execute(
        "UPDATE users SET salt=?, pw_hash=?, iterations=?, must_change_pw=0"
        " WHERE id=?", (salt, digest, iterations, user["id"]))
    conn.execute("DELETE FROM sessions WHERE user_id=? AND token<>?",
                 (user["id"], req.session["token"]))
    conn.commit()
    audit(req, "password_change", user["team_id"], "", None, "",
          "password changed")
    LOG.info("password changed user=%s", user["username"])
    return redirect("/account?done=1")


def h_bootstrap(req, *_args):
    teams = rows("SELECT id,slug,name,icon,color,description,sort_order"
                 " FROM teams ORDER BY sort_order, name")
    stats = {r["team_id"]: r for r in rows(
        "SELECT team_id, COUNT(*) AS total,"
        " SUM(CASE WHEN mfa='Yes' THEN 1 ELSE 0 END) AS mfa,"
        " SUM(CASE WHEN jump_server<>'' THEN 1 ELSE 0 END) AS jump"
        " FROM entries GROUP BY team_id")}
    for team in teams:
        s = stats.get(team["id"], {})
        team["count"] = s.get("total", 0) or 0
        team["mfa_count"] = s.get("mfa", 0) or 0
        team["jump_count"] = s.get("jump", 0) or 0

    user = None
    if req.user:
        user = {
            "username": req.user["username"],
            "display_name": req.user["display_name"],
            "role": req.user["role"],
            "team_id": req.user["team_id"],
            "must_change_pw": bool(req.user["must_change_pw"]),
            "csrf": req.session["csrf"],
            "editable": ([t["id"] for t in teams]
                         if req.user["role"] == "super"
                         else [req.user["team_id"]]),
        }
    return json_response({
        "teams": teams,
        "user": user,
        "vocab": {
            "environments": ENVIRONMENTS,
            "access_from": ACCESS_FROM,
            "access_ids": ACCESS_IDS,
            "mfa": MFA_VALUES,
            "categories": CATEGORIES,
        },
        "generated": now_iso(),
    })


def h_entries_list(req, *_args):
    slug = req.q("team")
    if slug and slug != "all":
        team = team_by_slug(slug)
        data = rows("SELECT * FROM entries WHERE team_id=?"
                    " ORDER BY sort_order, tool_name", (team["id"],))
    else:
        data = rows("SELECT * FROM entries ORDER BY team_id, sort_order,"
                    " tool_name")
    return json_response({"entries": data})


def h_entry_create(req, *_args):
    payload = req.json_body()
    team = team_by_slug(clean(payload.get("team"), 40))
    require_edit(req, team["id"])
    require_csrf(req)
    fields = validate_entry(payload)

    conn = db()
    nxt = row("SELECT COALESCE(MAX(sort_order),0)+1 AS n FROM entries"
              " WHERE team_id=?", (team["id"],))["n"]
    cur = conn.execute(
        "INSERT INTO entries (team_id,tool_name,category,environment,url,host,"
        "jump_server,jump_port,access_from,access_id,mfa,sort_order,updated_at,"
        "updated_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (team["id"], fields["tool_name"], fields["category"],
         fields["environment"], fields["url"], fields["host"],
         fields["jump_server"], fields["jump_port"], fields["access_from"],
         fields["access_id"], fields["mfa"], nxt, now_iso(),
         req.user["username"]))
    conn.commit()
    entry_id = cur.lastrowid
    audit(req, "create", team["id"], team["slug"], entry_id,
          fields["tool_name"], "entry created")
    return json_response({"entry": row("SELECT * FROM entries WHERE id=?",
                                       (entry_id,))}, "201 Created")


def h_entry_update(req, entry_id):
    existing = row("SELECT * FROM entries WHERE id=?", (int(entry_id),))
    if not existing:
        raise HttpError("404 Not Found", "Entry not found")
    require_edit(req, existing["team_id"])
    require_csrf(req)
    fields = validate_entry(req.json_body())

    changed = [k for k in fields if str(existing.get(k, "")) != fields[k]]
    conn = db()
    conn.execute(
        "UPDATE entries SET tool_name=?,category=?,environment=?,url=?,host=?,"
        "jump_server=?,jump_port=?,access_from=?,access_id=?,mfa=?,"
        "updated_at=?,updated_by=? WHERE id=?",
        (fields["tool_name"], fields["category"], fields["environment"],
         fields["url"], fields["host"], fields["jump_server"],
         fields["jump_port"], fields["access_from"], fields["access_id"],
         fields["mfa"], now_iso(), req.user["username"], existing["id"]))
    conn.commit()
    team = team_by_id(existing["team_id"])
    audit(req, "update", team["id"], team["slug"], existing["id"],
          fields["tool_name"],
          "changed: " + (", ".join(changed) if changed else "no field values"))
    return json_response({"entry": row("SELECT * FROM entries WHERE id=?",
                                       (existing["id"],))})


def h_entry_delete(req, entry_id):
    existing = row("SELECT * FROM entries WHERE id=?", (int(entry_id),))
    if not existing:
        raise HttpError("404 Not Found", "Entry not found")
    require_edit(req, existing["team_id"])
    require_csrf(req)
    conn = db()
    conn.execute("DELETE FROM entries WHERE id=?", (existing["id"],))
    conn.commit()
    team = team_by_id(existing["team_id"])
    audit(req, "delete", team["id"], team["slug"], existing["id"],
          existing["tool_name"], "entry deleted")
    return json_response({"deleted": existing["id"]})


def h_export(req, *_args):
    slug = req.q("team", "all")
    if slug and slug != "all":
        team = team_by_slug(slug)
        data = rows("SELECT * FROM entries WHERE team_id=?"
                    " ORDER BY sort_order, tool_name", (team["id"],))
        label = team["slug"]
    else:
        data = rows("SELECT * FROM entries ORDER BY team_id, sort_order,"
                    " tool_name")
        label = "all-teams"
    slugs = {t["id"]: t["slug"] for t in rows("SELECT id,slug FROM teams")}

    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerow(["team"] + CSV_FIELDS + ["updated_at", "updated_by"])
    for entry in data:
        writer.writerow([slugs.get(entry["team_id"], "")]
                        + [entry.get(f, "") for f in CSV_FIELDS]
                        + [entry.get("updated_at", ""),
                           entry.get("updated_by", "")])
    filename = "infraportal-%s-%s.csv" % (label,
                                          datetime.now().strftime("%Y%m%d"))
    return response(buf.getvalue(), ctype="text/csv; charset=utf-8", headers=[
        ("Content-Disposition", 'attachment; filename="%s"' % filename),
        ("Cache-Control", "no-store"),
    ])


def h_import(req, *_args):
    payload = req.json_body()
    team = team_by_slug(clean(payload.get("team"), 40))
    require_edit(req, team["id"])
    require_csrf(req)
    mode = "replace" if payload.get("mode") == "replace" else "append"
    text = payload.get("csv", "")
    if not isinstance(text, str) or not text.strip():
        raise HttpError("400 Bad Request", "CSV content is empty")

    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        raise HttpError("400 Bad Request", "CSV has no header row")
    headers = [(h or "").strip().lower() for h in reader.fieldnames]
    if "tool_name" not in headers:
        raise HttpError("400 Bad Request",
                        "CSV header must contain at least 'tool_name'")

    parsed, errors = [], []
    for number, raw in enumerate(reader, start=2):
        record = {(k or "").strip().lower(): (v or "")
                  for k, v in raw.items() if k}
        if not any(v.strip() for v in record.values()):
            continue
        try:
            parsed.append(validate_entry(record))
        except HttpError as exc:
            errors.append("row %d: %s" % (number, exc.message))
        if len(errors) >= 20:
            break
    if errors:
        raise HttpError("400 Bad Request",
                        "Import rejected - " + "; ".join(errors))
    if not parsed:
        raise HttpError("400 Bad Request", "No usable rows found in the CSV")

    # sqlite3 opens an implicit transaction at the first write below, so the
    # delete + inserts either all land or none of them do.
    conn = db()
    removed = 0
    try:
        if mode == "replace":
            removed = conn.execute("SELECT COUNT(*) FROM entries WHERE team_id=?",
                                   (team["id"],)).fetchone()[0]
            conn.execute("DELETE FROM entries WHERE team_id=?", (team["id"],))
            order = 0
        else:
            order = conn.execute("SELECT COALESCE(MAX(sort_order),0) FROM entries"
                                 " WHERE team_id=?", (team["id"],)).fetchone()[0]
        for fields in parsed:
            order += 1
            conn.execute(
                "INSERT INTO entries (team_id,tool_name,category,environment,"
                "url,host,jump_server,jump_port,access_from,access_id,mfa,"
                "sort_order,updated_at,updated_by)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (team["id"], fields["tool_name"], fields["category"],
                 fields["environment"], fields["url"], fields["host"],
                 fields["jump_server"], fields["jump_port"],
                 fields["access_from"], fields["access_id"], fields["mfa"],
                 order, now_iso(), req.user["username"]))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    audit(req, "import", team["id"], team["slug"], None, "",
          "%s import: %d row(s) added, %d removed" % (mode, len(parsed), removed))
    return json_response({"imported": len(parsed), "removed": removed,
                          "mode": mode})


def h_audit(req, *_args):
    user = require_login(req)
    slug = req.q("team", "all")
    try:
        limit = max(1, min(int(req.q("limit", "100") or 100), 500))
    except ValueError:
        limit = 100
    if user["role"] == "super":
        if slug and slug != "all":
            team = team_by_slug(slug)
            data = rows("SELECT * FROM audit WHERE team_id=? ORDER BY id DESC"
                        " LIMIT ?", (team["id"], limit))
        else:
            data = rows("SELECT * FROM audit ORDER BY id DESC LIMIT ?", (limit,))
    else:
        data = rows("SELECT * FROM audit WHERE team_id=? ORDER BY id DESC"
                    " LIMIT ?", (user["team_id"], limit))
    return json_response({"audit": data})


ROUTES = [
    ("GET", re.compile(r"^/$"), h_shell),
    ("GET", re.compile(r"^/t/[A-Za-z0-9_-]+$"), h_shell),
    ("GET", re.compile(r"^/health$"), h_health),
    ("GET", re.compile(r"^/static/([A-Za-z0-9._-]+)$"), h_static),
    ("GET", re.compile(r"^/login$"), h_login_page),
    ("POST", re.compile(r"^/login$"), h_login_post),
    ("POST", re.compile(r"^/logout$"), h_logout),
    ("GET", re.compile(r"^/account$"), h_account_page),
    ("POST", re.compile(r"^/account/password$"), h_password_post),
    ("GET", re.compile(r"^/api/bootstrap$"), h_bootstrap),
    ("GET", re.compile(r"^/api/entries$"), h_entries_list),
    ("POST", re.compile(r"^/api/entries$"), h_entry_create),
    ("PUT", re.compile(r"^/api/entries/(\d+)$"), h_entry_update),
    ("DELETE", re.compile(r"^/api/entries/(\d+)$"), h_entry_delete),
    ("GET", re.compile(r"^/api/export$"), h_export),
    ("POST", re.compile(r"^/api/import$"), h_import),
    ("GET", re.compile(r"^/api/audit$"), h_audit),
]


def dispatch(req):
    path = req.path.rstrip("/") or "/"
    allowed = set()
    for method, pattern, handler in ROUTES:
        match = pattern.match(path)
        if not match:
            continue
        if method != req.method:
            allowed.add(method)
            continue
        return handler(req, *match.groups())
    if allowed:
        raise HttpError("405 Method Not Allowed", "Method not allowed")
    raise HttpError("404 Not Found", "Not found")


def application(environ, start_response):
    req = Req(environ)
    try:
        req.session = load_session(req.cookie(SESSION_COOKIE))
        if req.session:
            req.user = {
                "id": req.session["id"],
                "username": req.session["username"],
                "display_name": req.session["display_name"],
                "role": req.session["role"],
                "team_id": req.session["team_id"],
                "must_change_pw": req.session["must_change_pw"],
            }
        status, headers, body = dispatch(req)
    except HttpError as exc:
        if req.path.startswith("/api/"):
            status, headers, body = json_response({"error": exc.message},
                                                  exc.status)
        else:
            status, headers, body = response(
                "<h1>%s</h1><p>%s</p><p><a href=\"/\">Back to the portal</a></p>"
                % (esc(exc.status), esc(exc.message)), exc.status)
    except Exception:
        LOG.exception("unhandled error on %s %s", req.method, req.path)
        status, headers, body = json_response(
            {"error": "Internal server error"}, "500 Internal Server Error")
    headers = list(headers) + [("X-Content-Type-Options", "nosniff")]
    start_response(status, headers)
    return [body]


class ThreadingWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True
    request_queue_size = 64


class QuietHandler(WSGIRequestHandler):
    def log_message(self, fmt, *args):
        LOG.info("%s %s", self.address_string(), fmt % args)


def janitor():
    """Housekeeping: expire sessions and trim old login attempts."""
    while True:
        time.sleep(600)
        try:
            conn = db()
            conn.execute("DELETE FROM sessions WHERE expires_at < ?", (now_iso(),))
            cutoff = (datetime.now(timezone.utc) - timedelta(days=7)
                      ).strftime("%Y-%m-%dT%H:%M:%SZ")
            conn.execute("DELETE FROM login_attempts WHERE ts < ?", (cutoff,))
            conn.commit()
        except Exception:
            LOG.exception("janitor pass failed")


# --------------------------------------------------------------------------
# Seed data - about ten representative entries per team
# --------------------------------------------------------------------------
TEAMS_SEED = [
    ("windows", "Windows", "\N{PERSONAL COMPUTER}", "#3b82f6",
     "Active Directory, MECM, WSUS and Windows server estate", 10),
    ("linux", "Linux", "\N{PENGUIN}", "#f97316",
     "RHEL estate, Satellite, Ansible and the Linux jump hosts", 20),
    ("middleware", "Middleware", "\N{JIGSAW PUZZLE PIECE}", "#a855f7",
     "WebSphere, JBoss, Tomcat, MQ and web tier consoles", 30),
    ("database", "Database", "\N{FILE CABINET}", "#10b981",
     "Oracle, SQL Server, PostgreSQL, MySQL and Mongo estates", 40),
    ("storage", "Storage & Backup", "\N{FLOPPY DISK}", "#06b6d4",
     "SAN/NAS arrays, fabric managers and backup consoles", 50),
    ("controlm", "Control-M", "\N{ALARM CLOCK}", "#eab308",
     "Control-M EM, servers, agents and MFT", 60),
    ("cloudops", "CloudOps", "\N{CLOUD}", "#ec4899",
     "AWS, Azure, OpenShift, Terraform and the CI/CD chain", 70),
]

ENTRIES_SEED = {
    "windows": [
        ("Active Directory Users & Computers", "Admin Console", "Prod", "",
         "adds01.corp.local", "jmp-win-01.corp.local", "3389", "Jump Server",
         "ADM ID", "Yes"),
        ("MECM / SCCM Console", "Admin Console", "Prod", "",
         "sccm01.corp.local", "jmp-win-01.corp.local", "3389", "Jump Server",
         "ADM ID", "Yes"),
        ("Windows Admin Center", "Admin Console", "Prod",
         "https://wac.corp.local", "wac01.corp.local", "", "", "Laptop",
         "ADM ID", "Yes"),
        ("WSUS Administration Console", "Patching", "Prod", "",
         "wsus01.corp.local", "jmp-win-01.corp.local", "3389", "Jump Server",
         "ADM ID", "No"),
        ("Failover Cluster Manager (Hyper-V)", "Admin Console", "Prod", "",
         "hvclu01.corp.local", "jmp-win-02.corp.local", "3389", "Jump Server",
         "ADM ID", "Yes"),
        ("AD Certificate Services (PKI Web Enrollment)", "Security", "Prod",
         "https://pki.corp.local/certsrv", "pki01.corp.local", "", "",
         "Laptop", "ADM ID", "Yes"),
        ("Group Policy Management Console", "Admin Console", "Prod", "",
         "adds01.corp.local", "jmp-win-01.corp.local", "3389", "Jump Server",
         "ADM ID", "Yes"),
        ("DFS Namespace & File Server Manager", "Admin Console", "Prod", "",
         "fs-dfs01.corp.local", "jmp-win-02.corp.local", "3389",
         "Jump Server", "ADM ID", "No"),
        ("MECM Console - UAT", "Admin Console", "UAT", "",
         "sccm-uat01.corp.local", "jmp-win-uat01.corp.local", "3389",
         "Jump Server", "UID", "No"),
        ("Domain Controller - DR Site", "Admin Console", "DR", "",
         "adds-dr01.dr.corp.local", "jmp-win-dr01.dr.corp.local", "3389",
         "Jump Server", "ADM ID", "Yes"),
    ],
    "linux": [
        ("Red Hat Satellite", "Patching", "Prod", "https://satellite.corp.local",
         "sat01.corp.local", "", "", "Laptop", "UID", "Yes"),
        ("Ansible Automation Platform", "Automation", "Prod",
         "https://aap.corp.local", "aap01.corp.local", "", "", "Laptop",
         "UID", "Yes"),
        ("Linux Jump Server - Primary", "Admin Console", "Prod", "",
         "jmp-lnx-01.corp.local", "jmp-lnx-01.corp.local", "22", "Laptop",
         "ADM ID", "Yes"),
        ("Cockpit Web Console", "Admin Console", "Prod",
         "https://cockpit.corp.local:9090", "cockpit01.corp.local",
         "jmp-lnx-01.corp.local", "22", "Both", "ADM ID", "No"),
        ("Zabbix Monitoring", "Monitoring", "Prod",
         "https://zabbix.corp.local/zabbix", "zbx01.corp.local", "", "",
         "Laptop", "UID", "No"),
        ("Red Hat Hybrid Cloud Console (Insights)", "Cloud", "Prod",
         "https://console.redhat.com/insights", "console.redhat.com", "", "",
         "Laptop", "UID", "Yes"),
        ("Central rsyslog Collector", "Logging", "Prod", "",
         "logsrv01.corp.local", "jmp-lnx-01.corp.local", "22", "Jump Server",
         "ADM ID", "No"),
        ("BIND DNS / NTP Master", "Networking", "Prod", "",
         "dns01.corp.local", "jmp-lnx-01.corp.local", "22", "Jump Server",
         "ADM ID", "No"),
        ("Linux Jump Server - UAT", "Admin Console", "UAT", "",
         "jmp-lnx-uat01.corp.local", "jmp-lnx-uat01.corp.local", "22",
         "Laptop", "UID", "No"),
        ("Linux Jump Server - DR Site", "Admin Console", "DR", "",
         "jmp-lnx-dr01.dr.corp.local", "jmp-lnx-dr01.dr.corp.local", "22",
         "Laptop", "ADM ID", "Yes"),
    ],
    "middleware": [
        ("WebSphere ND Deployment Manager", "Admin Console", "Prod",
         "https://was-dmgr01.corp.local:9043/ibm/console",
         "was-dmgr01.corp.local", "jmp-mw-01.corp.local", "22", "Jump Server",
         "ADM ID", "Yes"),
        ("JBoss EAP Management Console", "Admin Console", "Prod",
         "https://jboss01.corp.local:9990", "jboss01.corp.local",
         "jmp-mw-01.corp.local", "22", "Jump Server", "ADM ID", "Yes"),
        ("Tomcat Manager", "Admin Console", "Prod",
         "https://tomcat01.corp.local:8443/manager", "tomcat01.corp.local",
         "jmp-mw-01.corp.local", "22", "Jump Server", "ADM ID", "Yes"),
        ("IBM MQ Web Console", "Admin Console", "Prod",
         "https://mq01.corp.local:9443/ibmmq/console", "mq01.corp.local",
         "jmp-mw-02.corp.local", "22", "Jump Server", "ADM ID", "Yes"),
        ("WebLogic Admin Console", "Admin Console", "Prod",
         "https://wls-admin01.corp.local:7002/console", "wls-admin01.corp.local",
         "jmp-mw-02.corp.local", "22", "Jump Server", "ADM ID", "Yes"),
        ("IBM HTTP Server (Web Tier)", "Admin Console", "Prod", "",
         "ihs01.corp.local", "jmp-mw-01.corp.local", "22", "Jump Server",
         "ADM ID", "No"),
        ("NGINX Plus Dashboard", "Monitoring", "Prod",
         "https://nginxplus.corp.local/dashboard.html", "nginxplus.corp.local",
         "", "", "Laptop", "UID", "No"),
        ("Kafka Control Center", "Monitoring", "Prod",
         "https://kafka-cc.corp.local:9021", "kafka-cc.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("WebSphere Console - UAT", "Admin Console", "UAT",
         "https://was-dmgr-uat01.corp.local:9043/ibm/console",
         "was-dmgr-uat01.corp.local", "jmp-mw-uat01.corp.local", "22",
         "Jump Server", "UID", "No"),
        ("WebSphere Deployment Manager - DR", "Admin Console", "DR",
         "https://was-dmgr-dr01.dr.corp.local:9043/ibm/console",
         "was-dmgr-dr01.dr.corp.local", "jmp-mw-dr01.dr.corp.local", "22",
         "Jump Server", "ADM ID", "Yes"),
    ],
    "database": [
        ("Oracle Enterprise Manager Cloud Control", "Database", "Prod",
         "https://oem.corp.local:7803/em", "oem01.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("Oracle RAC SCAN Listener", "Database", "Prod", "",
         "rac-scan.corp.local:1521", "jmp-db-01.corp.local", "22",
         "Jump Server", "ADM ID", "No"),
        ("SQL Server - Production Instance (SSMS)", "Database", "Prod", "",
         "sqlprd01.corp.local,1433", "jmp-db-01.corp.local", "3389",
         "Jump Server", "ADM ID", "Yes"),
        ("pgAdmin - PostgreSQL Estate", "Database", "Prod",
         "https://pgadmin.corp.local", "pgadmin01.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("MySQL Production Cluster", "Database", "Prod", "",
         "mysqlprd01.corp.local:3306", "jmp-db-02.corp.local", "22",
         "Jump Server", "ADM ID", "No"),
        ("MongoDB Ops Manager", "Database", "Prod",
         "https://mongo-ops.corp.local:8080", "mongo-ops01.corp.local", "",
         "", "Laptop", "UID", "Yes"),
        ("IBM Db2 Data Server Manager", "Database", "Prod",
         "https://db2dsm.corp.local:11081", "db2dsm01.corp.local",
         "jmp-db-02.corp.local", "22", "Both", "ADM ID", "No"),
        ("Redis Enterprise Cluster Manager", "Database", "Prod",
         "https://redis-cm.corp.local:8443", "redis-cm01.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("SQL Server - UAT Instance", "Database", "UAT", "",
         "sqluat01.corp.local,1433", "jmp-db-uat01.corp.local", "3389",
         "Jump Server", "UID", "No"),
        ("Oracle RAC SCAN - DR Site", "Database", "DR", "",
         "rac-dr-scan.dr.corp.local:1521", "jmp-db-dr01.dr.corp.local", "22",
         "Jump Server", "ADM ID", "Yes"),
    ],
    "storage": [
        ("NetApp ONTAP System Manager", "Storage", "Prod",
         "https://ontap-cl1.corp.local", "ontap-cl1.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("Dell EMC Unisphere for PowerMax", "Storage", "Prod",
         "https://unisphere.corp.local:8443/univmax", "unisphere01.corp.local",
         "", "", "Laptop", "UID", "Yes"),
        ("Broadcom SANnav Fabric Manager", "Networking", "Prod",
         "https://sannav.corp.local", "sannav01.corp.local", "", "", "Laptop",
         "UID", "Yes"),
        ("Veritas NetBackup Web UI", "Backup", "Prod",
         "https://nbumaster01.corp.local/webui", "nbumaster01.corp.local", "",
         "", "Laptop", "UID", "Yes"),
        ("Commvault Command Center", "Backup", "Prod",
         "https://commvault.corp.local/commandcenter", "cvcs01.corp.local",
         "", "", "Laptop", "UID", "Yes"),
        ("IBM Storage Protect Operations Center", "Backup", "Prod",
         "https://tsm-oc.corp.local:11090/oc", "tsmsrv01.corp.local",
         "jmp-stg-01.corp.local", "22", "Both", "ADM ID", "No"),
        ("Quantum Scalar Tape Library", "Storage", "Prod",
         "https://tapelib01.corp.local", "tapelib01.corp.local",
         "jmp-stg-01.corp.local", "22", "Jump Server", "ADM ID", "No"),
        ("Rubrik CDM Cluster", "Backup", "Prod", "https://rubrik.corp.local",
         "rubrik01.corp.local", "", "", "Laptop", "UID", "Yes"),
        ("NetApp ONTAP - UAT Cluster", "Storage", "UAT",
         "https://ontap-uat.corp.local", "ontap-uat.corp.local", "", "",
         "Laptop", "UID", "No"),
        ("NetBackup Master - DR Domain", "Backup", "DR",
         "https://nbumaster-dr01.dr.corp.local/webui",
         "nbumaster-dr01.dr.corp.local", "jmp-stg-dr01.dr.corp.local", "22",
         "Both", "ADM ID", "Yes"),
    ],
    "controlm": [
        ("Control-M Web (Enterprise Manager)", "Scheduler", "Prod",
         "https://ctm-em01.corp.local:8443/ControlM", "ctm-em01.corp.local",
         "", "", "Laptop", "UID", "Yes"),
        ("Control-M Configuration Manager (CCM)", "Scheduler", "Prod",
         "https://ctm-em01.corp.local:8443/ControlM/ccm",
         "ctm-em01.corp.local", "", "", "Laptop", "UID", "Yes"),
        ("Control-M/Server - Primary", "Scheduler", "Prod", "",
         "ctm-srv01.corp.local", "jmp-ctm-01.corp.local", "22", "Jump Server",
         "ADM ID", "No"),
        ("Control-M/Agent Gateway Host", "Scheduler", "Prod", "",
         "ctm-agt-gw01.corp.local", "jmp-ctm-01.corp.local", "22",
         "Jump Server", "ADM ID", "No"),
        ("Control-M Managed File Transfer", "Automation", "Prod",
         "https://ctm-mft01.corp.local:8443/mft", "ctm-mft01.corp.local", "",
         "", "Laptop", "UID", "Yes"),
        ("Control-M Application Integrator", "Automation", "Prod",
         "https://ctm-em01.corp.local:8443/ai", "ctm-em01.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("Control-M Automation API (ctm CLI)", "Automation", "Prod",
         "https://ctm-em01.corp.local:8443/automation-api",
         "ctm-em01.corp.local", "jmp-ctm-01.corp.local", "22", "Jump Server",
         "Service Account", "No"),
        ("Control-M BIM / Reporting Facility", "Monitoring", "Prod",
         "https://ctm-bim01.corp.local:8443/reports", "ctm-bim01.corp.local",
         "", "", "Laptop", "UID", "No"),
        ("Control-M EM - UAT", "Scheduler", "UAT",
         "https://ctm-em-uat01.corp.local:8443/ControlM",
         "ctm-em-uat01.corp.local", "", "", "Laptop", "UID", "No"),
        ("Control-M/Server - DR Site", "Scheduler", "DR", "",
         "ctm-srv-dr01.dr.corp.local", "jmp-ctm-dr01.dr.corp.local", "22",
         "Jump Server", "ADM ID", "Yes"),
    ],
    "cloudops": [
        ("AWS Console (IAM Identity Center)", "Cloud", "Prod",
         "https://corp.awsapps.com/start", "corp.awsapps.com", "", "",
         "Laptop", "UID", "Yes"),
        ("Azure Portal", "Cloud", "Prod", "https://portal.azure.com",
         "portal.azure.com", "", "", "Laptop", "UID", "Yes"),
        ("OpenShift Container Platform Console", "Cloud", "Prod",
         "https://console-openshift-console.apps.ocp.corp.local",
         "api.ocp.corp.local:6443", "", "", "Laptop", "UID", "Yes"),
        ("HashiCorp Vault", "Security", "Prod",
         "https://vault.corp.local:8200/ui", "vault.corp.local", "", "",
         "Laptop", "UID", "Yes"),
        ("Terraform Enterprise", "Automation", "Prod",
         "https://tfe.corp.local", "tfe01.corp.local", "", "", "Laptop",
         "UID", "Yes"),
        ("GitLab CI/CD", "Automation", "Prod", "https://gitlab.corp.local",
         "gitlab01.corp.local", "", "", "Laptop", "UID", "Yes"),
        ("Grafana Observability Stack", "Monitoring", "Prod",
         "https://grafana.corp.local", "grafana01.corp.local", "", "",
         "Laptop", "UID", "No"),
        ("AWS Landing Zone Bastion (SSM)", "Cloud", "Prod", "",
         "bastion-aws-01.eu-west-1.corp.local", "bastion-aws-01.corp.local",
         "22", "Jump Server", "ADM ID", "Yes"),
        ("OpenShift Console - UAT", "Cloud", "UAT",
         "https://console-openshift-console.apps.ocp-uat.corp.local",
         "api.ocp-uat.corp.local:6443", "", "", "Laptop", "UID", "No"),
        ("Azure DR Subscription (Secondary Region)", "Cloud", "DR",
         "https://portal.azure.com", "portal.azure.com", "", "", "Laptop",
         "ADM ID", "Yes"),
    ],
}

USERS_SEED = [
    ("superadmin", "Super User - All Teams", "super", None),
    ("win_admin", "Windows Team Editor", "team", "windows"),
    ("lnx_admin", "Linux Team Editor", "team", "linux"),
    ("mw_admin", "Middleware Team Editor", "team", "middleware"),
    ("db_admin", "Database Team Editor", "team", "database"),
    ("stg_admin", "Storage & Backup Team Editor", "team", "storage"),
    ("ctm_admin", "Control-M Team Editor", "team", "controlm"),
    ("cloud_admin", "CloudOps Team Editor", "team", "cloudops"),
]


def cmd_init():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = db()
    conn.executescript(SCHEMA)
    conn.commit()

    for slug, name, icon, color, description, order in TEAMS_SEED:
        conn.execute(
            "INSERT INTO teams (slug,name,icon,color,description,sort_order)"
            " VALUES (?,?,?,?,?,?) ON CONFLICT(slug) DO UPDATE SET"
            " name=excluded.name, icon=excluded.icon, color=excluded.color,"
            " description=excluded.description, sort_order=excluded.sort_order",
            (slug, name, icon, color, description, order))
    conn.commit()
    team_ids = {t["slug"]: t["id"] for t in rows("SELECT id,slug FROM teams")}

    for slug, entries in ENTRIES_SEED.items():
        team_id = team_ids[slug]
        existing = conn.execute("SELECT COUNT(*) FROM entries WHERE team_id=?",
                                (team_id,)).fetchone()[0]
        if existing:
            LOG.info("team %s already has %d entries - skipping seed",
                     slug, existing)
            continue
        for order, item in enumerate(entries, start=1):
            conn.execute(
                "INSERT INTO entries (team_id,tool_name,category,environment,"
                "url,host,jump_server,jump_port,access_from,access_id,mfa,"
                "sort_order,updated_at,updated_by)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (team_id,) + item + (order, now_iso(), "seed"))
    conn.commit()

    created = []
    for username, display, role, team_slug in USERS_SEED:
        if row("SELECT id FROM users WHERE username=?", (username,)):
            continue
        password = gen_password()
        salt, digest, iterations = hash_password(password)
        conn.execute(
            "INSERT INTO users (username,display_name,role,team_id,salt,"
            "pw_hash,iterations,active,must_change_pw,created_at)"
            " VALUES (?,?,?,?,?,?,?,1,1,?)",
            (username, display, role,
             team_ids.get(team_slug) if team_slug else None,
             salt, digest, iterations, now_iso()))
        created.append((username, password, role, team_slug or "ALL"))
    conn.commit()

    for username, password, role, scope in created:
        print("CRED\t%s\t%s\t%s\t%s" % (username, password, role, scope))
    LOG.info("initialisation complete: %d team(s), %d entry(ies), %d new user(s)",
             len(team_ids),
             conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0],
             len(created))


def cmd_listusers():
    data = rows("SELECT u.username,u.role,u.active,u.must_change_pw,"
                "u.last_login,COALESCE(t.name,'ALL TEAMS') AS team"
                " FROM users u LEFT JOIN teams t ON t.id=u.team_id"
                " ORDER BY u.role DESC, u.username")
    print("%-14s %-7s %-22s %-7s %-7s %s"
          % ("USERNAME", "ROLE", "SCOPE", "ACTIVE", "PWCHG", "LAST LOGIN"))
    for u in data:
        print("%-14s %-7s %-22s %-7s %-7s %s"
              % (u["username"], u["role"], u["team"],
                 "yes" if u["active"] else "no",
                 "due" if u["must_change_pw"] else "done",
                 u["last_login"] or "never"))


def set_password(username, password, force_change=False):
    user = row("SELECT id FROM users WHERE username=?", (username,))
    if not user:
        print("No such user: %s" % username, file=sys.stderr)
        return 1
    if len(password) < MIN_PW_LEN:
        print("Password must be at least %d characters" % MIN_PW_LEN,
              file=sys.stderr)
        return 1
    salt, digest, iterations = hash_password(password)
    conn = db()
    conn.execute("UPDATE users SET salt=?,pw_hash=?,iterations=?,"
                 "must_change_pw=? WHERE id=?",
                 (salt, digest, iterations, 1 if force_change else 0,
                  user["id"]))
    conn.execute("DELETE FROM sessions WHERE user_id=?", (user["id"],))
    conn.commit()
    return 0


def cmd_adduser(username, scope):
    if row("SELECT id FROM users WHERE username=?", (username,)):
        print("User already exists: %s" % username, file=sys.stderr)
        return 1
    if scope == "super":
        role, team_id = "super", None
    else:
        team = row("SELECT id FROM teams WHERE slug=?", (scope,))
        if not team:
            print("Unknown team slug: %s" % scope, file=sys.stderr)
            return 1
        role, team_id = "team", team["id"]
    password = gen_password()
    salt, digest, iterations = hash_password(password)
    conn = db()
    conn.execute(
        "INSERT INTO users (username,display_name,role,team_id,salt,pw_hash,"
        "iterations,active,must_change_pw,created_at)"
        " VALUES (?,?,?,?,?,?,?,1,1,?)",
        (username, username, role, team_id, salt, digest, iterations,
         now_iso()))
    conn.commit()
    print("Created %s (%s / %s) with password: %s" % (username, role, scope,
                                                      password))
    return 0


def cmd_backup(dest_dir, keep=14):
    """Consistent online copy of the database using SQLite's backup API."""
    os.makedirs(dest_dir, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = os.path.join(dest_dir, "portal-%s.db" % stamp)
    dest = sqlite3.connect(target)
    try:
        with dest:
            db().backup(dest)
    finally:
        dest.close()
    os.chmod(target, 0o640)
    old = sorted(f for f in os.listdir(dest_dir)
                 if f.startswith("portal-") and f.endswith(".db"))
    for name in old[:-keep] if len(old) > keep else []:
        os.remove(os.path.join(dest_dir, name))
    print(target)
    return 0


def serve():
    if not os.path.exists(DB_PATH):
        LOG.error("database %s is missing - run 'app.py init' first", DB_PATH)
        return 1
    threading.Thread(target=janitor, daemon=True).start()
    httpd = make_server(BIND_HOST, BIND_PORT, application,
                        server_class=ThreadingWSGIServer,
                        handler_class=QuietHandler)
    LOG.info("InfraPortal listening on http://%s:%d (db=%s, web=%s)",
             BIND_HOST, BIND_PORT, DB_PATH, WEB_DIR)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutting down")
    finally:
        httpd.server_close()
    return 0


def main(argv):
    command = argv[1] if len(argv) > 1 else "serve"
    if command == "init":
        cmd_init()
        return 0
    if command == "listusers":
        cmd_listusers()
        return 0
    if command == "passwd":
        if len(argv) != 4:
            print("usage: app.py passwd <username> <password>", file=sys.stderr)
            return 2
        code = set_password(argv[2], argv[3])
        if code == 0:
            print("Password updated for %s" % argv[2])
        return code
    if command == "resetpw":
        if len(argv) != 3:
            print("usage: app.py resetpw <username>", file=sys.stderr)
            return 2
        password = gen_password()
        code = set_password(argv[2], password, force_change=True)
        if code == 0:
            print("New password for %s: %s" % (argv[2], password))
        return code
    if command == "adduser":
        if len(argv) != 4:
            print("usage: app.py adduser <username> <team-slug|super>",
                  file=sys.stderr)
            return 2
        return cmd_adduser(argv[2], argv[3])
    if command == "backup":
        return cmd_backup(argv[2] if len(argv) > 2
                          else "/var/lib/infraportal/backups")
    if command in ("serve", "run"):
        return serve()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/index.html" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>InfraPortal &mdash; Infrastructure Access Directory</title>
<link rel="icon" href="/static/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>

<header class="topbar">
  <a class="brand" href="/" data-nav="/">
    <span class="brand-mark">IP</span>
    <span>
      <span class="brand-name">InfraPortal</span>
      <span class="brand-sub">Infrastructure Access Directory</span>
    </span>
  </a>

  <div class="searchwrap">
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" stroke-width="2.2" stroke-linecap="round">
      <circle cx="11" cy="11" r="7"></circle><path d="M20 20l-3.5-3.5"></path>
    </svg>
    <input id="globalSearch" type="text" autocomplete="off" spellcheck="false"
           placeholder="Search every team - tool, IP, FQDN, jump server..."
           aria-label="Search all teams">
    <kbd>/</kbd>
  </div>

  <div class="topactions">
    <button class="btn btn-icon" id="themeToggle" type="button"
            title="Toggle light / dark theme" aria-label="Toggle theme">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none"
           stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"></path>
      </svg>
    </button>
    <span id="authArea"></span>
  </div>
</header>

<nav class="teamnav" aria-label="Teams">
  <div class="teamchips" id="teamChips"></div>
  <div class="selectwrap">
    <label class="sr-only" for="teamSelect" hidden>Jump to team</label>
    <select id="teamSelect" aria-label="Jump to team"></select>
  </div>
</nav>

<main id="main"><div class="empty">Loading the directory&hellip;</div></main>

<div id="toasts" aria-live="polite"></div>
<div id="modalRoot"></div>

<script src="/static/app.js"></script>
</body>
</html>
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/login.html" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Sign in &mdash; InfraPortal</title>
<link rel="icon" href="/static/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/static/style.css">
<script src="/static/theme.js"></script>
</head>
<body>
<div class="authpage">
  <div class="authcard">
    <div class="brand">
      <span class="brand-mark">IP</span>
      <span>
        <span class="brand-name">InfraPortal</span>
        <span class="brand-sub">Infrastructure Access Directory</span>
      </span>
    </div>

    <h1>Sign in to edit</h1>
    <p class="lede">Browsing the directory needs no account. Sign in with your
      team editor ID to add or change entries.</p>

    <div class="formerr">{{ERROR}}</div>
    <div class="banner banner-info">{{NOTICE}}</div>

    <form method="post" action="/login" autocomplete="off">
      <input type="hidden" name="csrf" value="{{CSRF}}">
      <input type="hidden" name="next" value="{{NEXT}}">

      <div class="field">
        <label for="username">Team editor ID</label>
        <input type="text" id="username" name="username" required autofocus
               autocapitalize="off" autocorrect="off" spellcheck="false">
      </div>

      <div class="field">
        <label for="password">Password</label>
        <input type="password" id="password" name="password" required>
      </div>

      <button class="btn btn-primary" type="submit">Sign in</button>
    </form>

    <div class="authback"><a href="/">&larr; Back to the directory</a></div>
  </div>
</div>
</body>
</html>
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/account.html" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>My account &mdash; InfraPortal</title>
<link rel="icon" href="/static/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/static/style.css">
<script src="/static/theme.js"></script>
</head>
<body>
<div class="authpage">
  <div class="authcard">
    <div class="brand">
      <span class="brand-mark">IP</span>
      <span>
        <span class="brand-name">InfraPortal</span>
        <span class="brand-sub">Account settings</span>
      </span>
    </div>

    <h1>Change password</h1>
    <p class="lede">Passwords are stored as PBKDF2-SHA256 hashes. Changing it
      signs out every other session for this account.</p>

    <div class="formerr">{{ERROR}}</div>
    <div class="banner banner-info">{{NOTICE}}</div>

    <div style="margin-bottom:20px">
      <div class="metarow"><span>Signed in as</span><b>{{USERNAME}}</b></div>
      <div class="metarow"><span>Role</span><b>{{ROLE}}</b></div>
      <div class="metarow"><span>Edit scope</span><b>{{TEAM}}</b></div>
    </div>

    <form method="post" action="/account/password" autocomplete="off">
      <input type="hidden" name="csrf" value="{{CSRF}}">

      <div class="field">
        <label for="current">Current password</label>
        <input type="password" id="current" name="current" required autofocus>
      </div>

      <div class="field">
        <label for="new">New password</label>
        <input type="password" id="new" name="new" required
               minlength="{{MINLEN}}">
        <span class="hint">At least {{MINLEN}} characters.</span>
      </div>

      <div class="field">
        <label for="confirm">Confirm new password</label>
        <input type="password" id="confirm" name="confirm" required
               minlength="{{MINLEN}}">
      </div>

      <button class="btn btn-primary" type="submit">Update password</button>
    </form>

    <div class="authback">
      <a href="/">&larr; Back to the directory</a>
      &nbsp;&middot;&nbsp;
      <form method="post" action="/logout" style="display:inline">
        <button class="btn btn-sm" type="submit">Sign out</button>
      </form>
    </div>
  </div>
</div>
</body>
</html>
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/style.css" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
/* ------------------------------------------------------------------
   InfraPortal - stylesheet
   Light palette on :root, dark overrides for both the explicit toggle
   and the system preference.
   ------------------------------------------------------------------ */
:root {
  --bg: #f4f6fb;
  --bg-elev: #ffffff;
  --bg-sunk: #eef1f8;
  --line: #dfe3ec;
  --line-soft: #eaedf4;
  --ink: #131722;
  --ink-2: #4a5266;
  --ink-3: #79819a;
  --accent: #4f46e5;
  --accent-ink: #ffffff;
  --accent-soft: #eceafe;
  --ok: #0f8a5f;
  --ok-soft: #e2f5ec;
  --warn: #b45309;
  --warn-soft: #fdf1e0;
  --danger: #c0392b;
  --danger-soft: #fdecea;
  --info: #1d6fd0;
  --info-soft: #e6f0fd;
  --shadow: 0 1px 2px rgba(19, 23, 34, .06), 0 8px 24px rgba(19, 23, 34, .07);
  --shadow-lg: 0 24px 60px rgba(19, 23, 34, .22);
  --radius: 12px;
  --radius-sm: 8px;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas,
          "Liberation Mono", monospace;
  --sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue",
          Arial, sans-serif;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #0d1017;
    --bg-elev: #151a24;
    --bg-sunk: #10141d;
    --line: #262d3b;
    --line-soft: #1d2330;
    --ink: #e8ecf6;
    --ink-2: #a9b2c6;
    --ink-3: #79839b;
    --accent: #8b85ff;
    --accent-ink: #10121a;
    --accent-soft: #221f45;
    --ok: #4ade80;
    --ok-soft: #12291f;
    --warn: #fbbf24;
    --warn-soft: #2c2210;
    --danger: #f87171;
    --danger-soft: #2e1615;
    --info: #60a5fa;
    --info-soft: #12213a;
    --shadow: 0 1px 2px rgba(0, 0, 0, .5), 0 8px 24px rgba(0, 0, 0, .45);
    --shadow-lg: 0 24px 60px rgba(0, 0, 0, .6);
  }
}

:root[data-theme="dark"] {
  --bg: #0d1017;
  --bg-elev: #151a24;
  --bg-sunk: #10141d;
  --line: #262d3b;
  --line-soft: #1d2330;
  --ink: #e8ecf6;
  --ink-2: #a9b2c6;
  --ink-3: #79839b;
  --accent: #8b85ff;
  --accent-ink: #10121a;
  --accent-soft: #221f45;
  --ok: #4ade80;
  --ok-soft: #12291f;
  --warn: #fbbf24;
  --warn-soft: #2c2210;
  --danger: #f87171;
  --danger-soft: #2e1615;
  --info: #60a5fa;
  --info-soft: #12213a;
  --shadow: 0 1px 2px rgba(0, 0, 0, .5), 0 8px 24px rgba(0, 0, 0, .45);
  --shadow-lg: 0 24px 60px rgba(0, 0, 0, .6);
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--sans);
  font-size: 15px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}

a { color: var(--accent); }
h1, h2, h3 { margin: 0; line-height: 1.25; letter-spacing: -.01em; }

.skip {
  position: absolute; left: -9999px; top: 0; z-index: 100;
  background: var(--accent); color: var(--accent-ink);
  padding: 10px 16px; border-radius: 0 0 var(--radius-sm) 0;
}
.skip:focus { left: 0; }

/* ---------------------------------------------------------- top bar */
.topbar {
  position: sticky; top: 0; z-index: 40;
  display: flex; align-items: center; gap: 16px;
  padding: 10px 20px;
  background: color-mix(in srgb, var(--bg-elev) 88%, transparent);
  backdrop-filter: saturate(160%) blur(10px);
  border-bottom: 1px solid var(--line);
}

.brand {
  display: flex; align-items: center; gap: 10px;
  text-decoration: none; color: inherit; flex: 0 0 auto;
}
.brand-mark {
  width: 34px; height: 34px; border-radius: 10px; flex: 0 0 auto;
  background: linear-gradient(135deg, var(--accent), #06b6d4);
  display: grid; place-items: center;
  color: #fff; font-weight: 800; font-size: 15px;
}
.brand-name { font-weight: 700; font-size: 15px; letter-spacing: -.01em; }
.brand-sub { font-size: 11.5px; color: var(--ink-3); margin-top: -2px; }

.searchwrap { position: relative; flex: 1 1 auto; max-width: 560px; }
.searchwrap svg { position: absolute; left: 12px; top: 50%;
  transform: translateY(-50%); color: var(--ink-3); pointer-events: none; }
#globalSearch {
  width: 100%; padding: 9px 46px 9px 36px;
  border: 1px solid var(--line); border-radius: 999px;
  background: var(--bg-sunk); color: var(--ink);
  font: inherit; font-size: 14px; outline: none;
}
#globalSearch:focus {
  border-color: var(--accent); background: var(--bg-elev);
  box-shadow: 0 0 0 4px var(--accent-soft);
}
.searchwrap kbd {
  position: absolute; right: 10px; top: 50%; transform: translateY(-50%);
  font: 600 11px var(--mono); color: var(--ink-3);
  border: 1px solid var(--line); border-radius: 5px; padding: 1px 6px;
  background: var(--bg-elev);
}

.topactions { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }

/* ------------------------------------------------------------ atoms */
.btn {
  display: inline-flex; align-items: center; gap: 7px;
  padding: 8px 13px; border-radius: var(--radius-sm);
  border: 1px solid var(--line); background: var(--bg-elev); color: var(--ink);
  font: inherit; font-size: 13.5px; font-weight: 600;
  cursor: pointer; text-decoration: none; white-space: nowrap;
  transition: background .13s, border-color .13s, transform .06s;
}
.btn:hover { background: var(--bg-sunk); border-color: var(--ink-3); }
.btn:active { transform: translateY(1px); }
.btn-primary {
  background: var(--accent); border-color: var(--accent); color: var(--accent-ink);
}
.btn-primary:hover { background: var(--accent); filter: brightness(1.08); }
.btn-danger { color: var(--danger); border-color: var(--danger); background: transparent; }
.btn-danger:hover { background: var(--danger-soft); }
.btn-icon { padding: 8px; }
.btn-sm { padding: 5px 9px; font-size: 12.5px; }

.badge {
  display: inline-flex; align-items: center; gap: 5px;
  padding: 2px 9px; border-radius: 999px;
  font-size: 11.5px; font-weight: 700; letter-spacing: .02em;
  border: 1px solid transparent; white-space: nowrap;
}
.env-Prod { background: var(--danger-soft); color: var(--danger);
  border-color: color-mix(in srgb, var(--danger) 30%, transparent); }
.env-UAT { background: var(--info-soft); color: var(--info);
  border-color: color-mix(in srgb, var(--info) 30%, transparent); }
.env-DR { background: var(--warn-soft); color: var(--warn);
  border-color: color-mix(in srgb, var(--warn) 30%, transparent); }
.mfa-Yes { background: var(--ok-soft); color: var(--ok);
  border-color: color-mix(in srgb, var(--ok) 30%, transparent); }
.mfa-No { background: var(--bg-sunk); color: var(--ink-3); border-color: var(--line); }
.badge-plain { background: var(--bg-sunk); color: var(--ink-2); border-color: var(--line); }

.mono { font-family: var(--mono); font-size: 13px; }

/* ------------------------------------------------------- team nav */
.teamnav {
  position: sticky; top: 55px; z-index: 30;
  display: flex; align-items: center; gap: 10px;
  padding: 10px 20px;
  background: var(--bg);
  border-bottom: 1px solid var(--line-soft);
}
.teamchips {
  display: flex; gap: 8px; overflow-x: auto; flex: 1 1 auto;
  scrollbar-width: thin; padding-bottom: 2px;
}
.teamchip {
  display: inline-flex; align-items: center; gap: 7px;
  padding: 6px 13px; border-radius: 999px; cursor: pointer;
  border: 1px solid var(--line); background: var(--bg-elev); color: var(--ink-2);
  font: inherit; font-size: 13px; font-weight: 600; white-space: nowrap;
  transition: all .13s;
}
.teamchip:hover { color: var(--ink); border-color: var(--ink-3); }
.teamchip[aria-current="true"] {
  color: #fff; border-color: transparent;
  background: var(--chip, var(--accent));
  box-shadow: 0 2px 10px color-mix(in srgb, var(--chip, var(--accent)) 40%, transparent);
}
.teamchip .dot {
  width: 8px; height: 8px; border-radius: 50%; background: var(--chip, var(--accent));
}
.teamchip[aria-current="true"] .dot { background: rgba(255,255,255,.9); }

.selectwrap { flex: 0 0 auto; }
select, input[type=text], input[type=password], input[type=url], textarea {
  font: inherit; font-size: 13.5px; color: var(--ink);
  background: var(--bg-elev); border: 1px solid var(--line);
  border-radius: var(--radius-sm); padding: 7px 10px; outline: none;
}
select:focus, input:focus, textarea:focus {
  border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft);
}

/* ---------------------------------------------------------- layout */
main { max-width: 1400px; margin: 0 auto; padding: 24px 20px 80px; }
.section { margin-bottom: 34px; }
.section-head {
  display: flex; align-items: baseline; gap: 12px; margin-bottom: 14px;
  flex-wrap: wrap;
}
.section-head h2 { font-size: 15px; text-transform: uppercase;
  letter-spacing: .08em; color: var(--ink-3); }
.section-head .rule { flex: 1 1 auto; height: 1px; background: var(--line); }

.hero {
  background: var(--bg-elev); border: 1px solid var(--line);
  border-radius: 16px; padding: 26px; margin-bottom: 30px;
  box-shadow: var(--shadow); position: relative; overflow: hidden;
}
.hero::after {
  content: ""; position: absolute; inset: 0 0 auto auto;
  width: 340px; height: 340px; transform: translate(38%, -55%);
  background: radial-gradient(circle, var(--accent-soft), transparent 68%);
  pointer-events: none;
}
.hero h1 { font-size: 26px; margin-bottom: 6px; }
.hero p { margin: 0; color: var(--ink-2); max-width: 70ch; font-size: 14px; }

.statgrid {
  display: grid; gap: 12px; margin-top: 22px;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  position: relative;
}
.stat {
  background: var(--bg-sunk); border: 1px solid var(--line-soft);
  border-radius: var(--radius); padding: 13px 15px;
}
.stat b { display: block; font-size: 25px; letter-spacing: -.02em; }
.stat span { font-size: 12px; color: var(--ink-3); font-weight: 600;
  text-transform: uppercase; letter-spacing: .05em; }

.cardgrid {
  display: grid; gap: 14px;
  grid-template-columns: repeat(auto-fill, minmax(268px, 1fr));
}
.teamcard {
  display: block; text-decoration: none; color: inherit; cursor: pointer;
  background: var(--bg-elev); border: 1px solid var(--line);
  border-radius: var(--radius); padding: 17px; text-align: left;
  font: inherit; position: relative; overflow: hidden;
  transition: transform .14s, box-shadow .14s, border-color .14s;
}
.teamcard::before {
  content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 4px;
  background: var(--chip);
}
.teamcard:hover {
  transform: translateY(-2px); box-shadow: var(--shadow);
  border-color: color-mix(in srgb, var(--chip) 45%, var(--line));
}
.teamcard .tc-top { display: flex; align-items: center; gap: 10px; }
.teamcard .tc-icon {
  width: 34px; height: 34px; border-radius: 9px; display: grid;
  place-items: center; font-size: 17px;
  background: color-mix(in srgb, var(--chip) 16%, transparent);
}
.teamcard h3 { font-size: 15.5px; }
.teamcard p { margin: 9px 0 12px; font-size: 12.5px; color: var(--ink-3);
  min-height: 34px; }
.tc-meta { display: flex; gap: 14px; font-size: 12px; color: var(--ink-2); }
.tc-meta b { color: var(--ink); }

/* --------------------------------------------------------- toolbar */
.teamhead {
  display: flex; align-items: flex-start; gap: 14px; margin-bottom: 18px;
  flex-wrap: wrap;
}
.teamhead .th-icon {
  width: 46px; height: 46px; border-radius: 13px; display: grid;
  place-items: center; font-size: 22px;
  background: color-mix(in srgb, var(--chip) 16%, transparent);
  border: 1px solid color-mix(in srgb, var(--chip) 30%, transparent);
}
.teamhead h1 { font-size: 22px; }
.teamhead p { margin: 3px 0 0; color: var(--ink-3); font-size: 13px; }
.teamhead .spacer { flex: 1 1 auto; }
.headactions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }

.toolbar {
  display: flex; gap: 10px; flex-wrap: wrap; align-items: center;
  padding: 12px; margin-bottom: 14px;
  background: var(--bg-elev); border: 1px solid var(--line);
  border-radius: var(--radius);
}
.toolbar input[type=text] { min-width: 190px; flex: 1 1 190px; }
.toolbar .count { margin-left: auto; font-size: 12.5px; color: var(--ink-3);
  font-weight: 600; }

.banner {
  display: flex; align-items: center; gap: 10px; padding: 11px 14px;
  border-radius: var(--radius); margin-bottom: 14px; font-size: 13.5px;
  border: 1px solid transparent;
}
.banner-info { background: var(--info-soft); color: var(--info);
  border-color: color-mix(in srgb, var(--info) 26%, transparent); }
.banner-ok { background: var(--ok-soft); color: var(--ok);
  border-color: color-mix(in srgb, var(--ok) 26%, transparent); }

/* ----------------------------------------------------------- table */
.tablewrap {
  background: var(--bg-elev); border: 1px solid var(--line);
  border-radius: var(--radius); overflow-x: auto;
}
table.entries { width: 100%; border-collapse: collapse; min-width: 1040px; }
table.entries thead th {
  position: sticky; top: 0; z-index: 5;
  background: var(--bg-sunk); text-align: left; font-size: 11px;
  text-transform: uppercase; letter-spacing: .07em; color: var(--ink-3);
  padding: 10px 12px; border-bottom: 1px solid var(--line); white-space: nowrap;
}
table.entries tbody td {
  padding: 11px 12px; border-bottom: 1px solid var(--line-soft);
  vertical-align: top; font-size: 13.5px;
}
table.entries tbody tr:last-child td { border-bottom: none; }
table.entries tbody tr:hover { background: var(--bg-sunk); }
.col-fav { width: 34px; }
.col-act { width: 1%; white-space: nowrap; }

.toolcell { min-width: 210px; }
.toolcell .name { font-weight: 650; display: block; }
.toolcell .sub { display: flex; align-items: center; gap: 6px; margin-top: 4px;
  flex-wrap: wrap; }
.toolcell a.url {
  display: inline-flex; align-items: center; gap: 4px; font-size: 12px;
  overflow-wrap: anywhere; text-decoration: none;
}
.toolcell a.url:hover { text-decoration: underline; }

.copyfield { display: flex; align-items: center; gap: 6px; }
/* Hosts stay on one line - the table scrolls rather than breaking a FQDN up */
.copyfield .val { font-family: var(--mono); font-size: 12.5px;
  white-space: nowrap; }
.copybtn {
  display: inline-grid; place-items: center; flex: 0 0 auto;
  width: 25px; height: 25px; padding: 0; border-radius: 6px;
  border: 1px solid var(--line); background: var(--bg-sunk);
  color: var(--ink-3); cursor: pointer; transition: all .12s;
}
.copybtn:hover { color: var(--accent); border-color: var(--accent);
  background: var(--accent-soft); }
.copybtn.done { color: var(--ok); border-color: var(--ok);
  background: var(--ok-soft); }
.copybtn svg { width: 13px; height: 13px; }

.favbtn {
  background: none; border: none; cursor: pointer; padding: 2px;
  color: var(--ink-3); line-height: 0;
}
.favbtn:hover { color: var(--warn); }
.favbtn[aria-pressed="true"] { color: var(--warn); }
.favbtn svg { width: 17px; height: 17px; }

.empty { padding: 46px 20px; text-align: center; color: var(--ink-3); }
.empty b { display: block; color: var(--ink); font-size: 15px;
  margin-bottom: 5px; }

/* Search results */
.resultgroup { margin-bottom: 22px; }
.resultgroup h3 {
  font-size: 12px; text-transform: uppercase; letter-spacing: .07em;
  color: var(--ink-3); margin-bottom: 8px;
  display: flex; align-items: center; gap: 8px;
}
mark { background: color-mix(in srgb, var(--warn) 35%, transparent);
  color: inherit; border-radius: 3px; padding: 0 2px; }

/* ----------------------------------------------------------- modal */
.modal-backdrop {
  position: fixed; inset: 0; z-index: 60; display: grid; place-items: center;
  background: rgba(9, 12, 20, .55); padding: 20px;
  backdrop-filter: blur(3px);
}
.modal {
  background: var(--bg-elev); border: 1px solid var(--line);
  border-radius: 16px; box-shadow: var(--shadow-lg);
  width: min(720px, 100%); max-height: 88vh; overflow-y: auto;
}
.modal-head {
  display: flex; align-items: center; gap: 12px; padding: 18px 20px;
  border-bottom: 1px solid var(--line); position: sticky; top: 0;
  background: var(--bg-elev); z-index: 2;
}
.modal-head h2 { font-size: 16px; flex: 1 1 auto; }
.modal-body { padding: 20px; }
.modal-foot {
  display: flex; gap: 10px; justify-content: flex-end; padding: 16px 20px;
  border-top: 1px solid var(--line); position: sticky; bottom: 0;
  background: var(--bg-elev);
}
.formgrid { display: grid; gap: 14px; grid-template-columns: 1fr 1fr; }
.formgrid .full { grid-column: 1 / -1; }
.field { display: flex; flex-direction: column; gap: 5px; }
.field label { font-size: 12px; font-weight: 700; color: var(--ink-2);
  text-transform: uppercase; letter-spacing: .04em; }
.field .hint { font-size: 11.5px; color: var(--ink-3); }
.field input, .field select, .field textarea { width: 100%; }
.formerr {
  background: var(--danger-soft); color: var(--danger); padding: 10px 12px;
  border-radius: var(--radius-sm); font-size: 13px; margin-bottom: 14px;
  border: 1px solid color-mix(in srgb, var(--danger) 30%, transparent);
}
.formerr:empty, .banner:empty { display: none; }

.auditlist { display: flex; flex-direction: column; gap: 2px; }
.auditrow {
  display: grid; grid-template-columns: 150px 84px 1fr; gap: 12px;
  padding: 9px 10px; border-radius: var(--radius-sm); font-size: 12.5px;
  border-bottom: 1px solid var(--line-soft);
}
.auditrow:hover { background: var(--bg-sunk); }
.auditrow time { color: var(--ink-3); font-family: var(--mono); font-size: 11.5px; }
.auditrow .who { font-weight: 700; }
.act-create { color: var(--ok); }
.act-update { color: var(--info); }
.act-delete { color: var(--danger); }
.act-import { color: var(--warn); }

/* ---------------------------------------------------------- toasts */
#toasts {
  position: fixed; right: 18px; bottom: 18px; z-index: 80;
  display: flex; flex-direction: column; gap: 9px; align-items: flex-end;
}
.toast {
  display: flex; align-items: center; gap: 9px;
  background: var(--bg-elev); color: var(--ink);
  border: 1px solid var(--line); border-left: 3px solid var(--ok);
  border-radius: var(--radius-sm); padding: 10px 15px;
  box-shadow: var(--shadow); font-size: 13.5px; font-weight: 600;
  animation: toast-in .18s ease-out;
}
.toast.err { border-left-color: var(--danger); }
@keyframes toast-in {
  from { opacity: 0; transform: translateY(8px); }
  to { opacity: 1; transform: none; }
}

/* ------------------------------------------------------- auth pages */
.authpage {
  min-height: 100vh; display: grid; place-items: center; padding: 24px;
}
.authcard {
  width: min(430px, 100%); background: var(--bg-elev);
  border: 1px solid var(--line); border-radius: 16px; padding: 30px;
  box-shadow: var(--shadow);
}
.authcard .brand { justify-content: center; margin-bottom: 20px; }
.authcard h1 { font-size: 19px; text-align: center; margin-bottom: 5px; }
.authcard .lede { text-align: center; color: var(--ink-3); font-size: 13px;
  margin: 0 0 22px; }
.authcard .field { margin-bottom: 15px; }
.authcard .btn { width: 100%; justify-content: center; padding: 10px; }
.authback { text-align: center; margin-top: 18px; font-size: 13px; }
.metarow {
  display: flex; justify-content: space-between; gap: 10px;
  padding: 8px 0; border-bottom: 1px solid var(--line-soft); font-size: 13px;
}
.metarow span { color: var(--ink-3); }
.metarow b { font-weight: 650; }

/* ------------------------------------------------------ responsive */
@media (max-width: 900px) {
  .brand-sub, .searchwrap kbd { display: none; }
  .topbar { gap: 10px; padding: 9px 12px; }
  .teamnav { top: 53px; padding: 9px 12px; }
  main { padding: 18px 12px 70px; }
  .formgrid { grid-template-columns: 1fr; }
  .auditrow { grid-template-columns: 1fr; gap: 2px; }

  /* Table collapses into stacked cards */
  table.entries { min-width: 0; display: block; }
  table.entries thead { display: none; }
  table.entries tbody, table.entries tr, table.entries td { display: block; }
  table.entries tbody tr {
    border-bottom: 1px solid var(--line);
    padding: 12px 6px; position: relative;
  }
  table.entries tbody td { border: none; padding: 4px 10px;
    display: grid; grid-template-columns: 108px 1fr; gap: 10px;
    align-items: start; }
  table.entries tbody td::before {
    content: attr(data-label); font-size: 10.5px; font-weight: 700;
    text-transform: uppercase; letter-spacing: .05em; color: var(--ink-3);
    padding-top: 2px;
  }
  table.entries tbody td.col-fav { position: absolute; right: 8px; top: 10px;
    display: block; padding: 0; }
  table.entries tbody td.col-fav::before { content: none; }
  /* In card mode there is no horizontal scroll, so long hosts may wrap */
  .copyfield .val { white-space: normal; overflow-wrap: anywhere; }
}

/* Phones: the search gets its own row so the action cluster always fits */
@media (max-width: 620px) {
  .topbar { flex-wrap: wrap; row-gap: 9px; }
  .brand { flex: 1 1 auto; }
  .searchwrap { order: 3; flex: 1 1 100%; max-width: none; }
  .teamnav { position: static; }
  .role-sfx { display: none; }
  .topactions .btn { padding: 7px 10px; }
  .teamhead .headactions { width: 100%; }
  .toolbar .count { margin-left: 0; }
}

@media print {
  .topbar, .teamnav, .toolbar, .headactions, #toasts, .col-act, .col-fav,
  .copybtn { display: none !important; }
  body { background: #fff; }
  .tablewrap { border: none; }
  table.entries { min-width: 0; }
}
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/app.js" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
/* ------------------------------------------------------------------
   InfraPortal front end - vanilla ES2018, no build step, no dependencies.
   ------------------------------------------------------------------ */
(function () {
  'use strict';

  var S = {
    teams: [], byId: {}, bySlug: {}, vocab: {}, user: null,
    entries: [], route: { view: 'home', slug: null }, query: '',
    filters: { text: '', env: '', cat: '', from: '', sort: 'default' }
  };

  var LS_FAVS = 'infraportal.favourites';
  var LS_RECENT = 'infraportal.recent';
  var LS_THEME = 'infraportal.theme';

  /* ------------------------------------------------------------ util */
  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function $(sel, root) { return (root || document).querySelector(sel); }
  function store(key, fallback) {
    try { return JSON.parse(localStorage.getItem(key)) || fallback; }
    catch (e) { return fallback; }
  }
  function save(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {}
  }
  function safeHref(url) { return /^https?:\/\//i.test(url || '') ? url : ''; }

  var ICON = {
    copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>',
    tick: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"></path></svg>',
    star: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 3l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5-5.8-3-5.8 3 1.1-6.5L2.6 9.8l6.5-.9z"></path></svg>',
    starOn: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 3l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5-5.8-3-5.8 3 1.1-6.5L2.6 9.8l6.5-.9z"></path></svg>',
    ext: '<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"></path></svg>',
    term: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6l5 5-5 5M12 18h8"></path></svg>'
  };

  /* --------------------------------------------------------- network */
  function api(path, options) {
    options = options || {};
    options.headers = options.headers || {};
    options.credentials = 'same-origin';
    if (options.body) options.headers['Content-Type'] = 'application/json';
    if (S.user && S.user.csrf) options.headers['X-CSRF-Token'] = S.user.csrf;
    return fetch(path, options).then(function (res) {
      var ctype = res.headers.get('content-type') || '';
      if (ctype.indexOf('application/json') === -1) {
        if (!res.ok) throw new Error('Request failed (' + res.status + ')');
        return {};
      }
      return res.json().then(function (data) {
        if (!res.ok) throw new Error(data.error || 'Request failed');
        return data;
      });
    });
  }

  /* ---------------------------------------------------------- toasts */
  function toast(message, isError) {
    var host = $('#toasts');
    var node = document.createElement('div');
    node.className = 'toast' + (isError ? ' err' : '');
    node.innerHTML = (isError ? '' : '<span style="color:var(--ok)">' +
      ICON.tick.replace('<svg', '<svg width="14" height="14"') + '</span>') +
      '<span>' + esc(message) + '</span>';
    host.appendChild(node);
    setTimeout(function () { node.remove(); }, isError ? 5200 : 2400);
  }

  /* -------------------------------------------------------- clipboard */
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand('copy') ? resolve() : reject(new Error('denied'));
      } catch (e) { reject(e); }
      ta.remove();
    });
  }

  function rememberCopy(label, value) {
    var list = store(LS_RECENT, []).filter(function (r) {
      return r.value !== value;
    });
    list.unshift({ label: label, value: value, ts: Date.now() });
    save(LS_RECENT, list.slice(0, 8));
  }

  function handleCopy(button) {
    var value = button.getAttribute('data-value');
    var label = button.getAttribute('data-label') || 'Value';
    copyText(value).then(function () {
      button.classList.add('done');
      var iconOnly = button.classList.contains('copybtn');
      var original = button.innerHTML;
      if (iconOnly) button.innerHTML = ICON.tick;
      setTimeout(function () {
        button.classList.remove('done');
        if (iconOnly) button.innerHTML = original;
      }, 1100);
      rememberCopy(label, value);
      toast(label + ' copied');
    }).catch(function () {
      toast('Could not copy - select the text manually', true);
    });
  }

  /* ------------------------------------------------------- favourites */
  function favs() { return store(LS_FAVS, []); }
  function isFav(id) { return favs().indexOf(id) !== -1; }
  function toggleFav(id) {
    var list = favs();
    var index = list.indexOf(id);
    if (index === -1) list.push(id); else list.splice(index, 1);
    save(LS_FAVS, list);
    return index === -1;
  }

  /* ------------------------------------------------------------ theme */
  function applyTheme(mode) {
    if (mode) document.documentElement.setAttribute('data-theme', mode);
    else document.documentElement.removeAttribute('data-theme');
  }
  function initTheme() { applyTheme(store(LS_THEME, null)); }
  function cycleTheme() {
    var current = store(LS_THEME, null);
    var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    var next = current ? (current === 'dark' ? 'light' : 'dark')
                       : (dark ? 'light' : 'dark');
    save(LS_THEME, next);
    applyTheme(next);
    toast(next === 'dark' ? 'Dark theme' : 'Light theme');
  }

  /* ----------------------------------------------------------- router */
  function parseRoute() {
    var match = /^\/t\/([A-Za-z0-9_-]+)$/.exec(location.pathname);
    S.route = match ? { view: 'team', slug: match[1] } : { view: 'home', slug: null };
  }
  function go(path, replace) {
    if (location.pathname !== path) {
      history[replace ? 'replaceState' : 'pushState']({}, '', path);
    }
    parseRoute();
    S.query = '';
    $('#globalSearch').value = '';
    S.filters = { text: '', env: '', cat: '', from: '', sort: 'default' };
    render();
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  /* ------------------------------------------------------- components */
  function copyBtn(value, label) {
    if (!value) return '';
    return '<button class="copybtn" data-act="copy" data-value="' + esc(value) +
      '" data-label="' + esc(label) + '" title="Copy ' + esc(label) +
      '" aria-label="Copy ' + esc(label) + '">' + ICON.copy + '</button>';
  }

  function copyField(value, label, extra) {
    if (!value) return '<span style="color:var(--ink-3)">&mdash;</span>';
    return '<div class="copyfield"><span class="val">' + hl(value) + '</span>' +
      copyBtn(value, label) + (extra || '') + '</div>';
  }

  function connectCommand(entry) {
    var host = entry.jump_server;
    if (!host) return null;
    var port = entry.jump_port || '';
    if (port === '3389') return { cmd: 'mstsc /v:' + host, label: 'RDP command' };
    if (port && port !== '22') return { cmd: 'ssh -p ' + port + ' ' + host, label: 'SSH command' };
    return { cmd: 'ssh ' + host, label: 'SSH command' };
  }

  function hl(text) {
    var safe = esc(text);
    if (!S.query || S.query.length < 2) return safe;
    var needle = S.query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return safe.replace(new RegExp('(' + needle + ')', 'ig'), '<mark>$1</mark>');
  }

  function canEdit(teamId) {
    return !!(S.user && S.user.editable.indexOf(teamId) !== -1);
  }

  function entryRow(entry, showTeam) {
    var team = S.byId[entry.team_id] || {};
    var editable = canEdit(entry.team_id);
    var link = safeHref(entry.url);
    var connect = connectCommand(entry);
    var summary = [
      entry.tool_name,
      entry.url ? 'URL        : ' + entry.url : null,
      entry.host ? 'IP / FQDN  : ' + entry.host : null,
      entry.jump_server ? 'Jump server: ' + entry.jump_server +
        (entry.jump_port ? ':' + entry.jump_port : '') : null,
      'Access from: ' + entry.access_from,
      'Credential : ' + entry.access_id,
      'MFA        : ' + entry.mfa,
      'Environment: ' + entry.environment
    ].filter(Boolean).join('\n');

    return '<tr>' +
      '<td class="col-fav"><button class="favbtn" data-act="fav" data-id="' +
        entry.id + '" aria-pressed="' + (isFav(entry.id) ? 'true' : 'false') +
        '" title="Pin to home page">' +
        (isFav(entry.id) ? ICON.starOn : ICON.star) + '</button></td>' +

      '<td class="toolcell" data-label="Tool"><span class="name">' +
        hl(entry.tool_name) + '</span><span class="sub">' +
        (showTeam ? '<span class="badge badge-plain">' + esc(team.name || '') +
          '</span>' : '') +
        (entry.category ? '<span class="badge badge-plain">' +
          hl(entry.category) + '</span>' : '') +
        (link ? '<a class="url" href="' + esc(link) + '" target="_blank" ' +
          'rel="noopener noreferrer">' + hl(entry.url) + ICON.ext + '</a>' +
          copyBtn(entry.url, 'URL') : '') +
        '</span></td>' +

      '<td data-label="Env"><span class="badge env-' + esc(entry.environment) +
        '">' + esc(entry.environment) + '</span></td>' +

      '<td data-label="IP / FQDN">' + copyField(entry.host, 'IP / FQDN') + '</td>' +

      '<td data-label="Access from">' + esc(entry.access_from) + '</td>' +

      '<td data-label="Credential"><span class="badge badge-plain">' +
        esc(entry.access_id) + '</span></td>' +

      '<td data-label="MFA"><span class="badge mfa-' + esc(entry.mfa) + '">' +
        esc(entry.mfa) + '</span></td>' +

      '<td data-label="Jump server">' + copyField(
        entry.jump_server + (entry.jump_port ? ':' + entry.jump_port : ''),
        'Jump server',
        connect ? '<button class="copybtn" data-act="copy" data-value="' +
          esc(connect.cmd) + '" data-label="' + esc(connect.label) +
          '" title="Copy: ' + esc(connect.cmd) + '">' + ICON.term + '</button>' : ''
      ) + '</td>' +

      '<td class="col-act" data-label="Actions">' +
        '<button class="btn btn-sm" data-act="copy" data-value="' + esc(summary) +
          '" data-label="Full entry" title="Copy every field">Copy all</button>' +
        (editable ? ' <button class="btn btn-sm" data-act="edit" data-id="' +
          entry.id + '">Edit</button>' +
          ' <button class="btn btn-sm btn-danger" data-act="del" data-id="' +
          entry.id + '">Delete</button>' : '') +
      '</td></tr>';
  }

  function tableFor(list, showTeam) {
    if (!list.length) {
      return '<div class="tablewrap"><div class="empty"><b>Nothing here yet</b>' +
        'No entries match the current filters.</div></div>';
    }
    return '<div class="tablewrap"><table class="entries"><thead><tr>' +
      '<th class="col-fav"></th><th>Tool</th><th>Env</th><th>IP / FQDN</th>' +
      '<th>Access from</th><th>Credential</th><th>MFA</th><th>Jump server</th>' +
      '<th class="col-act"></th></tr></thead><tbody>' +
      list.map(function (e) { return entryRow(e, showTeam); }).join('') +
      '</tbody></table></div>';
  }

  /* -------------------------------------------------------- home view */
  function renderHome() {
    var total = S.entries.length;
    var mfa = S.entries.filter(function (e) { return e.mfa === 'Yes'; }).length;
    var jump = S.entries.filter(function (e) { return e.jump_server; }).length;
    var prod = S.entries.filter(function (e) { return e.environment === 'Prod'; }).length;
    var pinned = S.entries.filter(function (e) { return isFav(e.id); });
    var recent = store(LS_RECENT, []);

    var html = '<section class="hero">' +
      '<h1>Infrastructure access, one place.</h1>' +
      '<p>Every console, jump server and endpoint the support tracks need, ' +
      'with the credential type and MFA requirement spelled out. Browsing is ' +
      'open to everyone; changes require a team sign-in.</p>' +
      '<div class="statgrid">' +
        '<div class="stat"><b>' + total + '</b><span>Entries</span></div>' +
        '<div class="stat"><b>' + S.teams.length + '</b><span>Teams</span></div>' +
        '<div class="stat"><b>' + prod + '</b><span>Production</span></div>' +
        '<div class="stat"><b>' + mfa + '</b><span>Need MFA</span></div>' +
        '<div class="stat"><b>' + jump + '</b><span>Via jump server</span></div>' +
      '</div></section>';

    if (pinned.length) {
      html += '<section class="section"><div class="section-head">' +
        '<h2>Pinned by you</h2><div class="rule"></div></div>' +
        tableFor(pinned, true) + '</section>';
    }

    if (recent.length) {
      html += '<section class="section"><div class="section-head">' +
        '<h2>Recently copied</h2><div class="rule"></div>' +
        '<button class="btn btn-sm" data-act="clear-recent">Clear</button></div>' +
        '<div class="cardgrid">' + recent.map(function (r) {
          return '<div class="teamcard" style="--chip:var(--ink-3);cursor:default">' +
            '<div class="tc-meta" style="margin-bottom:6px"><b>' + esc(r.label) +
            '</b></div><div class="copyfield"><span class="val">' + esc(r.value) +
            '</span>' + copyBtn(r.value, r.label) + '</div></div>';
        }).join('') + '</div></section>';
    }

    html += '<section class="section"><div class="section-head">' +
      '<h2>Teams</h2><div class="rule"></div></div><div class="cardgrid">' +
      S.teams.map(function (t) {
        return '<button class="teamcard" data-nav="/t/' + esc(t.slug) +
          '" style="--chip:' + esc(t.color) + '">' +
          '<div class="tc-top"><span class="tc-icon">' + esc(t.icon) +
          '</span><h3>' + esc(t.name) + '</h3></div>' +
          '<p>' + esc(t.description) + '</p>' +
          '<div class="tc-meta"><span><b>' + t.count + '</b> ' +
          (t.count === 1 ? 'entry' : 'entries') + '</span>' +
          '<span><b>' + t.mfa_count + '</b> MFA</span>' +
          '<span><b>' + t.jump_count + '</b> jump</span></div></button>';
      }).join('') + '</div></section>';

    return html;
  }

  /* ------------------------------------------------------ search view */
  function matches(entry, needle) {
    var team = S.byId[entry.team_id] || {};
    return [entry.tool_name, entry.category, entry.environment, entry.url,
            entry.host, entry.jump_server, entry.access_from, entry.access_id,
            team.name].join(' ').toLowerCase().indexOf(needle) !== -1;
  }

  function renderSearch() {
    var needle = S.query.toLowerCase();
    var hits = S.entries.filter(function (e) { return matches(e, needle); });
    var html = '<div class="section-head"><h2>' + hits.length +
      ' result' + (hits.length === 1 ? '' : 's') + ' for &ldquo;' +
      esc(S.query) + '&rdquo;</h2><div class="rule"></div>' +
      '<button class="btn btn-sm" data-act="clear-search">Clear search</button>' +
      '</div>';
    if (!hits.length) {
      return html + '<div class="tablewrap"><div class="empty">' +
        '<b>No matches</b>Try a hostname fragment, a tool name or a team name.' +
        '</div></div>';
    }
    S.teams.forEach(function (team) {
      var group = hits.filter(function (e) { return e.team_id === team.id; });
      if (!group.length) return;
      html += '<div class="resultgroup"><h3><span class="badge badge-plain" ' +
        'style="border-color:' + esc(team.color) + '">' + esc(team.icon) + ' ' +
        esc(team.name) + '</span> ' + group.length + ' match' +
        (group.length === 1 ? '' : 'es') + '</h3>' + tableFor(group, false) +
        '</div>';
    });
    return html;
  }

  /* -------------------------------------------------------- team view */
  function teamEntries(team) {
    var f = S.filters;
    var text = f.text.toLowerCase();
    var list = S.entries.filter(function (e) {
      if (e.team_id !== team.id) return false;
      if (f.env && e.environment !== f.env) return false;
      if (f.cat && e.category !== f.cat) return false;
      if (f.from && e.access_from !== f.from) return false;
      if (text && !matches(e, text)) return false;
      return true;
    });
    if (f.sort === 'name') {
      list.sort(function (a, b) { return a.tool_name.localeCompare(b.tool_name); });
    } else if (f.sort === 'env') {
      var order = { Prod: 0, UAT: 1, DR: 2 };
      list.sort(function (a, b) {
        return (order[a.environment] - order[b.environment]) ||
               a.tool_name.localeCompare(b.tool_name);
      });
    } else if (f.sort === 'mfa') {
      list.sort(function (a, b) {
        return (a.mfa === b.mfa ? 0 : (a.mfa === 'Yes' ? -1 : 1)) ||
               a.tool_name.localeCompare(b.tool_name);
      });
    }
    return list;
  }

  function renderTeam() {
    var team = S.bySlug[S.route.slug];
    if (!team) {
      return '<div class="empty"><b>Unknown team</b>' +
        '<a href="/" data-nav="/">Back to the home page</a></div>';
    }
    var list = teamEntries(team);
    var editable = canEdit(team.id);
    var all = S.entries.filter(function (e) { return e.team_id === team.id; });
    var cats = all.map(function (e) { return e.category; })
      .filter(function (c, i, a) { return c && a.indexOf(c) === i; }).sort();

    var html = '<div class="teamhead" style="--chip:' + esc(team.color) + '">' +
      '<span class="th-icon">' + esc(team.icon) + '</span>' +
      '<div><h1>' + esc(team.name) + '</h1><p>' + esc(team.description) +
      '</p></div><div class="spacer"></div><div class="headactions">' +
      '<a class="btn" href="/api/export?team=' + encodeURIComponent(team.slug) +
        '">Export CSV</a>' +
      (S.user ? '<button class="btn" data-act="audit">Change history</button>' : '') +
      (editable ? '<button class="btn" data-act="import">Import CSV</button>' +
        '<button class="btn btn-primary" data-act="new">+ Add entry</button>' : '') +
      '</div></div>';

    if (!S.user) {
      html += '<div class="banner banner-info">Viewing in read-only mode. ' +
        '<a href="/login?next=' + encodeURIComponent(location.pathname) +
        '">Sign in</a> as a ' + esc(team.name) +
        ' editor to change these entries.</div>';
    } else if (!editable) {
      html += '<div class="banner banner-info">You are signed in as <b>' +
        esc(S.user.username) + '</b>, which cannot edit ' + esc(team.name) +
        ' entries. Read-only for this team.</div>';
    }

    html += '<div class="toolbar">' +
      '<input type="text" id="fText" placeholder="Filter within ' +
        esc(team.name) + '..." value="' + esc(S.filters.text) + '">' +
      selectFilter('fEnv', 'All environments', S.vocab.environments, S.filters.env) +
      selectFilter('fCat', 'All categories', cats, S.filters.cat) +
      selectFilter('fFrom', 'Accessed from anywhere', S.vocab.access_from, S.filters.from) +
      '<select id="fSort">' +
        opt('default', 'Default order', S.filters.sort) +
        opt('name', 'Sort by name', S.filters.sort) +
        opt('env', 'Sort by environment', S.filters.sort) +
        opt('mfa', 'MFA first', S.filters.sort) +
      '</select>' +
      '<span class="count">' + list.length + ' of ' + all.length + '</span>' +
      '</div>';

    return html + tableFor(list, false);
  }

  function opt(value, label, current) {
    return '<option value="' + esc(value) + '"' +
      (current === value ? ' selected' : '') + '>' + esc(label) + '</option>';
  }
  function selectFilter(id, placeholder, values, current) {
    return '<select id="' + id + '">' + opt('', placeholder, current) +
      (values || []).map(function (v) { return opt(v, v, current); }).join('') +
      '</select>';
  }

  /* ---------------------------------------------------------- modals */
  function closeModal() { $('#modalRoot').innerHTML = ''; }

  function openModal(title, body, footer) {
    $('#modalRoot').innerHTML =
      '<div class="modal-backdrop" data-act="backdrop"><div class="modal" ' +
      'role="dialog" aria-modal="true"><div class="modal-head"><h2>' +
      esc(title) + '</h2><button class="btn btn-sm" data-act="close">Close</button>' +
      '</div><div class="modal-body">' + body + '</div>' +
      (footer ? '<div class="modal-foot">' + footer + '</div>' : '') +
      '</div></div>';
  }

  function field(name, label, value, hint) {
    return '<div class="field"><label for="f_' + name + '">' + esc(label) +
      '</label><input type="text" id="f_' + name + '" name="' + name +
      '" value="' + esc(value || '') + '">' +
      (hint ? '<span class="hint">' + esc(hint) + '</span>' : '') + '</div>';
  }
  function selectField(name, label, values, value, hint) {
    return '<div class="field"><label for="f_' + name + '">' + esc(label) +
      '</label><select id="f_' + name + '" name="' + name + '">' +
      values.map(function (v) { return opt(v, v, value); }).join('') +
      '</select>' + (hint ? '<span class="hint">' + esc(hint) + '</span>' : '') +
      '</div>';
  }

  function openEntryForm(entry) {
    var team = S.bySlug[S.route.slug];
    entry = entry || { environment: 'Prod', access_from: 'Laptop',
                       access_id: 'UID', mfa: 'No' };
    var body = '<div id="formErr"></div><div class="formgrid">' +
      '<div class="full">' + field('tool_name', 'Tool name *', entry.tool_name,
        'How the team refers to it, e.g. "Control-M Web (EM)"') + '</div>' +
      '<div class="field"><label for="f_category">Category</label>' +
      '<input type="text" id="f_category" name="category" list="catlist" value="' +
        esc(entry.category || '') + '">' +
      '<datalist id="catlist">' + (S.vocab.categories || []).map(function (c) {
        return '<option value="' + esc(c) + '"></option>'; }).join('') +
      '</datalist></div>' +
      selectField('environment', 'Environment', S.vocab.environments, entry.environment) +
      '<div class="full">' + field('url', 'URL', entry.url,
        'Must start with http:// or https:// - leave blank for thick clients') +
        '</div>' +
      '<div class="full">' + field('host', 'IP or FQDN *', entry.host,
        'The endpoint itself, e.g. ctm-em01.corp.local or 10.20.30.40:8443') +
        '</div>' +
      field('jump_server', 'Jump server', entry.jump_server,
        'Leave blank when reachable straight from the laptop') +
      field('jump_port', 'Jump port', entry.jump_port, '22 for SSH, 3389 for RDP') +
      selectField('access_from', 'Where to access from', S.vocab.access_from,
        entry.access_from) +
      selectField('access_id', 'Which ID to use', S.vocab.access_ids, entry.access_id) +
      selectField('mfa', 'MFA required', S.vocab.mfa, entry.mfa) +
      '</div>';

    openModal(entry.id ? 'Edit entry' : 'New entry for ' + team.name, body,
      '<button class="btn" data-act="close">Cancel</button>' +
      '<button class="btn btn-primary" data-act="save" data-id="' +
      (entry.id || '') + '">' + (entry.id ? 'Save changes' : 'Create entry') +
      '</button>');
    setTimeout(function () { var f = $('#f_tool_name'); if (f) f.focus(); }, 30);
  }

  function collectForm() {
    var payload = {};
    ['tool_name', 'category', 'environment', 'url', 'host', 'jump_server',
     'jump_port', 'access_from', 'access_id', 'mfa'].forEach(function (name) {
      var node = $('#f_' + name);
      payload[name] = node ? node.value.trim() : '';
    });
    return payload;
  }

  function formError(message) {
    $('#formErr').innerHTML = '<div class="formerr">' + esc(message) + '</div>';
  }

  function saveEntry(id) {
    var payload = collectForm();
    payload.team = S.route.slug;
    var request = id
      ? api('/api/entries/' + id, { method: 'PUT', body: JSON.stringify(payload) })
      : api('/api/entries', { method: 'POST', body: JSON.stringify(payload) });
    request.then(function () {
      closeModal();
      toast(id ? 'Entry updated' : 'Entry created');
      return reload();
    }).catch(function (err) { formError(err.message); });
  }

  function confirmDelete(entry) {
    openModal('Delete entry',
      '<p>Delete <b>' + esc(entry.tool_name) + '</b> from ' +
      esc((S.byId[entry.team_id] || {}).name) + '? This cannot be undone, but ' +
      'it will be recorded in the change history.</p>',
      '<button class="btn" data-act="close">Cancel</button>' +
      '<button class="btn btn-danger" data-act="del-confirm" data-id="' +
      entry.id + '">Delete entry</button>');
  }

  function openImport() {
    var team = S.bySlug[S.route.slug];
    openModal('Import CSV into ' + team.name,
      '<div id="formErr"></div>' +
      '<p style="margin-top:0;color:var(--ink-2);font-size:13.5px">Header row ' +
      'must contain <code class="mono">tool_name</code>; the other columns are ' +
      '<code class="mono">category, environment, url, host, jump_server, ' +
      'jump_port, access_from, access_id, mfa</code>. ' +
      '<a href="/api/export?team=' + encodeURIComponent(team.slug) + '">Export ' +
      'the current data</a> to get a correctly shaped template.</p>' +
      '<div class="field"><label for="csvFile">CSV file</label>' +
      '<input type="file" id="csvFile" accept=".csv,text/csv"></div>' +
      '<div class="field" style="margin-top:14px"><label for="csvText">' +
      'or paste CSV</label><textarea id="csvText" rows="9" spellcheck="false" ' +
      'placeholder="tool_name,category,environment,url,host,jump_server,' +
      'jump_port,access_from,access_id,mfa"></textarea></div>' +
      '<div class="field" style="margin-top:14px"><label for="csvMode">Mode' +
      '</label><select id="csvMode"><option value="append">Append to the ' +
      'existing entries</option><option value="replace">Replace every ' +
      'entry for this team</option></select>' +
      '<span class="hint">Replace deletes the whole team list first - the ' +
      'action is written to the change history.</span></div>',
      '<button class="btn" data-act="close">Cancel</button>' +
      '<button class="btn btn-primary" data-act="import-run">Import</button>');

    $('#csvFile').addEventListener('change', function (event) {
      var file = event.target.files[0];
      if (!file) return;
      var reader = new FileReader();
      reader.onload = function () { $('#csvText').value = reader.result; };
      reader.readAsText(file);
    });
  }

  function runImport() {
    var text = $('#csvText').value;
    var mode = $('#csvMode').value;
    if (!text.trim()) { formError('Choose a file or paste some CSV first.'); return; }
    if (mode === 'replace' &&
        !window.confirm('Replace every entry for this team? This deletes the ' +
                        'current list before importing.')) return;
    api('/api/import', {
      method: 'POST',
      body: JSON.stringify({ team: S.route.slug, csv: text, mode: mode })
    }).then(function (data) {
      closeModal();
      toast('Imported ' + data.imported + ' entr' +
            (data.imported === 1 ? 'y' : 'ies'));
      return reload();
    }).catch(function (err) { formError(err.message); });
  }

  function openAudit() {
    openModal('Change history', '<div class="empty">Loading&hellip;</div>');
    api('/api/audit?limit=150&team=' + encodeURIComponent(S.route.slug || 'all'))
      .then(function (data) {
        var body = data.audit.length
          ? '<div class="auditlist">' + data.audit.map(function (row) {
              return '<div class="auditrow"><time>' +
                esc((row.ts || '').replace('T', ' ').replace('Z', ' UTC')) +
                '</time><span class="act-' + esc(row.action) + '">' +
                esc(row.action) + '</span><span><span class="who">' +
                esc(row.username) + '</span> &middot; ' +
                esc(row.entry_name || row.team_slug || '-') + ' &middot; ' +
                esc(row.details) + '</span></div>';
            }).join('') + '</div>'
          : '<div class="empty"><b>No changes recorded</b>Edits will show up here.</div>';
        var modalBody = $('.modal-body');
        if (modalBody) modalBody.innerHTML = body;
      }).catch(function (err) {
        var modalBody = $('.modal-body');
        if (modalBody) modalBody.innerHTML = '<div class="formerr">' +
          esc(err.message) + '</div>';
      });
  }

  /* ------------------------------------------------------------ chrome */
  function renderChrome() {
    var chips = '<button class="teamchip" data-nav="/"' +
      (S.route.view === 'home' ? ' aria-current="true"' : '') +
      ' style="--chip:var(--accent)"><span class="dot"></span>Home</button>' +
      S.teams.map(function (t) {
        return '<button class="teamchip" data-nav="/t/' + esc(t.slug) + '"' +
          (S.route.slug === t.slug ? ' aria-current="true"' : '') +
          ' style="--chip:' + esc(t.color) + '"><span class="dot"></span>' +
          esc(t.name) + '</button>';
      }).join('');
    $('#teamChips').innerHTML = chips;

    $('#teamSelect').innerHTML = '<option value="/">Go to team&hellip;</option>' +
      S.teams.map(function (t) {
        return '<option value="/t/' + esc(t.slug) + '"' +
          (S.route.slug === t.slug ? ' selected' : '') + '>' + esc(t.name) +
          ' (' + t.count + ')</option>';
      }).join('');

    var auth = S.user
      ? '<a class="btn" href="/account" title="Signed in as ' +
        esc(S.user.username) + '">' + esc(S.user.username) +
        '<span class="role-sfx"> &middot; ' +
        (S.user.role === 'super' ? 'super' : 'editor') + '</span></a>' +
        '<form method="post" action="/logout" style="display:inline">' +
        '<button class="btn" type="submit">Sign out</button></form>'
      : '<a class="btn btn-primary" href="/login?next=' +
        encodeURIComponent(location.pathname) + '">Sign in to edit</a>';
    $('#authArea').innerHTML = auth;
  }

  function render() {
    renderChrome();
    var main = $('#main');
    if (S.query && S.query.length >= 2) main.innerHTML = renderSearch();
    else if (S.route.view === 'team') main.innerHTML = renderTeam();
    else main.innerHTML = renderHome();
  }

  function reload() {
    return api('/api/bootstrap').then(function (data) {
      S.teams = data.teams;
      S.vocab = data.vocab;
      S.user = data.user;
      S.byId = {}; S.bySlug = {};
      S.teams.forEach(function (t) { S.byId[t.id] = t; S.bySlug[t.slug] = t; });
      return api('/api/entries');
    }).then(function (data) {
      S.entries = data.entries;
      render();
    });
  }

  /* ----------------------------------------------------------- events */
  document.addEventListener('click', function (event) {
    var navTarget = event.target.closest('[data-nav]');
    if (navTarget) {
      event.preventDefault();
      go(navTarget.getAttribute('data-nav'));
      return;
    }
    var actionNode = event.target.closest('[data-act]');
    if (!actionNode) return;
    var action = actionNode.getAttribute('data-act');
    var id = parseInt(actionNode.getAttribute('data-id'), 10);
    var entry = S.entries.filter(function (e) { return e.id === id; })[0];

    if (action === 'copy') { handleCopy(actionNode); }
    else if (action === 'fav') {
      var on = toggleFav(id);
      actionNode.setAttribute('aria-pressed', on ? 'true' : 'false');
      actionNode.innerHTML = on ? ICON.starOn : ICON.star;
      if (S.route.view === 'home' && !S.query) render();
    }
    else if (action === 'clear-recent') { save(LS_RECENT, []); render(); }
    else if (action === 'clear-search') {
      $('#globalSearch').value = ''; S.query = ''; render();
    }
    else if (action === 'new') { openEntryForm(null); }
    else if (action === 'edit') { openEntryForm(entry); }
    else if (action === 'del') { confirmDelete(entry); }
    else if (action === 'del-confirm') {
      api('/api/entries/' + id, { method: 'DELETE' }).then(function () {
        closeModal(); toast('Entry deleted'); return reload();
      }).catch(function (err) { toast(err.message, true); });
    }
    else if (action === 'save') {
      saveEntry(actionNode.getAttribute('data-id'));
    }
    else if (action === 'import') { openImport(); }
    else if (action === 'import-run') { runImport(); }
    else if (action === 'audit') { openAudit(); }
    else if (action === 'close') { closeModal(); }
    else if (action === 'backdrop' && event.target === actionNode) { closeModal(); }
  });

  document.addEventListener('input', function (event) {
    var id = event.target.id;
    if (id === 'globalSearch') {
      S.query = event.target.value.trim();
      render();
    } else if (id === 'fText') {
      S.filters.text = event.target.value;
      var caret = event.target.selectionStart;
      render();
      var again = $('#fText');
      if (again) { again.focus(); again.setSelectionRange(caret, caret); }
    }
  });

  document.addEventListener('change', function (event) {
    var id = event.target.id;
    if (id === 'teamSelect') { go(event.target.value); }
    else if (id === 'fEnv') { S.filters.env = event.target.value; render(); }
    else if (id === 'fCat') { S.filters.cat = event.target.value; render(); }
    else if (id === 'fFrom') { S.filters.from = event.target.value; render(); }
    else if (id === 'fSort') { S.filters.sort = event.target.value; render(); }
  });

  document.addEventListener('keydown', function (event) {
    var tag = (event.target.tagName || '').toLowerCase();
    var typing = tag === 'input' || tag === 'textarea' || tag === 'select';
    if (event.key === '/' && !typing) {
      event.preventDefault();
      $('#globalSearch').focus();
      $('#globalSearch').select();
    } else if (event.key === 'Escape') {
      if ($('#modalRoot').innerHTML) { closeModal(); }
      else if (S.query) { $('#globalSearch').value = ''; S.query = ''; render(); }
    }
  });

  $('#themeToggle').addEventListener('click', cycleTheme);
  window.addEventListener('popstate', function () {
    parseRoute(); S.query = ''; $('#globalSearch').value = ''; render();
  });

  /* -------------------------------------------------------------- boot */
  initTheme();
  parseRoute();
  reload().catch(function (err) {
    $('#main').innerHTML = '<div class="empty"><b>The portal could not load</b>' +
      esc(err.message) + '</div>';
  });
})();
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/theme.js" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
/* Applies the stored light/dark preference on the server-rendered auth pages.
   Kept as an external file so the strict CSP can stay script-src 'self'. */
(function () {
  try {
    var mode = JSON.parse(localStorage.getItem('infraportal.theme'));
    if (mode === 'dark' || mode === 'light') {
      document.documentElement.setAttribute('data-theme', mode);
    }
  } catch (e) { /* no stored preference - fall back to prefers-color-scheme */ }
})();
__INFRAPORTAL_ASSET_EOF__

emit_asset "$APP_DIR/web/favicon.svg" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#4f46e5"/>
      <stop offset="1" stop-color="#06b6d4"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="14" fill="url(#g)"/>
  <g fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round">
    <path d="M18 22h28M18 32h28M18 42h16"/>
  </g>
  <circle cx="46" cy="42" r="5" fill="#fff"/>
</svg>
__INFRAPORTAL_ASSET_EOF__

python3 -m py_compile "$APP_DIR/app.py" \
  || die "app.py failed to compile - the script may have been truncated in transit."
rm -rf "$APP_DIR/__pycache__"
ok "app.py compiles cleanly"

# --------------------------------------------------------------------------
step "Initialising the SQLite database and seeding sample data"
# --------------------------------------------------------------------------
FRESH_DB="no"
[ -f "$DATA_DIR/portal.db" ] || FRESH_DB="yes"

INIT_OUT="$(runuser -u "$PORTAL_USER" -- env \
             PORTAL_ROOT="$APP_DIR" PORTAL_WEB="$APP_DIR/web" \
             PORTAL_DB="$DATA_DIR/portal.db" \
             /usr/bin/python3 "$APP_DIR/app.py" init 2>&1)" \
  || { printf '%s\n' "$INIT_OUT"; die "Database initialisation failed."; }
printf '%s\n' "$INIT_OUT" | grep -v '^CRED' | sed 's/^/     | /' || true

NEW_CREDS="$(printf '%s\n' "$INIT_OUT" | grep '^CRED' || true)"
if [ -n "$NEW_CREDS" ]; then
  {
    echo "InfraPortal - generated credentials"
    echo "Created : $(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname -f 2>/dev/null || hostname)"
    echo "Portal  : https://${SERVER_NAME}/"
    echo
    echo "Every account is flagged 'password change required' - the portal forces"
    echo "a new password at first sign-in. Delete this file once distributed."
    echo
    printf '%-14s %-20s %-8s %s\n' "USERNAME" "PASSWORD" "ROLE" "EDIT SCOPE"
    printf '%-14s %-20s %-8s %s\n' "--------------" "--------------------" "--------" "----------"
    printf '%s\n' "$NEW_CREDS" | awk -F'\t' '{printf "%-14s %-20s %-8s %s\n", $2, $3, $4, $5}'
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  ok "credentials for $(printf '%s\n' "$NEW_CREDS" | wc -l) account(s) written to ${CRED_FILE}"
else
  ok "all portal accounts already exist - passwords left untouched"
fi

if [ "$FRESH_DB" = "yes" ]; then
  ok "seeded 7 teams with sample entries"
else
  ok "existing database preserved (no sample data re-inserted)"
fi
chown -R "$PORTAL_USER":"$PORTAL_USER" "$DATA_DIR"

# --------------------------------------------------------------------------
step "Installing the systemd service"
# --------------------------------------------------------------------------
emit_asset "$UNIT_FILE" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
[Unit]
Description=InfraPortal - Infrastructure Access Directory
Documentation=file:__APP_DIR__/app.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=__PORTAL_USER__
Group=__PORTAL_USER__
WorkingDirectory=__APP_DIR__
Environment=PORTAL_ROOT=__APP_DIR__
Environment=PORTAL_WEB=__APP_DIR__/web
Environment=PORTAL_DB=__DATA_DIR__/portal.db
Environment=PORTAL_BIND=127.0.0.1
Environment=PORTAL_PORT=__APP_PORT__
Environment=PORTAL_SESSION_HOURS=8
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 -u __APP_DIR__/app.py serve
Restart=always
RestartSec=3
TimeoutStopSec=15

# Hardening - the portal only needs to read /opt and write its own data dir
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=__DATA_DIR__
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
UMask=0027

StandardOutput=journal
StandardError=journal
SyslogIdentifier=infraportal

[Install]
WantedBy=multi-user.target
__INFRAPORTAL_ASSET_EOF__

sed -i -e "s|__APP_DIR__|${APP_DIR}|g" \
       -e "s|__DATA_DIR__|${DATA_DIR}|g" \
       -e "s|__PORTAL_USER__|${PORTAL_USER}|g" \
       -e "s|__APP_PORT__|${APP_PORT}|g" "$UNIT_FILE"

emit_asset "${UNIT_FILE%.service}-backup.service" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
[Unit]
Description=InfraPortal nightly database backup

[Service]
Type=oneshot
User=__PORTAL_USER__
Group=__PORTAL_USER__
Environment=PORTAL_DB=__DATA_DIR__/portal.db
ExecStart=/usr/bin/python3 __APP_DIR__/app.py backup __DATA_DIR__/backups
__INFRAPORTAL_ASSET_EOF__

emit_asset "${UNIT_FILE%.service}-backup.timer" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
[Unit]
Description=Nightly InfraPortal database backup

[Timer]
OnCalendar=*-*-* 01:30:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
__INFRAPORTAL_ASSET_EOF__

sed -i -e "s|__APP_DIR__|${APP_DIR}|g" \
       -e "s|__DATA_DIR__|${DATA_DIR}|g" \
       -e "s|__PORTAL_USER__|${PORTAL_USER}|g" \
       "${UNIT_FILE%.service}-backup.service"

emit_asset "/usr/local/bin/infraportal-admin" 0750 root:root <<'__INFRAPORTAL_ASSET_EOF__'
#!/usr/bin/env bash
# InfraPortal administration helper. Runs the app CLI as the service account.
#
#   infraportal-admin listusers
#   infraportal-admin passwd  <username> <new-password>
#   infraportal-admin resetpw <username>
#   infraportal-admin adduser <username> <team-slug|super>
#   infraportal-admin backup  [directory]
#
# Team slugs: windows linux middleware database storage controlm cloudops
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
exec runuser -u __PORTAL_USER__ -- env \
     PORTAL_ROOT=__APP_DIR__ PORTAL_WEB=__APP_DIR__/web \
     PORTAL_DB=__DATA_DIR__/portal.db \
     /usr/bin/python3 __APP_DIR__/app.py "$@"
__INFRAPORTAL_ASSET_EOF__

sed -i -e "s|__APP_DIR__|${APP_DIR}|g" \
       -e "s|__DATA_DIR__|${DATA_DIR}|g" \
       -e "s|__PORTAL_USER__|${PORTAL_USER}|g" "/usr/local/bin/infraportal-admin"

systemctl daemon-reload
ok "systemd units installed"

# --------------------------------------------------------------------------
step "Preparing the TLS certificate"
# --------------------------------------------------------------------------
if [ -n "${PORTAL_CERT_FILE:-}" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  ok "using the supplied certificate ${CERT_FILE}"
elif [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && [ "${PORTAL_FORCE_CERT:-0}" != "1" ]; then
  ok "certificate already present at ${CERT_FILE} (PORTAL_FORCE_CERT=1 to replace)"
else
  install -d -m 0755 /etc/pki/tls/certs
  install -d -m 0700 /etc/pki/tls/private
  SAN="DNS:${SERVER_NAME},DNS:localhost,IP:127.0.0.1"
  if [ -n "$SERVER_SHORT" ] && [ "$SERVER_SHORT" != "$SERVER_NAME" ]; then
    SAN="${SAN},DNS:${SERVER_SHORT}"
  fi
  for ip in $SERVER_IPS; do SAN="${SAN},IP:${ip}"; done
  openssl req -x509 -newkey rsa:2048 -sha256 -days "$CERT_DAYS" -nodes \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/O=Infrastructure Support/OU=InfraPortal/CN=${SERVER_NAME}" \
    -addext "subjectAltName=${SAN}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 \
    || die "Certificate generation failed."
  chmod 0644 "$CERT_FILE"; chmod 0600 "$KEY_FILE"
  chown root:root "$CERT_FILE" "$KEY_FILE"
  ok "self-signed certificate generated, valid ${CERT_DAYS} days"
  info "SAN: ${SAN}"
fi

emit_asset "/usr/local/bin/infraportal-cert" 0750 root:root <<'__INFRAPORTAL_ASSET_EOF__'
#!/usr/bin/env bash
#############################################################################
#  infraportal-cert - swap the self-signed certificate for a CA-issued one
#
#    infraportal-cert show
#        Print the subject, issuer, SANs and expiry of the live certificate.
#
#    infraportal-cert csr [CN] [extra-name ...]
#        Generate a fresh 2048-bit key plus a CSR to hand to your internal CA
#        (AD Certificate Services, Venafi, EJBCA, ...). The new key is staged
#        and NOT put into service until 'install' runs, so the running site is
#        untouched if the request is refused or forgotten.
#        Names are auto-classified: 10.0.0.5 becomes an IP SAN, anything else
#        a DNS SAN. With no arguments the host's own names and addresses are
#        used.
#
#    infraportal-cert install <issued-file> [chain-file]
#        Validate that the certificate matches the staged (or current) key,
#        back up what is live, install, re-test the Apache config and reload.
#        Any failure rolls the previous pair back automatically.
#        Accepts whatever AD CS gave you: Base64 .cer, DER .cer, a .p7b chain
#        or a PEM bundle. The leaf is identified by matching the private key,
#        so any extra certificates in the file become the chain automatically
#        and a separate chain file is then optional.
#
#    infraportal-cert rollback
#        Restore the most recent backup.
#############################################################################
set -euo pipefail

CERT_FILE="__CERT_FILE__"
KEY_FILE="__KEY_FILE__"
HTTPD_CONF="__HTTPD_CONF__"
NEW_KEY="/etc/pki/tls/private/infraportal-new.key"
CSR_FILE="/root/infraportal.csr"
BACKUP_DIR="/etc/pki/tls/infraportal-backups"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
ok()   { printf '%s+%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

TMPD=""
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; return 0; }
trap cleanup EXIT

# Public key fingerprint of a cert, key or CSR - two files belong together
# when these match.
pubkey_of() {
  case "$2" in
    cert) openssl x509 -in "$1" -noout -pubkey 2>/dev/null ;;
    key)  openssl pkey -in "$1" -pubout 2>/dev/null ;;
    csr)  openssl req -in "$1" -noout -pubkey 2>/dev/null ;;
  esac | openssl sha256 | awk '{print $NF}'
}

# Turn whatever a CA handed over into PEM. AD CS web enrolment gives Base64
# .cer (already PEM), DER .cer, or a PKCS#7 .p7b holding the whole chain.
to_pem() {
  local src="$1" dest="$2"
  if grep -q -- '-----BEGIN CERTIFICATE-----' "$src" 2>/dev/null; then
    cp -- "$src" "$dest"; return 0
  fi
  if openssl x509 -inform DER -in "$src" -out "$dest" 2>/dev/null; then
    return 0
  fi
  local form
  for form in DER PEM; do
    if openssl pkcs7 -inform "$form" -in "$src" -print_certs 2>/dev/null \
         | grep -q -- '-----BEGIN CERTIFICATE-----'; then
      openssl pkcs7 -inform "$form" -in "$src" -print_certs 2>/dev/null > "$dest"
      return 0
    fi
  done
  return 1
}

# Split a PEM bundle into one file per certificate, dropping the descriptive
# text "openssl pkcs7 -print_certs" interleaves between blocks. The "inside"
# flag matters: without it the text following a block would be written to the
# just-closed file, and awk re-truncates on reopen, destroying the contents.
# CRs are stripped because a certificate downloaded from a Windows CA arrives
# with CRLF endings.
split_certs() {
  awk -v d="$2" '
    { sub(/\r$/, "") }
    /^-----BEGIN CERTIFICATE-----$/ { n++; f = sprintf("%s/cert-%02d.pem", d, n); inside = 1 }
    inside { print > f }
    /^-----END CERTIFICATE-----$/   { if (inside) { close(f); inside = 0 } }
  ' "$1"
}

describe_cert() {
  openssl x509 -in "$1" -noout -subject | sed 's/^subject=//'
}

cmd_show() {
  [ -f "$CERT_FILE" ] || die "no certificate at $CERT_FILE"
  printf '%sLive certificate: %s%s\n\n' "$C_BOLD" "$CERT_FILE" "$C_RESET"
  openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates
  printf '\nSubject Alternative Names:\n'
  openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | sed 's/^ */  /' || printf '  (none)\n'

  local subject issuer
  subject="$(openssl x509 -in "$CERT_FILE" -noout -subject)"
  issuer="$(openssl x509 -in "$CERT_FILE" -noout -issuer)"
  printf '\n'
  if [ "${subject#subject=}" = "${issuer#issuer=}" ]; then
    warn "Self-signed: browsers will warn until a CA your clients trust signs it."
    warn "Run 'infraportal-cert csr' to produce a request for your internal CA."
  else
    ok "Issued by a separate CA. Clients trust it once that CA is in their store."
  fi

  if openssl x509 -in "$CERT_FILE" -noout -checkend 2592000 >/dev/null 2>&1; then
    ok "More than 30 days of validity remaining."
  else
    warn "Expires within 30 days (or already has) - renew it."
  fi
}

cmd_csr() {
  local cn="${1:-}"; shift || true
  if [ -z "$cn" ]; then
    cn="$(hostname -f 2>/dev/null || hostname)"
  fi

  local san="DNS:${cn}" short ip
  short="$(hostname -s 2>/dev/null || echo '')"
  if [ -n "$short" ] && [ "$short" != "$cn" ]; then
    san="${san},DNS:${short}"
  fi
  for ip in $(hostname -I 2>/dev/null || true); do
    san="${san},IP:${ip}"
  done
  # Anything the caller added, classified by shape
  local extra
  for extra in "$@"; do
    case "$extra" in
      *:*|[0-9]*.[0-9]*.[0-9]*.[0-9]*) san="${san},IP:${extra}" ;;
      *)                                san="${san},DNS:${extra}" ;;
    esac
  done

  install -d -m 0700 /etc/pki/tls/private
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$NEW_KEY" -out "$CSR_FILE" \
    -subj "/O=Infrastructure Support/OU=InfraPortal/CN=${cn}" \
    -addext "subjectAltName=${san}" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2>/dev/null \
    || die "CSR generation failed"
  chmod 0600 "$NEW_KEY"; chmod 0644 "$CSR_FILE"

  ok "staged key : $NEW_KEY  (not in service yet)"
  ok "CSR        : $CSR_FILE"
  printf '\n  Common Name: %s\n  SANs       : %s\n' "$cn" "$san"
  printf '\n%sSubmit this to your CA (AD CS web enrolment: template "Web Server"):%s\n\n' \
    "$C_BOLD" "$C_RESET"
  cat "$CSR_FILE"
  printf '\n%sWhen the CA returns the certificate, copy it onto this server and run:%s\n' \
    "$C_BOLD" "$C_RESET"
  printf '    infraportal-cert install <the-file-the-CA-gave-you>\n\n'
  printf '  Any of .cer (Base64 or DER), .crt, .p7b or a PEM bundle is fine. A\n'
  printf '  .p7b already contains the chain, so no second argument is needed.\n'
}

cmd_install() {
  local given_cert="${1:-}" given_chain="${2:-}"
  if [ -z "$given_cert" ]; then
    die "usage: infraportal-cert install <issued-file> [chain-file]

       <issued-file> is the certificate your CA sent back. If you have not
       requested one yet, start with:

           infraportal-cert csr $(hostname -f 2>/dev/null || hostname)

       then submit the printed request to your CA and come back here."
  fi
  if [ ! -f "$given_cert" ]; then
    die "no such file: $given_cert
       (that path is only an example - use the file your CA actually returned)"
  fi
  if [ -n "$given_chain" ] && [ ! -f "$given_chain" ]; then
    die "no such chain file: $given_chain"
  fi

  TMPD="$(mktemp -d)"
  local bundle="$TMPD/bundle.pem"
  if ! to_pem "$given_cert" "$bundle"; then
    die "$given_cert is not a certificate in any format this understands
       (expected Base64 or DER .cer/.crt, a PKCS#7 .p7b, or a PEM bundle)"
  fi
  if [ -n "$given_chain" ]; then
    if ! to_pem "$given_chain" "$TMPD/chain-in.pem"; then
      die "$given_chain is not a certificate in any recognised format"
    fi
    cat "$TMPD/chain-in.pem" >> "$bundle"
  fi

  install -d -m 0700 "$TMPD/certs"
  split_certs "$bundle" "$TMPD/certs"
  local found
  found="$(find "$TMPD/certs" -name 'cert-*.pem' | wc -l)"
  if [ "$found" -eq 0 ]; then
    die "no certificates found inside $given_cert"
  fi
  ok "read ${found} certificate(s) from the supplied file(s)"

  # The leaf is whichever certificate matches a private key we hold; anything
  # else that came along is chain material. This is what lets a bare .p7b work.
  local staged_pub="" live_pub="" use_key="" leaf="" c cpub
  if [ -f "$NEW_KEY" ];  then staged_pub="$(pubkey_of "$NEW_KEY" key)"; fi
  if [ -f "$KEY_FILE" ]; then live_pub="$(pubkey_of "$KEY_FILE" key)"; fi
  for c in "$TMPD"/certs/cert-*.pem; do
    cpub="$(pubkey_of "$c" cert)"
    if [ -n "$staged_pub" ] && [ "$cpub" = "$staged_pub" ]; then
      leaf="$c"; use_key="$NEW_KEY"
      ok "leaf: $(describe_cert "$c")"
      ok "matches the staged key from 'infraportal-cert csr'"
      break
    fi
    if [ -n "$live_pub" ] && [ "$cpub" = "$live_pub" ]; then
      leaf="$c"; use_key="$KEY_FILE"
      ok "leaf: $(describe_cert "$c")"
      ok "matches the key already in service"
      break
    fi
  done
  if [ -z "$leaf" ]; then
    die "none of the ${found} certificate(s) match a private key on this host.
       They were issued from a different CSR than the one staged here.
       Run 'infraportal-cert csr' again and submit the new request."
  fi

  local chain_pem=""
  for c in "$TMPD"/certs/cert-*.pem; do
    if [ "$c" = "$leaf" ]; then continue; fi
    chain_pem="$TMPD/chain.pem"
    cat "$c" >> "$chain_pem"
    ok "chain: $(describe_cert "$c")"
  done

  local new_cert="$leaf" subject issuer
  subject="$(openssl x509 -in "$new_cert" -noout -subject)"
  issuer="$(openssl x509 -in "$new_cert" -noout -issuer)"
  if [ "${subject#subject=}" = "${issuer#issuer=}" ]; then
    warn "this certificate is also self-signed - browsers will still warn"
  fi
  openssl x509 -in "$new_cert" -noout -checkend 0 >/dev/null 2>&1 \
    || die "this certificate is already expired"

  # Back up whatever is live so a bad swap is always reversible
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP_DIR"
  if [ -f "$CERT_FILE" ]; then cp -a "$CERT_FILE" "$BACKUP_DIR/cert-${stamp}.pem"; fi
  if [ -f "$KEY_FILE" ];  then cp -a "$KEY_FILE"  "$BACKUP_DIR/key-${stamp}.pem"; fi
  cp -a "$HTTPD_CONF" "$BACKUP_DIR/vhost-${stamp}.conf"
  ok "backed up the current pair to $BACKUP_DIR (stamp ${stamp})"

  install -m 0644 -o root -g root "$new_cert" "$CERT_FILE"
  if [ "$use_key" != "$KEY_FILE" ]; then
    install -m 0600 -o root -g root "$use_key" "$KEY_FILE"
    rm -f "$NEW_KEY"
  fi

  # Point the vhost at the chain, or comment the directive back out
  local chain_line="# SSLCertificateChainFile is not used with this certificate"
  if [ -n "$chain_pem" ]; then
    install -d -m 0755 /etc/pki/tls/certs
    install -m 0644 -o root -g root "$chain_pem" /etc/pki/tls/certs/infraportal-chain.pem
    chain_line="SSLCertificateChainFile /etc/pki/tls/certs/infraportal-chain.pem"
  fi
  sed -i -E "s|^([[:space:]]*)(#[[:space:]]*)?SSLCertificateChainFile.*|\\1${chain_line}|" \
    "$HTTPD_CONF"

  if ! httpd -t 2>&1 | sed 's/^/  | /'; then
    warn "Apache rejected the new configuration - rolling back"
    cmd_rollback
    die "install aborted, the previous certificate is back in service"
  fi

  systemctl reload httpd || systemctl restart httpd
  sleep 1
  if ! systemctl is-active --quiet httpd; then
    warn "httpd did not come back - rolling back"
    cmd_rollback
    die "install aborted, the previous certificate is back in service"
  fi

  ok "installed and httpd reloaded"
  printf '\n'
  cmd_show
}

cmd_rollback() {
  local last_cert last_key last_conf
  last_cert="$(ls -1 "$BACKUP_DIR"/cert-*.pem 2>/dev/null | tail -1 || true)"
  last_key="$(ls -1 "$BACKUP_DIR"/key-*.pem 2>/dev/null | tail -1 || true)"
  last_conf="$(ls -1 "$BACKUP_DIR"/vhost-*.conf 2>/dev/null | tail -1 || true)"
  [ -n "$last_cert" ] || die "no backup to roll back to in $BACKUP_DIR"
  cp -a "$last_cert" "$CERT_FILE"
  [ -n "$last_key" ]  && cp -a "$last_key"  "$KEY_FILE"
  [ -n "$last_conf" ] && cp -a "$last_conf" "$HTTPD_CONF"
  systemctl reload httpd >/dev/null 2>&1 || systemctl restart httpd >/dev/null 2>&1 || true
  ok "restored $(basename "$last_cert")"
}

case "${1:-show}" in
  show)     cmd_show ;;
  csr)      shift; cmd_csr "$@" ;;
  install)  shift; cmd_install "$@" ;;
  rollback) cmd_rollback ;;
  *) sed -n '2,26p' "$0" | sed 's/^#*//'; exit 2 ;;
esac
__INFRAPORTAL_ASSET_EOF__

sed -i -e "s|__CERT_FILE__|${CERT_FILE}|g" \
       -e "s|__KEY_FILE__|${KEY_FILE}|g" \
       -e "s|__HTTPD_CONF__|${HTTPD_CONF}|g" "/usr/local/bin/infraportal-cert"
info "run 'infraportal-cert csr' to request a CA-signed replacement"

# --------------------------------------------------------------------------
step "Configuring Apache httpd"
# --------------------------------------------------------------------------
for stock in ssl.conf welcome.conf; do
  if [ -f "/etc/httpd/conf.d/${stock}" ]; then
    mv "/etc/httpd/conf.d/${stock}" "/etc/httpd/conf.d/${stock}.infraportal-disabled"
    info "moved stock ${stock} aside (kept as ${stock}.infraportal-disabled)"
  fi
done

# Remove our own previous copy first, so the search below only sees other files
rm -f "$HTTPD_CONF"
LISTEN_LINE="Listen 443 https"
if grep -qsE '^[[:space:]]*Listen[[:space:]]+443' /etc/httpd/conf/httpd.conf \
     /etc/httpd/conf.d/*.conf 2>/dev/null; then
  LISTEN_LINE="# Listen 443 is already declared in another configuration file"
  info "another config already declares Listen 443 - not repeating it"
fi

CHAIN_LINE="# SSLCertificateChainFile is not used with this certificate"
if [ -n "$CHAIN_FILE" ] && [ -f "$CHAIN_FILE" ]; then
  CHAIN_LINE="SSLCertificateChainFile ${CHAIN_FILE}"
fi

# Only advertise aliases that differ from ServerName, to keep httpd quiet
ALIASES=""
if [ -n "$SERVER_SHORT" ] && [ "$SERVER_SHORT" != "$SERVER_NAME" ]; then
  ALIASES="$SERVER_SHORT"
fi
for ip in $SERVER_IPS; do
  ALIASES="${ALIASES:+$ALIASES }${ip}"
done
if [ -n "$ALIASES" ]; then
  ALIAS_LINE="ServerAlias ${ALIASES}"
else
  ALIAS_LINE="# no additional names for this host"
fi

emit_asset "$HTTPD_CONF" 0644 root:root <<'__INFRAPORTAL_ASSET_EOF__'
# ==========================================================================
#  InfraPortal - Apache front end
#  TLS termination + reverse proxy to the Python application on 127.0.0.1.
#  Generated by deploy-infraportal.sh - re-running the script rewrites it.
# ==========================================================================

ServerTokens Prod
ServerSignature Off
TraceEnable Off

__LISTEN_LINE__

# Session cache is a server-level directive, not a per-vhost one
<IfModule mod_ssl.c>
    SSLSessionCache        shmcb:/run/httpd/sslcache(512000)
    SSLSessionCacheTimeout 300
</IfModule>

# ------------------------------------------------------------ HTTP -> HTTPS
<VirtualHost *:80>
    ServerName __SERVER_NAME__
    __ALIAS_LINE__

    <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteRule ^/?(.*) https://%{HTTP_HOST}/$1 [R=301,L,NE]
    </IfModule>

    ErrorLog  /var/log/httpd/infraportal_redirect_error.log
    CustomLog /var/log/httpd/infraportal_redirect_access.log combined
</VirtualHost>

# ------------------------------------------------------------------- HTTPS
<VirtualHost *:443>
    ServerName __SERVER_NAME__
    __ALIAS_LINE__

    SSLEngine on
    SSLCertificateFile    __CERT_FILE__
    SSLCertificateKeyFile __KEY_FILE__
    __CHAIN_LINE__

    # TLS 1.2/1.3 only; ciphers follow the RHEL system-wide crypto policy
    SSLProtocol         -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite      PROFILE=SYSTEM
    SSLHonorCipherOrder off

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=31536000"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "DENY"
        Header always set Referrer-Policy "same-origin"
        Header always set Permissions-Policy "geolocation=(), camera=(), microphone=()"
        Header always set Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        RequestHeader set X-Forwarded-Proto "https"
    </IfModule>

    # ------------------------------------------------ reverse proxy
    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 60
    ProxyPass        / http://127.0.0.1:__APP_PORT__/ retry=1
    ProxyPassReverse / http://127.0.0.1:__APP_PORT__/

    <Proxy "http://127.0.0.1:__APP_PORT__/">
        Require all granted
    </Proxy>

    # Matches MAX_BODY in app.py, so an oversized CSV is refused here with a
    # clean 413 rather than arriving truncated
    LimitRequestBody 8388608

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/css text/csv \
            text/plain application/javascript application/json image/svg+xml
    </IfModule>

    ErrorLog  /var/log/httpd/infraportal_error.log
    CustomLog /var/log/httpd/infraportal_access.log combined
    LogLevel warn
</VirtualHost>
__INFRAPORTAL_ASSET_EOF__

sed -i -e "s|__LISTEN_LINE__|${LISTEN_LINE}|g" \
       -e "s|__CHAIN_LINE__|${CHAIN_LINE}|g" \
       -e "s|__ALIAS_LINE__|${ALIAS_LINE}|g" \
       -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
       -e "s|__CERT_FILE__|${CERT_FILE}|g" \
       -e "s|__KEY_FILE__|${KEY_FILE}|g" \
       -e "s|__APP_PORT__|${APP_PORT}|g" "$HTTPD_CONF"

httpd -t 2>&1 | sed 's/^/     | /' || die "Apache rejected the generated configuration."
ok "Apache configuration is syntactically valid"

# --------------------------------------------------------------------------
step "Applying SELinux policy"
# --------------------------------------------------------------------------
# getenforce can report Disabled while the policy is still enforced against
# this process tree - the normal case inside a container, where the host owns
# SELinux. httpd is then denied 127.0.0.1:APP_PORT with "(13)Permission denied"
# even though nothing here looks enabled. So always attempt the configuration
# and let the individual commands decide whether they apply.
SEL_MODE="unavailable"
if command -v getenforce >/dev/null 2>&1; then
  SEL_MODE="$(getenforce 2>/dev/null || echo unavailable)"
fi
info "getenforce reports: ${SEL_MODE}"

SEL_DONE=0
if command -v semanage >/dev/null 2>&1; then
  if semanage port -l 2>/dev/null | grep -qE "^http_port_t.*\b${APP_PORT}\b"; then
    ok "tcp/${APP_PORT} is already labelled http_port_t"
    SEL_DONE=1
  elif semanage port -a -t http_port_t -p tcp "$APP_PORT" >/dev/null 2>&1; then
    ok "labelled tcp/${APP_PORT} as http_port_t"
    SEL_DONE=1
  fi
fi

if [ "$SEL_DONE" -eq 0 ]; then
  if setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1; then
    ok "set httpd_can_network_connect=1 (persistent)"
    SEL_DONE=1
  elif setsebool httpd_can_network_connect 1 >/dev/null 2>&1; then
    warn "set httpd_can_network_connect=1 for this boot only - the persistent"
    warn "write failed, so re-apply it after a reboot"
    SEL_DONE=1
  fi
fi

if [ "$SEL_DONE" -eq 0 ]; then
  case "$SEL_MODE" in
    Disabled|unavailable)
      info "no SELinux tooling and getenforce says ${SEL_MODE} - nothing applied" ;;
    *)
      warn "could not apply SELinux settings; if the portal returns 503, run:"
      warn "    setsebool -P httpd_can_network_connect 1 && systemctl restart httpd" ;;
  esac
fi
restorecon -R "$DATA_DIR" >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
step "Opening the firewall"
# --------------------------------------------------------------------------
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-service=http  >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "firewalld: http and https allowed in zone $(firewall-cmd --get-default-zone 2>/dev/null || echo default)"
else
  info "firewalld is not running - skipping (open 80/tcp and 443/tcp yourself if filtered)"
fi

# --------------------------------------------------------------------------
step "Starting services"
# --------------------------------------------------------------------------
systemctl enable --now infraportal.service >/dev/null 2>&1 || true
systemctl restart infraportal.service
systemctl enable --now infraportal-backup.timer >/dev/null 2>&1 || true
systemctl enable httpd >/dev/null 2>&1 || true
systemctl restart httpd

sleep 2
systemctl is-active --quiet infraportal.service \
  || { journalctl -u infraportal.service -n 30 --no-pager; die "infraportal.service did not start."; }
ok "infraportal.service is running"
systemctl is-active --quiet httpd \
  || { journalctl -u httpd -n 30 --no-pager; die "httpd did not start."; }
ok "httpd is running"

# --------------------------------------------------------------------------
step "Verifying the deployment"
# --------------------------------------------------------------------------
FAILED=0

if ! command -v curl >/dev/null 2>&1; then
  warn "curl is not installed - skipping the end-to-end checks"
  warn "verify manually: https://${SERVER_NAME}/health should return {\"status\": \"ok\", ...}"
  FAILED=0
else

APP_OK=0; TLS_OK=0

APP_HEALTH="$(curl -fsS --max-time 5 "http://127.0.0.1:${APP_PORT}/health" 2>/dev/null || true)"
case "$APP_HEALTH" in
  *'"status"'*'"ok"'*) ok "application health endpoint responded on 127.0.0.1:${APP_PORT}"
                       APP_OK=1 ;;
  *) warn "application health check failed"; FAILED=1 ;;
esac

TLS_HEALTH="$(curl -fsSk --max-time 8 "https://127.0.0.1/health" 2>/dev/null || true)"
case "$TLS_HEALTH" in
  *'"status"'*'"ok"'*) ok "HTTPS through Apache responded"; TLS_OK=1 ;;
  *) warn "HTTPS health check failed"; FAILED=1 ;;
esac

# A healthy backend that Apache cannot reach has exactly one common cause.
if [ "$APP_OK" -eq 1 ] && [ "$TLS_OK" -eq 0 ]; then
  printf '\n'
  warn "The application is healthy but Apache cannot connect to it."
  warn "That is an SELinux denial in almost every case. Confirm with:"
  warn "    tail /var/log/httpd/infraportal_error.log     # look for (13)Permission denied"
  warn "    ausearch -m avc -ts recent | grep -i httpd"
  warn "and fix it with:"
  warn "    setsebool -P httpd_can_network_connect 1 && systemctl restart httpd"
  printf '\n'
fi

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1/" 2>/dev/null || echo 000)"
if [ "$HTTP_CODE" = "301" ]; then
  ok "HTTP is redirected to HTTPS (301)"
else
  warn "expected a 301 from http://127.0.0.1/ but got ${HTTP_CODE}"; FAILED=1
fi

HOME_CODE="$(curl -s -o /dev/null -w '%{http_code}' -k --max-time 8 "https://127.0.0.1/" 2>/dev/null || echo 000)"
[ "$HOME_CODE" = "200" ] && ok "home page returns 200" \
  || { warn "home page returned ${HOME_CODE}"; FAILED=1; }

ENTRY_COUNT="$(printf '%s' "$TLS_HEALTH" | sed -n 's/.*"entries": *\([0-9]*\).*/\1/p')"
if [ -n "$ENTRY_COUNT" ]; then ok "${ENTRY_COUNT} entries in the directory"; fi

# Confirm an unauthenticated write is refused - requirement: edits need auth
AUTHZ_CODE="$(curl -s -o /dev/null -w '%{http_code}' -k --max-time 8 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"team":"linux","tool_name":"unauthenticated probe","host":"x"}' \
  "https://127.0.0.1/api/entries" 2>/dev/null || echo 000)"
if [ "$AUTHZ_CODE" = "401" ]; then
  ok "anonymous write attempt correctly rejected (401)"
else
  warn "anonymous write returned ${AUTHZ_CODE}, expected 401"; FAILED=1
fi

fi   # end of the curl-dependent checks

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
printf '\n%s' "$C_BOLD"
printf '=%.0s' $(seq 1 74); printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '  %sDEPLOYMENT COMPLETE%s\n' "$C_GREEN" "$C_RESET$C_BOLD"
else
  printf '  %sDEPLOYED WITH WARNINGS - review the messages above%s\n' "$C_YELLOW" "$C_RESET$C_BOLD"
fi
printf '=%.0s' $(seq 1 74); printf '\n%s\n' "$C_RESET"

cat <<SUMMARY
  Portal URL      : https://${SERVER_NAME}/
${SERVER_IP:+  By IP           : https://${SERVER_IP}/}
  Credentials     : ${CRED_FILE} (mode 600, root only)
  Application     : ${APP_DIR}/app.py   (systemctl status infraportal)
  Database        : ${DATA_DIR}/portal.db
  Nightly backup  : ${BACKUP_DIR} at 01:30 (systemctl list-timers infraportal*)
  Apache vhost    : ${HTTPD_CONF}
  Certificate     : ${CERT_FILE}
  Logs            : journalctl -u infraportal -f
                    /var/log/httpd/infraportal_{access,error}.log

  Accounts        : superadmin edits every team; win_admin, lnx_admin,
                    mw_admin, db_admin, stg_admin, ctm_admin and cloud_admin
                    each edit only their own team. Everyone else browses
                    without signing in. First sign-in forces a password change.

  Admin helper    : infraportal-admin listusers
                    infraportal-admin resetpw <username>
                    infraportal-admin adduser <username> <team-slug|super>
                    infraportal-admin backup

  The certificate is self-signed, so browsers warn on first visit. To make it
  trusted, have your internal CA sign it - the clients already trust that CA:
      infraportal-cert csr portal.corp.local     # emits a CSR to submit
      infraportal-cert install issued.crt chain.pem
      infraportal-cert show                      # subject, SANs, expiry
  The install step checks the certificate against the private key, backs up
  what is live and rolls back automatically if httpd will not take it.
SUMMARY

if [ -n "${NEW_CREDS:-}" ]; then
  printf '\n%s  Generated passwords (also saved in %s):%s\n\n' "$C_BOLD" "$CRED_FILE" "$C_RESET"
  printf '%s\n' "$NEW_CREDS" \
    | awk -F'\t' '{printf "      %-14s %-20s %-8s %s\n", $2, $3, $4, $5}'
  printf '\n  %sDistribute these, then delete %s.%s\n\n' "$C_YELLOW" "$CRED_FILE" "$C_RESET"
else
  printf '\n  Existing accounts were left untouched; see %s.\n\n' "$CRED_FILE"
fi

exit 0
