#!/usr/bin/env python3
"""A synthetic, no-DNS Route53 API stub for local certbotbot lifecycle tests.

Implements only the Route53 Query API calls the installed Certbot dns-route53
authenticator needs. No DNS answers are created, no network clients are used,
and no request is forwarded to AWS or Pebble. Pebble's independently configured
PEBBLE_VA_ALWAYS_VALID=1 bypasses actual DNS-01 verification.

Governing decision: ADR-047, superseding ADR-046's DNS acceptance requirement.
This module is test-only, never part of the shipped certbotbot artifact.
"""

from __future__ import annotations

import http.server
import re
import threading
import urllib.parse
import xml.etree.ElementTree as ET

VERSION = "2013-04-01"
NS = "https://route53.amazonaws.com/doc/2013-04-01/"
ZONE = "e2e.test."
ZONE_ID = "ZLOCALONLY123456"
ACCESS_KEY = "CBOTBOT_LOCAL_TEST_ACCESS_ONLY"
VALUE_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
NAME_RE = re.compile(r"^_acme-challenge(?:\.[a-z0-9-]+)*\.e2e\.test\.?$")
MAX_BODY = 16384

ET.register_namespace("", NS)


def tag(name: str) -> str:
    """Return a fully-qualified Route53 XML tag."""
    return f"{{{NS}}}{name}"


def element(name: str) -> ET.Element:
    """Create a Route53 Query XML root."""
    return ET.Element(tag(name))


def child(parent: ET.Element, name: str, value: str | None = None) -> ET.Element:
    """Append a namespace-qualified Route53 XML child."""
    node = ET.SubElement(parent, tag(name))
    node.text = value
    return node


def xml_bytes(root: ET.Element) -> bytes:
    """Encode one protocol response without emitting credentials."""
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


class ApiError(Exception):
    """An intentionally bounded API refusal, never an untrusted error string."""

    def __init__(self, code: str, status: int = 400):
        self.code = code
        self.status = status
        super().__init__(code)


