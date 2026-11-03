#!/usr/bin/env python3
"""Test-only Route53 XML API bridge for Pebble DNS-01 (ADR-046 / #243).

No third-party Python modules are used by the service. It accepts only the
fixture Route53 SigV4 identity, a single synthetic zone, and TXT mutations
needed by the real certbot-dns-route53 plugin. All challenge management
traffic goes to one compile-time internal Docker address, without proxies.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import http.client
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, quote, unquote, urlsplit
from xml.etree import ElementTree as ET

NS = 'https://route53.amazonaws.com/doc/2013-04-01/'
PREFIX = '/2013-04-01'
ZONE = 'e2e.invalid.'
ZONE_ID = 'ZLOCALONLY0001'
ACCESS_KEY = 'CBOTBOT_LOCAL_TEST_ACCESS_ONLY'
SECRET = 'CBOTBOT_LOCAL_TEST_SECRET_NOT_A_CLOUD_KEY'
BRIDGE_IP = '172.31.248.6'
BRIDGE_PORT = 8056
CHALL_IP = '172.31.248.3'
CHALL_PORT = 8055
MAX_BODY = 8192
HOST_RE = re.compile(
    r'^_acme-challenge(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?){0,2}\.e2e\.invalid\.$'
)
VALUE_RE = re.compile(r'^"([a-zA-Z0-9_-]{32,128})"$')
AUTH_RE = re.compile(
    r'^AWS4-HMAC-SHA256 Credential=([^/, ]+)/(\d{8})/([^/, ]+)/route53/aws4_request, '
    r'SignedHeaders=([a-z0-9;-]+), Signature=([0-9a-f]{64})$'
)
ET.register_namespace('', NS)


def node(parent: ET.Element, tag: str, value: str | None = None) -> ET.Element:
    """Append one namespaced Route53 response element."""
    result = ET.SubElement(parent, f'{{{NS}}}{tag}')
    if value is not None:
        result.text = value
    return result


def document(tag: str) -> ET.Element:
    """Construct a namespaced Route53 response root."""
    return ET.Element(f'{{{NS}}}{tag}')


def xml_bytes(root: ET.Element) -> bytes:
    """Serialize XML using the AWS Route53 protocol namespace."""
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def child_text(parent: ET.Element, name: str) -> str:
    """Read a mandatory nonempty child without accepting foreign namespaces."""
    result = parent.find(f'{{{NS}}}{name}')
    if result is None or result.text is None:
        raise ValueError('missing XML field')
    return result.text


def xml_child(parent: ET.Element, name: str) -> ET.Element:
    """Read a mandatory XML child in the expected Route53 namespace."""
    result = parent.find(f'{{{NS}}}{name}')
    if result is None:
        raise ValueError('missing XML element')
    return result


def sigv4_valid(method: str, target: str, headers, body: bytes) -> bool:
    """Verify the one synthetic Route53 AWS SigV4 identity.

    Deliberately rejects presigned query authentication, SigV4a, streaming
    unsigned bodies, foreign regions, and stale timestamps.
    """
    match = AUTH_RE.fullmatch(headers.get('Authorization', ''))
    if not match:
        return False
    key, date, region, signed_list, received = match.groups()
    if key != ACCESS_KEY or region != 'us-east-1':
        return False
    signed = signed_list.split(';')
    if signed != sorted(set(signed)) or 'host' not in signed or 'x-amz-date' not in signed:
        return False
    timestamp = headers.get('X-Amz-Date', '')
    try:
        observed = dt.datetime.strptime(
            timestamp, '%Y%m%dT%H%M%SZ'
        ).replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return False
    if observed.strftime('%Y%m%d') != date:
        return False
    if abs((dt.datetime.now(dt.timezone.utc) - observed).total_seconds()) > 300:
        return False
    if headers.get('Host', '') == '':
        return False
    payload_hash = hashlib.sha256(body).hexdigest()
    claimed_hash = headers.get('X-Amz-Content-Sha256')
    if claimed_hash and claimed_hash != payload_hash:
        return False
    parts = urlsplit(target)
    if parts.scheme or parts.netloc or parts.fragment:
        return False
    # Fixed ASCII API paths only; no traversal or ambiguous encodings.
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+', parts.path):
        return False
    canonical_path = quote(unquote(parts.path), safe='/-_.~')
    query = parse_qsl(parts.query, keep_blank_values=True)
    canonical_query = '&'.join(
        f'{quote(k, safe="-_.~")}={quote(v, safe="-_.~")}'
        for k, v in sorted(query)
    )
    canonical_headers = []
    for name in signed:
        value = headers.get(name)
        if value is None:
            return False
        canonical_headers.append(f'{name}:{" ".join(value.strip().split())}\n')
    request_hash = hashlib.sha256(('\n'.join((
        method, canonical_path, canonical_query, ''.join(canonical_headers),
        signed_list, payload_hash
    ))).encode()).hexdigest()
    scope = f'{date}/{region}/route53/aws4_request'
    to_sign = f'AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{request_hash}'
    k = ('AWS4' + SECRET).encode()
    for part in (date, region, 'route53', 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    calculated = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(calculated, received)


class ChallengeServer:
    """Reach only Pebble's fixed internal DNS challenge-management API."""

    def __init__(self, ip: str = CHALL_IP, port: int = CHALL_PORT):
        self.ip, self.port = ip, port

    def post(self, action: str, obj: dict[str, str]) -> None:
        if action not in ('set-txt', 'clear-txt', 'dns-request-history'):
            raise ValueError('unapproved challenge operation')
        connection = http.client.HTTPConnection(self.ip, self.port, timeout=3)
        try:
            connection.request(
                'POST', f'/{action}', body=json.dumps(obj).encode(),
                headers={'Content-Type': 'application/json'}
            )
            response = connection.getresponse()
            response.read(1024)
            if response.status != 200:
                raise OSError('Pebble challenge management rejected operation')
        finally:
            connection.close()


