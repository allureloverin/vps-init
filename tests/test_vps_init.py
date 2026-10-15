import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "vps-init.sh"
TOKEN = "test_secret_must_not_appear"
ZONE_ID = "a" * 32
RECORD_ID = "b" * 32


class DDNSTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps(dict(
            token=TOKEN, zone="example.com", domain="vps.example.com",
            record_type="A", proxied=False,
        )))
        source = SCRIPT.read_text().split("<<'CF_DDNS_WORKER'\n", 1)[1].split("\nCF_DDNS_WORKER", 1)[0]
        # 仅在测试副本替换 PATH，从而注入 curl 模拟实现。
        source = source.replace(
            "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            'export PATH="$TEST_BIN:/usr/bin:/bin"',
        )
        self.worker = self.root / "worker.sh"
        self.worker.write_text(source)
        self.calls = self.root / "calls.jsonl"
        self.scenario = self.root / "scenario.json"
        self.scenario.write_text("{}")
        curl = self.root / "curl"
        curl.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
s = json.loads(Path(os.environ["TEST_SCENARIO"]).read_text())
url = next(a for a in args if a.startswith("https://"))
method = args[args.index("--request") + 1] if "--request" in args else "GET"
payload = json.load(sys.stdin) if "--data-binary" in args else None
with open(os.environ["TEST_CALLS"], "a") as f:
    f.write(json.dumps(dict(url=url, method=method, payload=payload, args=args)) + "\\n")
if "cdn-cgi/trace" in url:
    if s.get("network_fail"):
        sys.exit(7)
    print("ip=" + s.get("ip", "8.8.8.8"))
    sys.exit(0)
if s.get("api_fail"):
    print(json.dumps(dict(success=False, errors=[dict(code=10000, message="Authentication error")])) )
    sys.exit(0)
if "/dns_records" not in url:
    result = [dict(id="a" * 32)] if not s.get("no_zone") else []
elif method == "GET":
    result = s.get("records", [])
else:
    result = dict(id="b" * 32)
print(json.dumps(dict(success=True, result=result)))
''')
        curl.chmod(0o700)

    def run_worker(self, **scenario):
        self.scenario.write_text(json.dumps(scenario))
        env = dict(os.environ, TEST_BIN=str(self.root), TEST_SCENARIO=str(self.scenario), TEST_CALLS=str(self.calls))
        result = subprocess.run(["bash", str(self.worker), str(self.config)], env=env, text=True, capture_output=True)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertEqual(list(Path("/tmp").glob("cf-ddns-auth.*")), [])
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        for call in calls:
            self.assertNotIn(TOKEN, str(call["args"]))
        return result, calls

    def record(self, ip="8.8.8.8", proxied=False):
        return dict(id=RECORD_ID, content=ip, proxied=proxied)

    def test_create_missing_record(self):
        result, calls = self.run_worker()
        self.assertEqual(result.returncode, 0, result.stderr)
        write = calls[-1]
        self.assertEqual(write["method"], "POST")
        self.assertEqual(write["payload"], dict(name="vps.example.com", type="A", content="8.8.8.8", ttl=1, proxied=False))

    def test_update_changed_ip_preserves_other_fields(self):
        result, calls = self.run_worker(records=[self.record("1.1.1.1")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1]["method"], "PATCH")
        self.assertEqual(calls[-1]["payload"], dict(content="8.8.8.8", proxied=False))

    def test_unchanged_ip_does_not_write(self):
        result, calls = self.run_worker(records=[self.record()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(c["method"] == "GET" for c in calls))

    def test_proxy_change_is_applied(self):
        result, calls = self.run_worker(records=[self.record(proxied=True)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(calls[-1]["payload"]["proxied"])

    def test_ipv6(self):
        config = json.loads(self.config.read_text())
        config["record_type"] = "AAAA"
        self.config.write_text(json.dumps(config))
        result, calls = self.run_worker(ip="2606:4700:4700::1111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-6", calls[1]["args"])
        self.assertEqual(calls[-1]["payload"]["type"], "AAAA")

    def test_api_failure_stops_writes(self):
        result, calls = self.run_worker(api_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(c["method"] == "GET" for c in calls))

    def test_network_failure_stops_writes(self):
        result, calls = self.run_worker(network_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(c["method"] == "GET" for c in calls))

    def test_invalid_ip_stops_writes(self):
        result, calls = self.run_worker(ip="bad-ip")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(c["method"] == "GET" for c in calls))

    def test_private_ip_stops_writes(self):
        result, calls = self.run_worker(ip="192.168.1.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(c["method"] == "GET" for c in calls))

    def test_duplicate_records_stop_writes(self):
        result, calls = self.run_worker(records=[self.record(), self.record()])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(c["method"] == "GET" for c in calls))

    def test_missing_zone_stops_writes(self):
        result, calls = self.run_worker(no_zone=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)


class InitializerTests(unittest.TestCase):
    def shell(self, code):
        return subprocess.run(["bash", "-c", 'source "$1"\n' + code, "test", str(SCRIPT)], text=True, capture_output=True)

    def test_shell_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_help(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Cloudflare", result.stdout)

    def test_update_failure_prevents_time_and_menu(self):
        result = self.shell('''
preflight() { :; }
update_system() { return 42; }
configure_time() { echo TIME_SHOULD_NOT_RUN; }
menu() { echo MENU_SHOULD_NOT_RUN; }
main --base-only
''')
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_time_sync_checks_all_properties(self):
        for failed in ("Timezone", "NTPSynchronized", "NTP", "service", "none"):
            with self.subTest(failed=failed):
                result = self.shell('''
