#!/usr/bin/env python3
"""Offline regression tests; all network/firewall/ubus commands are mocked.

Run: python3 scripts/test-ipv6-maint.py
Uses the repository's actual OpenWrt config helpers, with fixture config loading.
Does not validate nft syntax against a kernel or replace on-router smoke testing.
"""

import fcntl
import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "files/usr/bin/ipv6-maint.sh"
SHELL = shutil.which("dash") or "/bin/sh"
SOURCE = SCRIPT.read_text()
FUNCTIONS = SOURCE.removesuffix('main "$@"\n')
assert FUNCTIONS != SOURCE

MOCK = r'''
import fcntl, json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls").open("a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
if name == "flock":
    try:
        fcntl.flock(int(args[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(1)
elif name == "ip":
    if os.environ.get("FAIL_IP") and os.environ["FAIL_IP"] in " ".join(args):
        sys.exit(1)
    key = None
    if args[:3] == ["-6", "addr", "show"]:
        key = "wan" if args[4] == "modem0" else "lan"
    elif args[:3] == ["-6", "route", "show"]:
        key = "routes"
    elif args[1:3] == ["neigh", "show"]:
        key = "ndp" if args[0] == "-6" else "arp"
    if key:
        sys.stdout.write((root / key).read_text())
elif name == "nft":
    if args == ["-a", "list", "table", "inet", "fw4"]:
        if os.environ.get("FAIL_FW4"):
            sys.exit(1)
        sys.stdout.write((root / "fw4").read_text())
    elif args[0] == "-f":
        batch = pathlib.Path(args[1]).read_text()
        (root / "attempt").write_text(batch)
        if os.environ.get("FAIL_NFT"):
            print("mock transaction failure", file=sys.stderr)
            sys.exit(1)
        (root / "applied").write_text(batch)
    else:
        raise RuntimeError("unexpected nft invocation: " + repr(args))
elif name == "ubus":
    if args[-2:] == ["network.interface", "dump"]:
        if os.environ.get("FAIL_NETIFD"):
            sys.exit(1)
        print('{"interface": []}')
    else:
        sys.stdout.write((root / "leases.json").read_text())
elif name == "logger":
    with (root / "logs").open("a") as stream:
        stream.write(" ".join(args) + "\n")
else:
    raise RuntimeError(name)
'''

NETWORK = '''
network_find_wan6() { export "$1=auto6"; }
network_find_wan() { export "$1=uplink"; }
network_get_device() {
    case "$2" in
        auto6|uplink) export "$1=modem0" ;;
        inside) export "$1=switch0" ;;
        *) return 1 ;;
    esac
}
network_get_ipaddrs() { export "$1=192.0.2.1 192.0.2.2"; }
'''

