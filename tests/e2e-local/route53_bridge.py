#!/usr/bin/env python3
"""Isolated, deliberately small Route53 Query API bridge for Pebble DNS-01.

Only the synthetic e2e.test. hosted zone and its _acme-challenge TXT records
are supported.  Never use as an Internet-facing Route53 replacement.
"""

from __future__ import annotations

import base64
import datetime
import http.client
import http.server
import re
import threading
import urllib.parse
import xml.etree.ElementTree as ET

VERSION = "2013-04-01"
NS = "https://route53.amazonaws.com/doc/2013-04-01/"
ZONE = "e2e.test."
ZONE_ID = "ZLOCALONLY123456"
CHALLENGE_HOST = "challtestsrv"
CHALLENGE_PORT = 8055
ACCESS_KEY = "CBOTBOT_LOCAL_TEST_ACCESS_ONLY"
VALUE_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
NAME_RE = re.compile(r"^_acme-challenge(?:\.[a-z0-9-]+)*\.e2e\.test\.$")
MAX_BODY = 16384

ET.register_namespace("", NS)


def tag(name: str) -> str:
    return f"{{{NS}}}{name}"


def element(name: str, value: str | None = None) -> ET.Element:
    node = ET.Element(tag(name))
    if value is not None:
        node.text = value
    return node


def child(parent: ET.Element, name: str, value: str | None = None) -> ET.Element:
    node = ET.SubElement(parent, tag(name))
    if value is not None:
        node.text = value
    return node


def xml_bytes(root: ET.Element) -> bytes:
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


class ApiError(Exception):
    def __init__(self, code: str, status: int = 400):
        self.code = code
        self.status = status
        super().__init__(code)