CHRONY_UNIT=chrony.service
failed=%s
timedatectl() {
    case "$2" in
        --property=Timezone) [[ "$failed" != Timezone ]] && echo Asia/Shanghai || echo UTC ;;
        --property=NTPSynchronized) [[ "$failed" != NTPSynchronized ]] && echo yes || echo no ;;
        --property=NTP) [[ "$failed" != NTP ]] && echo yes || echo no ;;
    esac
}
systemctl() { [[ "$failed" != service ]]; }
if time_ready; then echo READY; else echo BLOCKED; fi
''' % failed)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "READY" if failed == "none" else "BLOCKED")

    def test_ntp_timeout_stops_script(self):
        result = self.shell('''
CHRONY_UNIT=chrony.service
timedatectl() { :; }
systemctl() { [[ "$1" != is-active ]]; }
chronyc() { :; }
sleep() { :; }
time_ready() { return 1; }
configure_time
echo MENU_SHOULD_NOT_RUN
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("120", result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_menu_child_failure_stops_action_and_allows_retry(self):
        result = self.shell('''
install_ddns() { read -r value; echo "INPUT=$value"; false; echo SHOULD_NOT_RUN; }
run_tcpfit() { echo SECOND_ACTION_OK; }
menu <<'INPUT'
1
test-input
2
0
INPUT
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("INPUT=test-input", result.stdout)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
        self.assertIn("SECOND_ACTION_OK", result.stdout)

    def test_tcpfit_download_failure_never_executes(self):
        result = self.shell('''
WORK_DIR=$(mktemp -d)
trap cleanup EXIT
curl() { return 22; }
run_tcpfit
echo EXECUTION_SHOULD_NOT_RUN
''')
        self.assertEqual(result.returncode, 22)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_domain_validation(self):
        for domain, valid in (("example.com", True), ("vps.example.com", True), ("-bad.example.com", False), ("bad..com", False), ("example.com;id", False), ("evil/example.com", False)):
            with self.subTest(domain=domain):
                result = self.shell('if valid_domain %s; then echo VALID; else echo INVALID; fi' % json.dumps(domain))
                self.assertEqual(result.stdout.strip(), "VALID" if valid else "INVALID")


class DDNSInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config_dir = self.root / "config"
        self.units = self.root / "units"
        self.libexec = self.root / "libexec"
        for directory in (self.config_dir, self.units, self.libexec):
            directory.mkdir()
        self.config = self.config_dir / "config.json"
        self.source = self.root / "initializer.sh"
        source = SCRIPT.read_text().replace("/etc/cloudflare-ddns", self.config_dir.as_posix())
        source = source.replace("/etc/systemd/system", self.units.as_posix())
        source = source.replace("/usr/local/libexec", self.libexec.as_posix())
        self.source.write_text(source)

    def run_install(self, validation_status=0, fail_timer=False):
        # 安装目标全部重定向到临时目录；模拟网络验证及 systemd。
        code = r'''
source "$1"
WORK_DIR=$(mktemp -d)
trap cleanup EXIT
install() {
    if [[ "$1" == -d ]]; then
        mkdir -p "$4"
    else
        cp -- "$3" "$4"
    fi
}
prompt_ddns_config() {
    echo PROMPTED
    printf '%s\n' '{"token":"new-test-token"}' > "$WORK_DIR/ddns-config.json"
}
systemctl() {
    printf 'SYSTEMCTL %s\n' "$*"
    if [[ "$1" == enable && "$3" == cloudflare-ddns.timer && "$FAIL_TIMER" == 1 ]]; then
        return 43
    fi
}
# 将验证退出码传给模拟 bash，不执行 worker。
bash() { echo VALIDATED; return "$VALIDATION_STATUS"; }
install_ddns
'''
        env = dict(os.environ, VALIDATION_STATUS=str(validation_status), FAIL_TIMER=str(int(fail_timer)))
        result = subprocess.run(["bash", "-c", code, "test", str(self.source)],
                                env=env, text=True, capture_output=True)
        self.assertNotIn("new-test-token", result.stdout + result.stderr)
        return result

    def test_existing_config_repairs_missing_units_without_prompt(self):
        original = '{"token":"existing-test-token"}\n'
        self.config.write_text(original)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("PROMPTED", result.stdout)
        self.assertEqual(self.config.read_text(), original)
        self.assertTrue((self.units / "cloudflare-ddns.service").exists())
        self.assertTrue((self.units / "cloudflare-ddns.timer").exists())
        self.assertTrue((self.libexec / "cloudflare-ddns.sh").exists())
        self.assertIn("SYSTEMCTL enable --now cloudflare-ddns.timer", result.stdout)

    def test_orphan_service_without_config_can_be_reinstalled(self):
        (self.units / "cloudflare-ddns.service").write_text("incomplete\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROMPTED", result.stdout)
        self.assertTrue(self.config.exists())
        self.assertIn("Type=oneshot", (self.units / "cloudflare-ddns.service").read_text())

    def test_timer_failure_can_be_retried_with_saved_config(self):
        result = self.run_install(fail_timer=True)
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertTrue(self.config.exists())
        saved = self.config.read_text()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("PROMPTED", result.stdout)
        self.assertEqual(self.config.read_text(), saved)

    def test_invalid_existing_config_leaves_installation_untouched(self):
        original = '{"token":"existing-test-token"}\n'
        self.config.write_text(original)
        unit = self.units / "cloudflare-ddns.service"
        unit.write_text("original-service\n")
        result = self.run_install(validation_status=44)
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(unit.read_text(), "original-service\n")
        self.assertNotIn("SYSTEMCTL", result.stdout)
        self.assertFalse((self.libexec / "cloudflare-ddns.sh").exists())


if __name__ == "__main__":
    unittest.main()
