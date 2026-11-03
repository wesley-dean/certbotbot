#!/usr/bin/env python3
"""Black-box local Route53 stub contract tests, with no AWS or DNS client."""

from __future__ import annotations

import http.client
import threading
import unittest
import xml.etree.ElementTree as ET

import route53_bridge as bridge

GOOD_AUTH = (
    "AWS4-HMAC-SHA256 "
    "Credential=CBOTBOT_LOCAL_TEST_ACCESS_ONLY/20261102/us-east-1/route53/aws4_request, "
    "SignedHeaders=host, Signature=synthetic"
)
TXT = "A" * 43
OTHER_TXT = "B" * 43
DOMAIN = "_acme-challenge.www.e2e.test."


def change_xml(
    action: str = "UPSERT",
    name: str = DOMAIN,
    values: tuple[str, ...] = (TXT,),
    record_type: str = "TXT",
) -> bytes:
    """Construct the minimal shape of a Certbot Route53 Query API change."""
    root = bridge.element("ChangeResourceRecordSetsRequest")
    batch = bridge.child(root, "ChangeBatch")
    changes = bridge.child(batch, "Changes")
    item = bridge.child(changes, "Change")
    bridge.child(item, "Action", action)
    record = bridge.child(item, "ResourceRecordSet")
    bridge.child(record, "Name", name)
    bridge.child(record, "Type", record_type)
    bridge.child(record, "TTL", "10")
    resource_records = bridge.child(record, "ResourceRecords")
    for value in values:
        rr = bridge.child(resource_records, "ResourceRecord")
        bridge.child(rr, "Value", f'"{value}"')
    return bridge.xml_bytes(root)


class Route53StubTests(unittest.TestCase):
    """Drive actual HTTP requests through a loopback-only synthetic server."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = bridge.ScopedServer(("127.0.0.1", 0))
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=3)

    def setUp(self) -> None:
        with self.server.lock:
            self.server.records.clear()
            self.server.changes.clear()

    def request(
        self, method: str, path: str, payload: bytes = b"",
        authorization: str = GOOD_AUTH,
    ) -> tuple[int, ET.Element]:
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_port, timeout=3
        )
        try:
            connection.request(
                method,
                path,
                body=payload,
                headers={
                    "Authorization": authorization,
                    "Content-Length": str(len(payload)),
                    "Content-Type": "application/xml",
                },
            )
            result = connection.getresponse()
            return result.status, ET.fromstring(result.read())
        finally:
            connection.close()

    def test_one_synthetic_zone_and_no_name_lookup(self) -> None:
        status, root = self.request("GET", "/2013-04-01/hostedzone")
        self.assertEqual(status, 200)
        self.assertEqual(
            root.findtext(f".//{bridge.tag('Id')}"),
            f"/hostedzone/{bridge.ZONE_ID}",
        )
        self.assertEqual(root.findtext(f".//{bridge.tag('Name')}"), bridge.ZONE)

        # Name lookup is a separately requested enhancement (#252).
        status, _ = self.request(
            "GET", "/2013-04-01/hostedzonesbyname?dnsname=e2e.test."
        )
        self.assertNotEqual(status, 200)

    def test_denied_credentials_and_unrecognized_apis(self) -> None:
        attempts = [
            ("GET", "/2013-04-01/hostedzone", ""),
            ("GET", "/2013-04-01/hostedzone", "AWS4-HMAC-SHA256 Credential=REAL/"),
            ("GET", "/2013-04-01/hostedzone?marker=untrusted", GOOD_AUTH),
            ("GET", "/2013-04-01/hostedzone/ZOTHER", GOOD_AUTH),
            ("GET", "/2013-04-01/change/CFAKE", GOOD_AUTH),
        ]
        for method, path, auth in attempts:
            with self.subTest(path=path, auth=bool(auth)):
                status, _ = self.request(method, path, authorization=auth)
                self.assertNotEqual(status, 200)

    def test_upsert_change_poll_and_exact_cleanup(self) -> None:
        path = f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset"
        status, root = self.request("POST", path, change_xml())
        self.assertEqual(status, 200)
        self.assertEqual(self.server.records[DOMAIN], (TXT,))
        change_id = root.findtext(f".//{bridge.tag('Id')}")
        self.assertTrue(change_id.startswith("/change/CLOCAL"))

        status, polling = self.request("GET", "/2013-04-01" + change_id)
        self.assertEqual(status, 200)
        self.assertEqual(
            polling.findtext(f".//{bridge.tag('Status')}"), "INSYNC"
        )

        status, _ = self.request("POST", path, change_xml(action="DELETE"))
        self.assertEqual(status, 200)
        self.assertNotIn(DOMAIN, self.server.records)

    def test_multiple_values_do_not_require_real_dns(self) -> None:
        path = f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset"
        values = (TXT, OTHER_TXT)
        status, _ = self.request("POST", path, change_xml(values=values))
        self.assertEqual(status, 200)
        self.assertEqual(self.server.records[DOMAIN], values)
        status, _ = self.request(
            "POST", path, change_xml(action="DELETE", values=values)
        )
        self.assertEqual(status, 200)
        self.assertNotIn(DOMAIN, self.server.records)

    def test_unauthorized_zone_name_type_and_malformed_values(self) -> None:
        valid_path = f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset"
        attempts = [
            ("/2013-04-01/hostedzone/ZOTHER/rrset", change_xml()),
            (valid_path, change_xml(name="_acme-challenge.example.org.")),
            (valid_path, change_xml(name="www.e2e.test.")),
            (valid_path, change_xml(record_type="A")),
            (valid_path, change_xml(values=("wrong",))),
            (valid_path, change_xml(values=(TXT, TXT))),
            (valid_path, b"not xml"),
        ]
        for path, payload in attempts:
            with self.subTest(path=path, payload_length=len(payload)):
                status, _ = self.request("POST", path, payload)
                self.assertNotEqual(status, 200)
        self.assertFalse(self.server.records)

    def test_failed_cleanup_does_not_mutate_existing_record(self) -> None:
        path = f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset"
        status, _ = self.request("POST", path, change_xml())
        self.assertEqual(status, 200)
        status, _ = self.request(
            "POST", path, change_xml(action="DELETE", values=(OTHER_TXT,))
        )
        self.assertNotEqual(status, 200)
        self.assertEqual(self.server.records[DOMAIN], (TXT,))


if __name__ == "__main__":
    unittest.main()