class Route53Bridge(http.server.BaseHTTPRequestHandler):
    server_version = "LocalRoute53Bridge/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        # Do not log DNS values, credentials, request paths, or signed headers.
        pass

    def reply(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def error(self, reason: str, status: int = 400) -> None:
        root = element("ErrorResponse")
        error = child(root, "Error")
        child(error, "Type", "Sender")
        child(error, "Code", reason)
        child(error, "Message", "Local Route53 operation refused")
        child(root, "RequestId", "local-only")
        self.reply(status, xml_bytes(root))

    def authenticated(self) -> bool:
        # The signed key is a synthetic fixture. Signature cryptography is
        # deliberately not verified: the network boundary is mandatory.
        auth = self.headers.get("Authorization", "")
        return (auth.startswith("AWS4-HMAC-SHA256 ")
                and f"Credential={ACCESS_KEY}/" in auth)

    def dispatch(self, method: str) -> None:
        try:
            if not self.authenticated():
                raise ApiError("AccessDenied", 403)
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.scheme or parsed.netloc or not parsed.path.startswith(f"/{VERSION}/"):
                raise ApiError("InvalidInput")
            if method == "GET":
                self.handle_get(parsed)
            elif method == "POST":
                self.handle_post(parsed)
            else:
                raise ApiError("InvalidAction")
        except ApiError as exc:
            self.error(exc.code, exc.status)

    def do_GET(self) -> None:
        self.dispatch("GET")

    def do_POST(self) -> None:
        self.dispatch("POST")

    def handle_get(self, parsed: urllib.parse.SplitResult) -> None:
        path = parsed.path
        if path == f"/{VERSION}/hostedzonesbyname":
            qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            if set(qs) - {"dnsname", "maxitems", "hostedzoneid"}:
                raise ApiError("InvalidInput")
            requested = qs.get("dnsname", [ZONE])[0].lower()
            if requested not in (ZONE, ZONE[:-1]):
                raise ApiError("AccessDenied", 403)
            root = element("ListHostedZonesByNameResponse")
            child(root, "DNSName", ZONE)
            zones = child(root, "HostedZones")
            zone = child(zones, "HostedZone")
            child(zone, "Id", f"/hostedzone/{ZONE_ID}")
            child(zone, "Name", ZONE)
            child(zone, "CallerReference", "local-e2e")
            config = child(zone, "Config")
            child(config, "PrivateZone", "false")
            child(root, "IsTruncated", "false")
            child(root, "MaxItems", "1")
            self.reply(200, xml_bytes(root))
            return
        if path.startswith(f"/{VERSION}/change/"):
            change_id = path.removeprefix(f"/{VERSION}/change/")
            if change_id not in self.server.changes:
                raise ApiError("NoSuchChange", 404)
            root = element("GetChangeResponse")
            self.change_info(child(root, "ChangeInfo"), change_id, "INSYNC")
            self.reply(200, xml_bytes(root))
            return
        raise ApiError("InvalidAction")

    @staticmethod
    def change_info(root: ET.Element, change_id: str, status: str) -> None:
        child(root, "Id", f"/change/{change_id}")
        child(root, "Status", status)
        child(root, "SubmittedAt", "2026-11-02T00:00:00Z")

    @staticmethod
    def extract_change(raw: bytes) -> tuple[str, str, str]:
        try:
            root = ET.fromstring(raw)
            batch = root.find(tag("ChangeBatch"))
            if root.tag != tag("ChangeResourceRecordSetsRequest") or batch is None:
                raise ValueError()
            changes = batch.findall(f"{tag('Changes')}/{tag('Change')}")
            if len(changes) != 1:
                raise ValueError()
            change = changes[0]
            action = change.findtext(tag("Action"))
            record = change.find(tag("ResourceRecordSet"))
            if record is None or action not in ("UPSERT", "DELETE"):
                raise ValueError()
            name = record.findtext(tag("Name"), "").lower()
            rrtype = record.findtext(tag("Type"))
            ttl = record.findtext(tag("TTL"))
            values = record.findall(f"{tag('ResourceRecords')}/{tag('ResourceRecord')}/{tag('Value')}")
            if (not NAME_RE.fullmatch(name)
                    or rrtype != "TXT" or len(values) != 1
                    or not ttl or not ttl.isdecimal() or int(ttl) > 300):
                raise ValueError()
            quoted = values[0].text or ""
            if not (quoted.startswith('"') and quoted.endswith('"')):
                raise ValueError()
            value = quoted[1:-1]
            if not VALUE_RE.fullmatch(value):
                raise ValueError()
            return action, name, value
        except (ET.ParseError, ValueError, TypeError) as exc:
            raise ApiError("InvalidChangeBatch") from exc

    @staticmethod
    def update_challenge(action: str, name: str, value: str) -> None:
        data = urllib.parse.urlencode({"host": name, "value": value}).encode("ascii")
        if action == "DELETE":
            data = urllib.parse.urlencode({"host": name}).encode("ascii")
        conn = http.client.HTTPConnection(CHALLENGE_HOST, CHALLENGE_PORT, timeout=3)
        try:
            conn.request("POST", "/set-txt" if action == "UPSERT" else "/clear-txt",
                         body=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
            response = conn.getresponse()
            response.read(4096)
            if response.status != 200:
                raise ApiError("ServiceUnavailable", 503)
        except (OSError, TimeoutError, http.client.HTTPException) as exc:
            raise ApiError("ServiceUnavailable", 503) from exc
        finally:
            conn.close()

    def handle_post(self, parsed: urllib.parse.SplitResult) -> None:
        if parsed.path != f"/{VERSION}/hostedzone/{ZONE_ID}/rrset" or parsed.query:
            raise ApiError("AccessDenied", 403)
        size = self.headers.get("Content-Length", "")
        if not size.isdecimal() or not 0 < int(size) <= MAX_BODY:
            raise ApiError("InvalidInput")
        action, name, value = self.extract_change(self.rfile.read(int(size)))
        with self.server.lock:
            before = self.server.records.get(name)
            if action == "UPSERT" and before not in (None, value):
                raise ApiError("ConflictingChangeBatch")
            if action == "DELETE" and before != value:
                raise ApiError("InvalidChangeBatch")
            self.update_challenge(action, name, value)
            if action == "UPSERT":
                self.server.records[name] = value
            else:
                del self.server.records[name]
            change_id = f"CLOCAL{len(self.server.changes) + 1:06d}"
            self.server.changes.add(change_id)
        root = element("ChangeResourceRecordSetsResponse")
        self.change_info(child(root, "ChangeInfo"), change_id, "PENDING")
        self.reply(200, xml_bytes(root))


class ScopedServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int]):
        self.records: dict[str, str] = {}
        self.changes: set[str] = set()
        self.lock = threading.Lock()
        super().__init__(address, Route53Bridge)


if __name__ == "__main__":
    server = ScopedServer(("0.0.0.0", 8056))
    server.serve_forever(poll_interval=0.25)