# JSON traversal is a shell fixture. The production script still traverses the
# same nested device/lease/address shape and preserves parent-child association.
JSON_HELPERS = r'''
json_load() { JSON_PATH=; }
json_select() {
    local next
    case "$1" in
        ..) next=${JSON_PATH%/*} ;;
        *) next="$JSON_PATH/$1" ;;
    esac
    "$FIXTURE/json-query" exists "$next" || return 1
    JSON_PATH=$next
}
json_get_keys() {
    local result
    result=$("$FIXTURE/json-query" keys "$JSON_PATH")
    export "$1=$result"
}
json_get_var() {
    local result
    result=$("$FIXTURE/json-query" value "$JSON_PATH/$2")
    export "$1=$result"
}
'''
JSON_QUERY = r'''
import json, os, pathlib, sys
obj = json.loads((pathlib.Path(os.environ["FIXTURE"]) / "leases.json").read_text())
try:
    for key in sys.argv[2].split("/"):
        if key:
            obj = obj[int(key)] if isinstance(obj, list) else obj[key]
except (KeyError, ValueError, IndexError, TypeError):
    sys.exit(1)
if sys.argv[1] == "keys":
    print(" ".join(map(str, range(len(obj)) if isinstance(obj, list) else obj)))
elif sys.argv[1] == "value":
    print(obj)
'''


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-ipv6-maint-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FIXTURE": str(self.root),
            "STATE_DIR": str(self.state),
            "LAN_NETWORK": "inside",
        }
        for key in ("WAN_IF", "WAN_NETWORK", "LAN_IF", "ROUTE_METRIC"):
            self.env.pop(key, None)
        for name in ("ip", "nft", "ubus", "logger", "flock"):
            self.executable(self.bin / name, MOCK)
        self.executable(self.root / "json-query", JSON_QUERY)
        (self.root / "functions").write_text(FUNCTIONS)
        helpers = (ROOT / "package/base-files/files/lib/functions.sh").read_text()
        # dash lacks ash's export -n; export fixture config variables instead.
        helpers += '\nNO_EXPORT=\nconfig_load() { CONFIG_SECTIONS=; . "$FIXTURE/$1.config"; }\n'
        (self.root / "config-lib").write_text(helpers)
        (self.root / "network-lib").write_text(NETWORK)
        (self.root / "json-lib").write_text(JSON_HELPERS)
        adapted = SOURCE
        for old, new in (("/lib/functions.sh", "config-lib"),
                         ("/lib/functions/network.sh", "network-lib"),
                         ("/usr/share/libubox/jshn.sh", "json-lib")):
            adapted = adapted.replace(f". {old}\n", f'. "$FIXTURE/{new}"\n')
        (self.root / "main").write_text(adapted)
        self.files = {
            "wan": "inet6 2001:db8::1234/64 scope global dynamic\n",
            "lan": "",
            "routes": "",
            "arp": "192.0.2.10 lladdr 00:11:22:33:44:55 REACHABLE\n",
            "ndp": "2001:db8::211:22ff:fe33:4455 lladdr 00:11:22:33:44:55 STALE\n",
            "fw4": 'table inet fw4 {\n chain forward_old {\n  accept comment "ipv6-maint" # handle 42\n  accept comment "other-ipv6-maint" # handle 43\n }\n}\n',
            "leases.json": '{"device":{"switch0":{"leases":[]}}}',
            "dhcp.config": "config dnsmasq resolver\noption leasefile /nonexistent-ipv6-maint-test\n",
        }
        self.redirect = {"src": "outside-net", "dest": "inside-net", "dest_ip": "192.0.2.10",
                         "src_dport": "8080", "dest_port": "80", "proto": "tcp udp", "name": "web"}
        self.firewall()
        self.sync()

    def executable(self, path, content):
        path.write_text(f"#!{sys.executable}\n" + content)
        path.chmod(0o755)

    def sync(self):
        for name, value in self.files.items():
            (self.root / name).write_text(value)

    def firewall(self, redirects=None):
        sections = [("zone", "outside", {"name": "outside-net", "network": "uplink"}),
                    ("zone", "inside", {"name": "inside-net", "network": "inside"})]
        sections += [("redirect", f"rule{i}", rule)
                     for i, rule in enumerate(redirects or [self.redirect])]
        lines = []
        for kind, section, options in sections:
            lines.append(f"config {kind} {section}")
            lines.extend(f"option {key} {shlex.quote(value)}" for key, value in options.items())
        self.files["firewall.config"] = "\n".join(lines) + "\n"

    def function(self, code, text="", **env):
        return subprocess.run([SHELL, "-c", '. "$FIXTURE/functions"; ' + code],
                              input=text, text=True, capture_output=True,
                              env={**self.env, **env}, timeout=15)

    def run_main(self, *args, **env):
        self.sync()
        return subprocess.run([SHELL, str(self.root / "main"), *args], text=True,
                              capture_output=True, env={**self.env, **env}, timeout=20)

    def calls(self, name):
        return [item for line in (self.root / "calls").read_text().splitlines()
                if (item := json.loads(line))[0] == name]

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def lease(self, duid, address="2001:db8::99", preferred=100, valid=200):
        self.files["leases.json"] = json.dumps({"device": {"switch0": {"leases": [
            {"ipv6-addr": [{"address": address, "preferred-lifetime": preferred,
                             "valid-lifetime": valid}], "duid": duid}]}}})


