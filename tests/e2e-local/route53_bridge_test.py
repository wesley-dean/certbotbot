#!/usr/bin/env python3
"""Offline contract tests for the container-only Route53 DNS-01 bridge."""

import contextlib
import http.client
import http.server
import threading
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET

import route53_bridge as bridge

GOOD_AUTH = "AWS4-HMAC-SHA256 Credential=CBOTBOT_LOCAL_TEST_ACCESS_ONLY/20261102/us-east-1/route53/aws4_request, SignedHeaders=host, Signature=fixture"
TXT = "A" * 43
DOMAIN = "_acme-challenge.www.e2e.test."


def change_xml(action="UPSERT", name=DOMAIN, value=TXT, record_type="TXT"):
    root = bridge.element("ChangeResourceRecordSetsRequest")
    batch = bridge.child(root, "ChangeBatch")
    changes = bridge.child(batch, "Changes")
    item = bridge.child(changes, "Change")
    bridge.child(item, "Action", action)
    record = bridge.child(item, "ResourceRecordSet")
    bridge.child(record, "Name", name)
    bridge.child(record, "Type", record_type)
    bridge.child(record, "TTL", "10")
    values = bridge.child(record, "ResourceRecords")
    rr = bridge.child(values, "ResourceRecord")
    bridge.child(rr, "Value", f'"{value}"')
    return bridge.xml_bytes(root)


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = bridge.ScopedServer(("127.0.0.1", 0))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=3)

    def setUp(self):
        self.server.records.clear()
        self.server.changes.clear()

    def request(self, method, path, body=b"", auth=GOOD_AUTH):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            conn.request(method, path, body=body, headers={
                "Authorization": auth,
                "Content-Length": str(len(body)),
                "Content-Type": "application/xml",
            })
            response = conn.getresponse()
            status, data = response.status, response.read()
            return status, ET.fromstring(data)
        finally:
            conn.close()

    def test_list_only_allowed_zone(self):
        status, root = self.request("GET", "/2013-04-01/hostedzonesbyname?dnsname=e2e.test.")
        self.assertEqual(status, 200)
        self.assertEqual(root.findtext(f".//{bridge.tag('Id')}"), "/hostedzone/" + bridge.ZONE_ID)
        status, _ = self.request("GET", "/2013-04-01/hostedzonesbyname?dnsname=example.com.")
        self.assertEqual(status, 403)

    def test_authentication_and_unknown_actions_fail_closed(self):
        for method, path, auth in [
            ("GET", "/2013-04-01/hostedzonesbyname", ""),
            ("GET", "/2013-04-01/hostedzonesbyname", "AWS4-HMAC-SHA256 Credential=REAL/"),
            ("GET", "/2013-04-01/hostedzone", GOOD_AUTH),
            ("GET", "/2013-04-01/hostedzone/ZREAL/rrset", GOOD_AUTH),
        ]:
            with self.subTest(method=method, path=path, auth=bool(auth)):
                status, _ = self.request(method, path, auth=auth)
                self.assertNotEqual(status, 200)

    def test_txt_lifecycle_and_polls(self):
        operations = []
        with patch.object(bridge.Route53Bridge, "update_challenge",
                          side_effect=lambda *args: operations.append(args)):
            status, root = self.request(
                "POST", f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset", change_xml())
            self.assertEqual(status, 200)
            self.assertEqual(self.server.records[DOMAIN], TXT)
            change_id = root.findtext(f".//{bridge.tag('Id')}")
            self.assertTrue(change_id.startswith("/change/CLOCAL"))
            status, result = self.request("GET", "/2013-04-01" + change_id)
            self.assertEqual(status, 200)
            self.assertEqual(result.findtext(f".//{bridge.tag('Status')}"), "INSYNC")
            status, _ = self.request(
                "POST", f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset",
                change_xml("DELETE"))
            self.assertEqual(status, 200)
            self.assertNotIn(DOMAIN, self.server.records)
        self.assertEqual(operations, [("UPSERT", DOMAIN, TXT), ("DELETE", DOMAIN, TXT)])

    def test_rejects_conflicts_and_out_of_zone_mutation(self):
        with patch.object(bridge.Route53Bridge, "update_challenge"):
            status, _ = self.request(
                "POST", f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset", change_xml())
            self.assertEqual(status, 200)
            for action, name, value in [
                ("UPSERT", DOMAIN, "B" * 43),
                ("DELETE", DOMAIN, "B" * 43),
                ("UPSERT", "_acme-challenge.example.org.", TXT),
                ("UPSERT", "www.e2e.test.", TXT),
            ]:
                with self.subTest(action=action, name=name):
                    status, _ = self.request(
                        "POST", f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset",
                        change_xml(action, name, value))
                    self.assertNotEqual(status, 200)
            self.assertEqual(self.server.records[DOMAIN], TXT)

    def test_challenge_server_failure_cannot_change_local_state(self):
        with patch.object(bridge.Route53Bridge, "update_challenge",
                          side_effect=bridge.ApiError("ServiceUnavailable", 503)):
            status, _ = self.request(
                "POST", f"/2013-04-01/hostedzone/{bridge.ZONE_ID}/rrset", change_xml())
            self.assertEqual(status, 503)
            self.assertFalse(self.server.records)
            self.assertFalse(self.server.changes)


if __name__ == "__main__":
    unittest.main()
