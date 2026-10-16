import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "vps-init.sh"

MOCKS = r"""
preflight() { :; }
apt() { printf 'APT %s\n' "$*"; }
ntp_attempts=0
timedatectl() {
    if [[ "$1" == show ]]; then
        if [[ "$2" == "--property=${FAIL_PROP:-}" ]]; then
            echo invalid
            return
        fi
        case "$2" in
            --property=Timezone) echo Asia/Shanghai ;;
            --property=NTPSynchronized|--property=NTP) echo yes ;;
            --property=LocalRTC) echo no ;;
        esac
    else
        printf 'TIME %s\n' "$*"
    fi
}
systemctl() { printf 'SERVICE %s\n' "$*"; }
sleep() { :; }
curl() { printf '%s\n' 'echo TCPFIT_RAN'; }
"""


class VPSInitTests(unittest.TestCase):
    def shell(self, code, answer=""):
        return subprocess.run(
            ["bash", "-c", 'source "$1"\n' + MOCKS + code, "test", str(SCRIPT)],
            input=answer, text=True, capture_output=True,
        )

    def test_syntax_and_process_substitution_entry(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        result = subprocess.run(
            ["bash", "-c", 'bash <(cat "$1") --help', "test", str(SCRIPT)],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("curl wget", result.stdout)

    def test_no_runs_only_required_steps_in_order(self):
        result = self.shell("main", "n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ["APT update -y", "APT install curl wget -y",
                    "TIME set-timezone Asia/Shanghai", "TIME set-local-rtc 0",
                    "TIME set-ntp true", "TIME status", "已完成时间设置，退出"]
        positions = [result.stdout.index(item) for item in expected]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("TCPFIT_RAN", result.stdout)
        self.assertNotIn("upgrade", result.stdout)
        self.assertNotIn("DDNS", result.stdout)
        self.assertNotIn("systemd-timesyncd -y", result.stdout)

    def test_yes_runs_tcpfit(self):
        for answer in ("y", "yes", "Y", "是", "1"):
            with self.subTest(answer=answer):
                result = self.shell("main", answer + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("TCPFIT_RAN", result.stdout)
                self.assertLess(result.stdout.index("TIME status"), result.stdout.index("TCPFIT_RAN"))

    def test_no_and_default_exit(self):
        for answer in ("n", "no", "N", "否", "0", ""):
            with self.subTest(answer=answer):
                result = self.shell("main", answer + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_eof_exits_without_tuning(self):
        result = self.shell("main")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_invalid_choice_reprompts(self):
        result = self.shell("main", "maybe\nn\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("请输入 y", result.stdout)
        self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_failed_update_stops_before_install_time_or_tuning(self):
        result = self.shell(r"""
apt() { printf 'APT %s\n' "$*"; return 42; }
main
""", "y\n")
        self.assertEqual(result.returncode, 42)
        self.assertIn("APT update -y", result.stdout)
        self.assertNotIn("APT install", result.stdout)
        self.assertNotIn("TIME", result.stdout)
        self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_failed_install_stops_before_time_or_tuning(self):
        result = self.shell(r"""
apt() { if [[ "$1" == install ]]; then return 43; fi; }
main
""", "y\n")
        self.assertEqual(result.returncode, 43)
        self.assertNotIn("TIME", result.stdout)
        self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_each_required_time_property_blocks_tuning(self):
        for prop in ("Timezone", "NTPSynchronized", "NTP", "LocalRTC"):
            with self.subTest(prop=prop):
                result = self.shell("FAIL_PROP=" + prop + "\nmain", "y\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("120 秒", result.stderr)
                self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_missing_ntp_service_is_installed_and_enabled(self):
        result = self.shell(r"""
original_timedatectl=$(declare -f timedatectl)
eval "${original_timedatectl/timedatectl ()/mock_timedatectl ()}"
timedatectl() {
    if [[ "$1" == set-ntp ]]; then
        ntp_attempts=$((ntp_attempts + 1))
        if [[ "$ntp_attempts" -eq 1 ]]; then return 1; fi
    fi
    mock_timedatectl "$@"
}
main
""", "n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("APT install systemd-timesyncd -y", result.stdout)
        self.assertIn("SERVICE enable --now systemd-timesyncd.service", result.stdout)

    def test_download_failure_is_reported(self):
        result = self.shell("curl() { return 22; }\nmain", "y\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("下载失败", result.stderr)
        self.assertNotIn("TCPFIT_RAN", result.stdout)

    def test_empty_download_is_reported(self):
        result = self.shell("curl() { :; }\nmain", "y\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("下载内容为空", result.stderr)

    def test_tcpfit_failure_reaches_caller(self):
        result = self.shell("curl() { printf '%s\\n' 'exit 37'; }\nmain", "y\n")
        self.assertEqual(result.returncode, 37)


if __name__ == "__main__":
    unittest.main()