class AddressTests(Fixture):
    def test_compressed_prefixes(self):
        for address in ("2001:db8::1234", "2001:0DB8:0:1::1234", "2a00::1", "3000:1::9"):
            with self.subTest(address=address):
                result = self.function("ipv6_records wan", f"inet6 {address}/64 scope global\n")
                self.assert_ok(result)
                self.assertEqual(result.stdout.strip(), ":".join(ipaddress.IPv6Address(address).exploded.split(":")[:4]))

    def test_skip_unusable_wan_addresses(self):
        text = "\n".join(f"inet6 {addr}/64 scope global {flag}" for addr, flag in
                         [("fd00::1", ""), ("2001:db8:1::1", "tentative"),
                          ("2001:db8:2::1", "deprecated"), ("2001:db8:3::1", "dadfailed"),
                          ("2001:db8::8", "")])
        self.assertEqual(self.function("ipv6_records wan", text).stdout.strip(), "2001:0db8:0000:0000")

    def test_eui64_vectors(self):
        for mac, expected in [("00:11:22:33:44:55", "0211:22ff:fe33:4455"),
                              ("02:00:00:00:00:01", "0000:00ff:fe00:0001"),
                              ("ff:ff:ff:ff:ff:ff", "fdff:ffff:feff:ffff")]:
            self.assertEqual(self.function(f"eui64_of {mac}").stdout.strip(), expected)

    def test_neighbors_exclude_failed_and_wrong_prefix(self):
        data = "\n".join([
            "2001:DB8::211:22ff:fe33:4455 lladdr 00:11:22:33:44:55 STALE",
            "2001:db8::9 lladdr 00:11:22:33:44:55 FAILED",
            "2001:db8:0:1::8 lladdr 00:11:22:33:44:55 REACHABLE",
            "2001:db8::8 INCOMPLETE"])
        result = self.function("PFX=2001:0db8:0000:0000; ipv6_records neighbors", data)
        self.assertEqual(result.stdout.splitlines(), ["00:11:22:33:44:55 2001:0db8:0000:0000:0211:22ff:fe33:4455"])

    def test_poison_route_scope(self):
        data = "\n".join(["2001:db8:0:1::2 dev modem0", "2001:db8:0:1::3/128 dev modem0",
                          "2001:db8:0:10::2/128 dev modem0", "2001:db8:0:1::/64 dev modem0",
                          "2001:db8:0:1::/80 dev modem0", "2001:db8:0:1::8 via fe80::1"])
        (self.root / "neighbors").write_text("00:11:22:33:44:55 2001:0db8:0000:0001:0000:0000:0000:0002\n")
        (self.root / "leases").write_text("00:11:22:33:44:55 2001:0db8:0000:0001:0000:0000:0000:0003\n")
        data += "\n2001:db8:0:1::4/128 dev modem0\n2001:db8:0:1::2/128 proto kernel metric 256\n"
        result = self.function("WORK=$FIXTURE; PFX=2001:0db8:0000:0001; ipv6_records routes", data)
        self.assert_ok(result)
        self.assertEqual(result.stdout.splitlines(), ["2001:db8:0:1::2", "2001:db8:0:1::3/128"])

    def test_duid_ll_and_llt(self):
        for duid in ("00030001001122334455", "0001000112345678001122334455"):
            # LLT uses four timestamp bytes, then six MAC bytes (28 hex chars).
            result = self.function("PFX=2001:0db8:0000:0000; ipv6_records leases", duid + " 2001:db8::9\n")
            self.assertEqual(result.stdout.strip(), "00:11:22:33:44:55 2001:0db8:0000:0000:0000:0000:0000:0009")

    def test_uuid_is_not_guessed(self):
        result = self.function("PFX=2001:0db8:0000:0000; ipv6_records leases",
                               "000400112233445500112233445500112233 2001:db8::9\n")
        self.assertEqual(result.stdout, "")

    def test_ports(self):
        result = self.function("ports '80 0443 1000:1005'")
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "{ 80, 443, 1000-1005 }")
        for value in ("", "0", "65536", "90-80", "80; accept", "tcp", "1-2-3", "-1"):
            self.assertNotEqual(self.function(f"ports {shlex.quote(value)}").returncode, 0, value)
        self.assertNotEqual(self.function("ports '80 443' 1").returncode, 0)

    def test_ipv4_validation(self):
        for value in ("1.2.3", "1.2.3.256", "1.2.3.x", "1.2.3.4;accept", "1.2.3.0000"):
            self.assertNotEqual(self.function(f"valid_ipv4 {shlex.quote(value)}").returncode, 0)