class State:
    """Serialize changes and retain one synthetic zone's in-memory TXT data."""

    def __init__(self, challenge: ChallengeServer):
        self.challenge = challenge
        self.lock = threading.Lock()
        self.records: dict[str, tuple[str, ...]] = {}
        self.changes: set[str] = set()
        self.sequence = 0
        self.tainted = False

    def healthy(self) -> bool:
        self.challenge.post(
            'dns-request-history', {'host': '_acme-challenge.e2e.invalid.'}
        )
        return not self.tainted

    def change(self, action: str, name: str, values: tuple[str, ...]) -> str:
        with self.lock:
            if self.tainted or len(self.changes) >= 1000:
                raise RuntimeError('bridge state unavailable')
            before = self.records.get(name, ())
            if action == 'DELETE':
                if before != values:
                    raise ValueError('record set does not match existing TXT')
                after: tuple[str, ...] = ()
            elif action == 'UPSERT':
                after = values
            else:
                raise ValueError('unsupported change action')

            # Pebble's management API is not atomic. Stop further changes on
            # partial failure instead of incorrectly reporting INSYNC.
            try:
                self.challenge.post('clear-txt', {'host': name})
                for value in after:
                    self.challenge.post(
                        'set-txt', {'host': name, 'value': value}
                    )
            except (OSError, ValueError) as exc:
                self.tainted = True
                raise RuntimeError('DNS update did not complete') from exc
            if after:
                self.records[name] = after
            else:
                self.records.pop(name, None)
            self.sequence += 1
            change_id = f'CLOCAL{self.sequence:08d}'
            self.changes.add(change_id)
            return change_id