class Route53Stub(http.server.BaseHTTPRequestHandler):
    """Serve a single synthetic zone via three narrow Route53 operations."""

    server_version = "LocalRoute53Stub/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        """Suppress sensitive headers, DNS values, paths and query strings."""
        pass

    @staticmethod
    def receipt(stage: str) -> None:
        """Emit a reviewed nonsecret operation stage to private Docker logs."""
        # No request path, headers, TXT values, account data, or raw errors.
        print(f"local-route53-stub: {stage}", flush=True)

    def reply(self, status: int, data: bytes) -> None:
        """Return XML without redirects or client-controlled headers."""
        self.send_response(status)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def refuse(self, code: str, status: int = 400) -> None:
        """Give the plugin a well-formed static Route53 API error."""
        root = element("ErrorResponse")
        item = child(root, "Error")
        child(item, "Type", "Sender")
        child(item, "Code", code)
        child(item, "Message", "Local test provider refused operation")
        child(root, "RequestId", "local-only")
        # Error codes are fixed in this stub. Never log caller-supplied data.
        if code in ("AccessDenied", "InvalidInput", "InvalidAction",
                    "InvalidChangeBatch", "NoSuchChange"):
            self.receipt(f"refused={code}")
        self.reply(status, xml_bytes(root))

    def authenticated(self) -> bool:
        """Check the synthetic access key only, not real SigV4 cryptography."""
        authorization = self.headers.get("Authorization", "")
        return (authorization.startswith("AWS4-HMAC-SHA256 ")
                and f"Credential={ACCESS_KEY}/" in authorization)

    def dispatch(self, method: str) -> None:
        """Reject unlisted paths, actions and credentials before mutation."""
        try:
            if not self.authenticated():
                raise ApiError("AccessDenied", 403)
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.scheme or parsed.netloc or not parsed.path.startswith(f"/{VERSION}/"):
                raise ApiError("InvalidInput")
            if method == "GET":
                self.get_api(parsed)
            elif method == "POST":
                self.post_api(parsed)
            else:
                raise ApiError("InvalidAction")
        except ApiError as exc:
            self.refuse(exc.code, exc.status)

    def do_GET(self) -> None:
        """Route permitted zone listing and change-status operations."""
        self.dispatch("GET")

    def do_POST(self) -> None:
        """Route the one permitted synthetic TXT mutation endpoint."""
        self.dispatch("POST")

    def get_api(self, request: urllib.parse.SplitResult) -> None:
        """Return one local zone or a previously accepted synthetic change."""
        path = request.path
        if path == f"/{VERSION}/hostedzone":
            arguments = urllib.parse.parse_qs(request.query, keep_blank_values=True)
            if set(arguments) - {"maxitems"}:
                raise ApiError("InvalidInput")
            root = element("ListHostedZonesResponse")
            zones = child(root, "HostedZones")
            zone = child(zones, "HostedZone")
            child(zone, "Id", f"/hostedzone/{ZONE_ID}")
            child(zone, "Name", ZONE)
            child(zone, "CallerReference", "certbotbot-local-e2e")
            config = child(zone, "Config")
            child(config, "PrivateZone", "false")
            child(root, "IsTruncated", "false")
            child(root, "MaxItems", "1")
            self.receipt("hosted-zones=accepted")
            self.reply(200, xml_bytes(root))
            return
        if path.startswith(f"/{VERSION}/change/") and not request.query:
            change_id = path[len(f"/{VERSION}/change/"):]
            # Botocore percent-encodes the Route53 /change/ ID prefix
            # emitted by the actual service. Accept only that exact form
            # or the already supported bare ID, never arbitrary escapes.
            encoded_prefix = "%2Fchange%2F"
            if change_id.startswith(encoded_prefix):
                change_id = change_id[len(encoded_prefix):]
            if change_id not in self.server.changes:
                raise ApiError("NoSuchChange", 404)
            root = element("GetChangeResponse")
            self.change_info(child(root, "ChangeInfo"), change_id, "INSYNC")
            self.receipt("change-poll=accepted")
            self.reply(200, xml_bytes(root))
            return
        raise ApiError("InvalidAction")

    @staticmethod
    def change_info(root: ET.Element, change_id: str, state: str) -> None:
        """Emit deterministic change metadata sufficient for GetChange polling."""
        child(root, "Id", f"/change/{change_id}")
        child(root, "Status", state)
        child(root, "SubmittedAt", "2026-11-02T00:00:00Z")

    @staticmethod
    def parse_changes(raw: bytes) -> tuple[str, str, tuple[str, ...]]:
        """Validate one TXT operation in one authorized synthetic challenge name."""
        try:
            root = ET.fromstring(raw)
            if root.tag != tag("ChangeResourceRecordSetsRequest"):
                raise ValueError()
            records = root.findall(
                f"{tag('ChangeBatch')}/{tag('Changes')}/{tag('Change')}"
            )
            if len(records) != 1:
                raise ValueError()
            change = records[0]
            action = change.findtext(tag("Action"))
            item = change.find(tag("ResourceRecordSet"))
            if action not in ("UPSERT", "DELETE") or item is None:
                raise ValueError()
            name = (item.findtext(tag("Name")) or "").lower()
            record_type = item.findtext(tag("Type"))
            ttl = item.findtext(tag("TTL"))
            values = item.findall(
                f"{tag('ResourceRecords')}/{tag('ResourceRecord')}/{tag('Value')}"
            )
            if (not NAME_RE.fullmatch(name) or record_type != "TXT"
                    or not ttl or not ttl.isdecimal()
                    or not 0 < int(ttl) <= 300
                    or not 1 <= len(values) <= 10):
                raise ValueError()
            # Certbot's plugin uses undotted DNS names; normalize after
            # strict validation for consistent UPSERT and DELETE identity.
            name = name.removesuffix(".") + "."
            decoded: list[str] = []
            for value in values:
                quoted = value.text or ""
                if not quoted.startswith('"') or not quoted.endswith('"'):
                    raise ValueError()
                txt = quoted[1:-1]
                if not VALUE_RE.fullmatch(txt) or txt in decoded:
                    raise ValueError()
                decoded.append(txt)
            return action, name, tuple(decoded)
        except (ET.ParseError, ValueError, TypeError) as exc:
            raise ApiError("InvalidChangeBatch") from exc

    def post_api(self, request: urllib.parse.SplitResult) -> None:
        """Record a synthetic mutation; deliberately never update Pebble DNS."""
        # Botocore's ChangeResourceRecordSets RequestUri terminates with
        # "/rrset/". Requiring the exact modeled route avoids accidentally
        # accepting unrelated synthetic API paths.
        # Real Botocore encodes the native /hostedzone/ prefix from the
        # ListHostedZones Id into the {Id} URI parameter. Permit exactly
        # the expected bare-ID and encoded native-ID resource paths.
        allowed_paths = (
            f"/{VERSION}/hostedzone/{ZONE_ID}/rrset/",
            f"/{VERSION}/hostedzone/%2Fhostedzone%2F{ZONE_ID}/rrset/",
        )
        if request.path not in allowed_paths or request.query:
            raise ApiError("AccessDenied", 403)
        length = self.headers.get("Content-Length", "")
        if not length.isdecimal() or not 0 < int(length) <= MAX_BODY:
            raise ApiError("InvalidInput")
        action, name, values = self.parse_changes(self.rfile.read(int(length)))
        with self.server.lock:
            previous = self.server.records.get(name)
            if action == "DELETE" and previous != values:
                raise ApiError("InvalidChangeBatch")
            if action == "UPSERT":
                self.server.records[name] = values
            else:
                del self.server.records[name]
            change_id = f"CLOCAL{len(self.server.changes) + 1:06d}"
            self.server.changes.add(change_id)
        root = element("ChangeResourceRecordSetsResponse")
        self.change_info(child(root, "ChangeInfo"), change_id, "PENDING")
        self.receipt("rrset-change=accepted")
        self.reply(200, xml_bytes(root))


class ScopedServer(http.server.ThreadingHTTPServer):
    """Keep state isolated to this server instance and serialize mutations."""

    daemon_threads = True

    def __init__(self, address: tuple[str, int]):
        self.records: dict[str, tuple[str, ...]] = {}
        self.changes: set[str] = set()
        self.lock = threading.Lock()
        super().__init__(address, Route53Stub)


if __name__ == "__main__":
    ScopedServer(("0.0.0.0", 8056)).serve_forever(poll_interval=0.25)