class IntegrationTests(Fixture):
    def test_dynamic_interfaces_and_atomic_batch(self):
        self.assert_ok(self.run_main())
        batch = (self.root / "applied").read_text()
        self.assertIn('delete rule inet fw4 forward_old handle 42', batch)
        self.assertNotIn("handle 43", batch)
        self.assertIn('forward_outside-net', batch)
        self.assertIn('iifname "modem0"', batch)
        self.assertIn("fib daddr type local", batch)
        self.assertIn("ct status dnat", batch)
        self.assertIn("[2001:0db8:0000:0000:0211:22ff:fe33:4455]:80", batch)
        self.assertEqual(len(self.calls("nft")), 2)
        self.assertFalse(list(self.state.glob("run.*")), "EXIT trap leaked temporary files")

    def test_nft_failure_keeps_applied_state_and_map(self):
        (self.state / "state").write_text("old state")
        (self.state / "map").write_text("old map")
        self.assertNotEqual(self.run_main(FAIL_NFT="1").returncode, 0)
        self.assertEqual((self.state / "state").read_text(), "old state")
        self.assertEqual((self.state / "map").read_text(), "old map")
        self.assertFalse((self.root / "applied").exists())
        self.assertFalse(list(self.state.glob("run.*")))

    def test_query_failure_is_not_an_empty_prefix(self):
        (self.state / "relay").write_text("2001:0db8:0000:0001 oldlan 64\n")
        self.assertNotEqual(self.run_main(FAIL_IP="addr show dev modem0").returncode, 0)
        self.assertIn("oldlan", (self.state / "relay").read_text())
        self.assertFalse(any("del" in cmd for cmd in self.calls("ip")))

    def test_netifd_failure_is_not_treated_as_wan_down(self):
        (self.state / "relay").write_text("2001:0db8:0000:0001 oldlan 64\n")
        (self.state / "state").write_text("previous")
        self.assertNotEqual(self.run_main(FAIL_NETIFD="1").returncode, 0)
        self.assertIn("oldlan", (self.state / "relay").read_text())
        self.assertEqual((self.state / "state").read_text(), "previous")
        self.assertFalse((self.root / "attempt").exists())

    def test_fw4_query_failure_preserves_port_state(self):
        (self.state / "state").write_text("previous")
        self.assertNotEqual(self.run_main(FAIL_FW4="1").returncode, 0)
        self.assertEqual((self.state / "state").read_text(), "previous")
        self.assertFalse((self.root / "attempt").exists())

    def test_dhcpv6_without_neighbor(self):
        self.files["ndp"] = ""
        self.lease("00030001001122334455")
        result = self.run_main("--resolve", "192.0.2.10")
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "2001:0db8:0000:0000:0000:0000:0000:0099")
        self.assertFalse((self.root / "applied").exists())

    def test_llt_lease_without_neighbor(self):
        self.files["ndp"] = ""
        self.lease("0001000112345678001122334455")
        result = self.run_main("--resolve", "192.0.2.10")
        self.assert_ok(result)
        self.assertTrue(result.stdout.strip().endswith(":0099"))

    def test_multiple_lease_objects_do_not_cross_associate(self):
        self.files["ndp"] = ""
        self.files["leases.json"] = json.dumps({"device": {"switch0": {"leases": [
            {"duid": "00030001001122334455", "ipv6-prefix": [{"address": "2001:db8:1::"}]},
            {"duid": "00030001aabbccddeeff", "ipv6-addr": [{"address": "2001:db8::10"}]},
            {"duid": "00030001001122334455", "ipv6-addr": [{"address": "2001:db8::99"}]}]}}})
        result = self.run_main("--resolve", "192.0.2.10")
        self.assert_ok(result)
        self.assertTrue(result.stdout.strip().endswith(":0099"))

    def test_configured_dhcpv4_lease_file(self):
        self.files["arp"] = ""
        leasefile = self.root / "custom.leases"
        leasefile.write_text("0 00:11:22:33:44:55 192.0.2.10 host *\n")
        self.files["dhcp.config"] = f"config dnsmasq resolver\noption leasefile {shlex.quote(str(leasefile))}\n"
        self.assert_ok(self.run_main("--resolve", "192.0.2.10"))
        leasefile.write_text("1 00:11:22:33:44:55 192.0.2.10 host *\n")
        self.assertNotEqual(self.run_main("--resolve", "192.0.2.10").returncode, 0)

    def test_expired_or_deprecated_lease_is_not_selected(self):
        self.files["ndp"] = ""
        for preferred, valid in ((0, 100), (100, 0)):
            self.lease("00030001001122334455", preferred=preferred, valid=valid)
            self.assertNotEqual(self.run_main("--resolve", "192.0.2.10").returncode, 0)

    def test_memory_beats_temporary_address(self):
        self.files["ndp"] = "2001:db8::10 lladdr 00:11:22:33:44:55 STALE\n2001:db8::20 lladdr 00:11:22:33:44:55 REACHABLE\n"
        (self.state / "map").write_text("00:11:22:33:44:55 2001:0db8:0000:0000:0000:0000:0000:0020\n")
        self.assertEqual(self.run_main("--resolve", "192.0.2.10").stdout.strip(),
                         "2001:0db8:0000:0000:0000:0000:0000:0020")

    def test_eui64_beats_memory(self):
        (self.state / "map").write_text("00:11:22:33:44:55 2001:0db8:0000:0000:0000:0000:0000:0020\n")
        self.assertIn("0211:22ff:fe33:4455", self.run_main("--resolve", "192.0.2.10").stdout)

    def test_recreates_missing_lan_address(self):
        (self.state / "relay").write_text("2001:0db8:0000:0000 switch0 64\n")
        self.assert_ok(self.run_main())
        self.assertTrue(any(cmd[1:4] == ["-6", "addr", "replace"] for cmd in self.calls("ip")))

    def test_does_not_replace_existing_lan_address(self):
        self.files["lan"] = "inet6 2001:db8::1/64 scope global\n"
        self.assert_ok(self.run_main())
        self.assertFalse(any(cmd[1:4] == ["-6", "addr", "replace"] for cmd in self.calls("ip")))

    def test_prefix_change_cleans_old_device_and_metric(self):
        (self.state / "relay").write_text("2001:0db8:0000:0001 oldlan 73\n")
        self.assert_ok(self.run_main())
        calls = self.calls("ip")
        self.assertIn(["ip", "-6", "route", "del", "2001:0db8:0000:0001::/64", "dev", "oldlan", "metric", "73"], calls)
        self.assertIn(["ip", "-6", "addr", "del", "2001:0db8:0000:0001::1/64", "dev", "oldlan"], calls)

    def test_no_prefix_removes_rules_and_old_relay(self):
        self.files["wan"] = ""
        (self.state / "relay").write_text("2001:0db8:0000:0001 oldlan 64\n")
        self.assert_ok(self.run_main())
        self.assertFalse((self.state / "relay").exists())
        batch = (self.root / "applied").read_text()
        self.assertIn("handle 42", batch)
        self.assertNotIn("dnat ip6 to", batch)

    def test_relay_failure_does_not_record_new_prefix(self):
        self.assertNotEqual(self.run_main(FAIL_IP="route replace").returncode, 0)
        self.assertFalse((self.state / "relay").exists())
        self.assertFalse((self.root / "applied").exists())

    def test_restricted_rules_are_not_broadened(self):
        self.redirect["src_ip"] = "198.51.100.2"
        self.firewall()
        self.assert_ok(self.run_main())
        self.assertNotIn("dnat ip6 to", (self.root / "applied").read_text())
        self.assertIn("src_ip", (self.state / "state").read_text())

    def test_invalid_proto_or_port_does_not_enter_nft(self):
        for key, value in (("proto", "icmp"), ("src_dport", "80; accept")):
            with self.subTest(key=key):
                self.redirect[key] = value
                self.firewall()
                self.assert_ok(self.run_main())
                self.assertNotIn("dnat ip6 to", (self.root / "applied").read_text())

    def test_local_runtime_alias_is_input_only(self):
        self.redirect["dest_ip"] = "192.0.2.2"
        self.redirect["dest_port"] = "8080"
        self.firewall()
        self.assert_ok(self.run_main())
        batch = (self.root / "applied").read_text()
        self.assertIn('input_outside-net', batch)
        self.assertNotIn("dnat ip6 to", batch)

    def test_local_port_remap_uses_translated_input_port(self):
        self.redirect["dest_ip"] = "192.0.2.2"
        self.firewall()
        self.assert_ok(self.run_main())
        batch = (self.root / "applied").read_text()
        self.assertIn('input_outside-net ip6 daddr 2001:0db8:0000:0000::1 tcp dport { 80 } ct status dnat', batch)
        self.assertIn('dnat ip6 to [2001:0db8:0000:0000::1]:80', batch)
        self.assertNotIn('forward_outside-net', batch)

    def test_date_restricted_rule_is_not_broadened(self):
        self.redirect["start_date"] = "2026-12-01"
        self.firewall()
        self.assert_ok(self.run_main())
        self.assertNotIn("dnat ip6 to", (self.root / "applied").read_text())
        self.assertIn("start_date", (self.state / "state").read_text())

    def test_duplicate_targets_reuse_snapshots(self):
        self.firewall([self.redirect, {**self.redirect, "src_dport": "8081"}])
        self.assert_ok(self.run_main())
        calls = self.calls("ip")
        self.assertEqual(sum(cmd[1:4] == ["-6", "neigh", "show"] for cmd in calls), 1)
        self.assertEqual(sum(cmd[1:4] == ["-4", "neigh", "show"] for cmd in calls), 1)
        ubus_calls = self.calls("ubus")
        self.assertEqual(sum(cmd[-2:] == ["dhcp", "ipv6leases"] for cmd in ubus_calls), 1)
        self.assertEqual(sum(cmd[-2:] == ["network.interface", "dump"] for cmd in ubus_calls), 1)

    def test_lock_covers_debug_and_main(self):
        with (self.state / "lock").open("w") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_ok(self.run_main())
            self.assertNotEqual(self.run_main("--resolve", "192.0.2.10").returncode, 0)
        self.assertFalse((self.root / "applied").exists())
        self.assert_ok(self.run_main())

    def test_unchanged_state_is_quiet(self):
        self.assert_ok(self.run_main())
        old = (self.root / "logs").read_text()
        self.assert_ok(self.run_main())
        self.assertEqual((self.root / "logs").read_text(), old)
        # Still reapplies rules, so a fw4 reload cannot invalidate a state-only cache.
        self.assertEqual(sum(cmd[1] == "-f" for cmd in self.calls("nft")), 2)

    def test_invalid_cli(self):
        for args in (("--resolve",), ("--resolve", "bad"), ("--typo",)):
            self.assertEqual(self.run_main(*args).returncode, 2)