class Handler(BaseHTTPRequestHandler):
    """Strict Route53 XML responder with verified synthetic SigV4."""

    server_version = 'LocalRoute53/1'
    sys_version = ''

    def log_message(self, *_args) -> None:
        # Never put challenges, credentials, signed URLs, or bodies in logs.
        return

    def send_xml(self, code: int, root: ET.Element) -> None:
        data = xml_bytes(root)
        self.send_response(code)
        self.send_header('Content-Type', 'text/xml')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def error_xml(self, code: int, name: str) -> None:
        root = document('ErrorResponse')
        err = node(root, 'Error')
        node(err, 'Type', 'Sender' if code < 500 else 'Receiver')
        node(err, 'Code', name)
        node(err, 'Message', 'Rejected by isolated local Route53 bridge')
        node(root, 'RequestId', 'local')
        self.send_xml(code, root)

    def handle_request(self, method: str) -> None:
        if self.headers.get('Host') != self.server.expected_host:
            self.error_xml(403, 'AccessDenied')
            return
        if method == 'GET' and self.path == '/health':
            try:
                if not self.server.state.healthy():
                    raise RuntimeError('bridge state tainted')
            except (OSError, RuntimeError):
                self.error_xml(503, 'ServiceUnavailable')
                return
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self.error_xml(400, 'InvalidInput')
            return
        if length < 0 or length > MAX_BODY or (method == 'GET' and length != 0):
            self.error_xml(400, 'InvalidInput')
            return
        body = self.rfile.read(length) if method == 'POST' else b''
        if not sigv4_valid(method, self.path, self.headers, body):
            self.error_xml(403, 'AccessDenied')
            return
        try:
            if method == 'GET' and self.path == PREFIX + '/hostedzone':
                self.list_zones()
            elif method == 'GET' and re.fullmatch(
                PREFIX + r'/change/CLOCAL\d{8}', self.path
            ):
                self.get_change(self.path.rsplit('/', 1)[-1])
            elif method == 'POST' and self.path == (
                f'{PREFIX}/hostedzone/{ZONE_ID}/rrset/'
            ):
                self.change_records(body)
            else:
                self.error_xml(400, 'InvalidInput')
        except ValueError:
            self.error_xml(400, 'InvalidChangeBatch')
        except (OSError, RuntimeError):
            self.error_xml(503, 'ServiceUnavailable')

    def do_GET(self):
        self.handle_request('GET')

    def do_POST(self):
        self.handle_request('POST')

    def list_zones(self) -> None:
        root = document('ListHostedZonesResponse')
        zones = node(root, 'HostedZones')
        zone = node(zones, 'HostedZone')
        node(zone, 'Id', f'/hostedzone/{ZONE_ID}')
        node(zone, 'Name', ZONE)
        node(zone, 'CallerReference', 'local-e2e-only')
        config = node(zone, 'Config')
        node(config, 'PrivateZone', 'false')
        node(root, 'Marker', '')
        node(root, 'IsTruncated', 'false')
        node(root, 'MaxItems', '100')
        self.send_xml(200, root)

    def get_change(self, change_id: str) -> None:
        if change_id not in self.server.state.changes:
            self.error_xml(404, 'NoSuchChange')
            return
        root = document('GetChangeResponse')
        info = node(root, 'ChangeInfo')
        node(info, 'Id', f'/change/{change_id}')
        node(info, 'Status', 'INSYNC')
        node(info, 'SubmittedAt', dt.datetime.now(
            dt.timezone.utc
        ).isoformat().replace('+00:00', 'Z'))
        self.send_xml(200, root)

    def change_records(self, body: bytes) -> None:
        if not body or b'<!DOCTYPE' in body.upper() or b'<!ENTITY' in body.upper():
            raise ValueError('invalid XML')
        try:
            xml = ET.fromstring(body)
        except ET.ParseError as exc:
            raise ValueError('invalid XML') from exc
        if xml.tag != f'{{{NS}}}ChangeResourceRecordSetsRequest':
            raise ValueError('unexpected XML namespace')
        batch = xml_child(xml, 'ChangeBatch')
        changes = xml_child(batch, 'Changes').findall(f'{{{NS}}}Change')
        if len(changes) != 1:
            raise ValueError('one change only')
        change = changes[0]
        action = child_text(change, 'Action')
        rrset = xml_child(change, 'ResourceRecordSet')
        name = child_text(rrset, 'Name').lower().rstrip('.') + '.'
        if not HOST_RE.fullmatch(name) or child_text(rrset, 'Type') != 'TXT':
            raise ValueError('zone/record out of bounds')
        if child_text(rrset, 'TTL') != '10':
            raise ValueError('unexpected TTL')
        values = []
        for record in xml_child(
            rrset, 'ResourceRecords'
        ).findall(f'{{{NS}}}ResourceRecord'):
            value = child_text(record, 'Value')
            match = VALUE_RE.fullmatch(value)
            if match is None:
                raise ValueError('invalid TXT value')
            values.append(match.group(1))
        if not values or len(values) > 16 or len(set(values)) != len(values):
            raise ValueError('invalid TXT set')
        change_id = self.server.state.change(action, name, tuple(sorted(values)))
        root = document('ChangeResourceRecordSetsResponse')
        info = node(root, 'ChangeInfo')
        node(info, 'Id', f'/change/{change_id}')
        node(info, 'Status', 'INSYNC')
        node(info, 'SubmittedAt', dt.datetime.now(
            dt.timezone.utc
        ).isoformat().replace('+00:00', 'Z'))
        self.send_xml(200, root)


def main() -> None:
    """Listen only in the private container topology configured by Compose."""
    state = State(ChallengeServer())
    server = ThreadingHTTPServer(('0.0.0.0', BRIDGE_PORT), Handler)
    server.state = state
    server.expected_host = f'{BRIDGE_IP}:{BRIDGE_PORT}'
    server.serve_forever(poll_interval=0.3)


if __name__ == '__main__':
    main()