class HotplugTests(Fixture):
    def test_events_do_not_depend_on_interface_name(self):
        hook = (ROOT / "files/etc/hotplug.d/iface/99-ipv6-maint").read_text()
        hook = hook.replace("/usr/bin/ipv6-maint.sh", '"$FIXTURE/maint"')
        (self.root / "hook").write_text(hook)
        (self.root / "maint").write_text('#!/bin/sh\nprintf done > "$FIXTURE/triggered"\n')
        (self.root / "maint").chmod(0o755)
        marker = self.root / "triggered"
        for action, addresses, prefixes, expected in (
                ("ifup", "0", "0", True), ("ifdown", "0", "0", True),
                ("ifupdate", "1", "0", True), ("ifupdate", "0", "1", True),
                ("ifupdate", "0", "0", False), ("unknown", "1", "1", False)):
            with self.subTest(action=action, addresses=addresses, prefixes=prefixes):
                marker.unlink(missing_ok=True)
                result = subprocess.run([SHELL, "-c", '. "$FIXTURE/hook"; wait'],
                                        env={**self.env, "ACTION": action, "INTERFACE": "renamed-uplink",
                                             "IFUPDATE_ADDRESSES": addresses, "IFUPDATE_PREFIXES": prefixes,
                                             "IPV6_MAINT_DELAY": "0"},
                                        text=True, capture_output=True, timeout=5)
                self.assert_ok(result)
                self.assertEqual(marker.exists(), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
