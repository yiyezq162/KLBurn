#!/usr/bin/env python3
"""Confirmation behavior only; fake device names, never run fio or touch disks."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = r'''
set -uo pipefail
source rootfs/opt/klburn/lib/core.sh
source rootfs/opt/klburn/lib/ui.sh
source rootfs/opt/klburn/lib/storage.sh
MAIN_LOG=/dev/null
DISK_CAND=(/dev/FAKE_TEST_ONLY)
DISK_INFO=('/dev/FAKE_TEST_ONLY|1G|Fixture|FAKE|1|sata|gpt')
DISK_EXCLUDED=()
DISK_SKIP_REASON=''
TERM=dumb
'''


def run(script, inputs=''):
    return subprocess.run(['bash', '-c', SETUP + script], cwd=ROOT,
                          input=inputs, text=True, capture_output=True, timeout=8)


class DiskConsoleTests(unittest.TestCase):
    def test_both_languages_and_early_write_warning(self):
        result = run('KLB_DISK_CJK=1; confirm_disk_write 2', 'y\nyes\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('测试导致数据丢失，一切损失由测试者负责。'), 2)
        self.assertEqual(result.stdout.count('The test causes data loss.'), 2)
        self.assertIn('BEFORE the disk stress test.', result.stdout)
        self.assertIn('最终警告', result.stdout)

    def test_native_fallback_is_ascii_and_complete(self):
        result = run('confirm_disk_write 2', 'YES\ny\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.isascii())
        self.assertEqual(result.stdout.count('The test causes data loss.'), 2)
        self.assertIn('BEFORE the disk stress test.', result.stdout)

    def test_each_rejection_stops_without_authorization(self):
        for inputs in ('\n', 'n\n', 'yas\n', 'y\n\n', 'yes\nn\n', 'y\nye\n'):
            with self.subTest(inputs=inputs):
                result = run('KLB_DISK_CJK=1; confirm_disk_write 2', inputs)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('confirmed by operator', result.stdout)

    def test_timeout_at_either_gate_is_not_authorization(self):
        for gate in (1, 2):
            result = run(f'''
call=0
read_line_countdown() {{
  call=$((call+1))
  (( call != {gate} )) || return 1
  printf -v "$1" '%s' y
}}
KLB_DISK_CJK=1
confirm_disk_write 2
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('confirmed by operator', result.stdout)

    def test_no_candidates_never_prompts(self):
        result = run('DISK_CAND=(); KLB_DISK_CJK=1; confirm_disk_write 2')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_terminal_exit_alone_never_authorizes(self):
        for terminal_rc, receipt, expected in ((0, '', 1), (1, '', 1),
                                               (0, 'bad', 1), (124, 'confirmed', 1),
                                               (0, 'confirmed', 0)):
            with self.subTest(terminal_rc=terminal_rc, receipt=receipt):
                result = run(f'''
timeout() {{
  local session="${{@: -2:1}}"
  printf '%s\\n' '{receipt}' > "$session/result"
  return {terminal_rc}
}}
disk_confirm_console 2
''')
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_child_only_records_completed_double_confirmation(self):
        for inputs, confirmed in (('y\nyes\n', True), ('yes\nno\n', False), ('\n', False)):
            with self.subTest(inputs=inputs), tempfile.TemporaryDirectory() as tmp:
                session = pathlib.Path(tmp)
                state = run('declare -p DISK_CAND DISK_INFO DISK_EXCLUDED MAIN_LOG').stdout
                (session / 'state').write_text(state, encoding='utf-8')
                helper = (ROOT / 'rootfs/opt/klburn/disk-confirm-console.sh').read_text()
                # Test-only path substitution; production helper and library behavior unchanged.
                helper = helper.replace('/opt/klburn', str(ROOT / 'rootfs/opt/klburn'))
                result = subprocess.run(['bash', '-c', helper, 'test-helper', tmp, '2'],
                                        input=inputs, text=True, capture_output=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((session / 'result').exists(), confirmed)
                if confirmed:
                    self.assertEqual((session / 'result').read_text(), 'confirmed\n')
                else:
                    self.assertTrue((session / 'reason').read_text().strip())

    def test_terminal_exit_restores_original_no_blanking_policy(self):
        for terminal_rc, receipt in ((0, 'confirmed'), (0, ''), (1, ''), (124, 'confirmed')):
            with self.subTest(terminal_rc=terminal_rc, receipt=receipt):
                result = run(f'''
timeout() {{
  local session="${{@: -2:1}}"
  printf '%s\\n' '{receipt}' > "$session/result"
  printf 'TERMINAL_EXIT\\n'
  return {terminal_rc}
}}
setterm() {{ printf 'SETTERM %s\\n' "$*"; }}
disk_confirm_console 2 || true
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('SETTERM -blank 0 -powersave off', result.stdout)
                self.assertIn('SETTERM -cursor on', result.stdout)
                self.assertLess(result.stdout.index('TERMINAL_EXIT'),
                                result.stdout.index('SETTERM -blank 0 -powersave off'))


if __name__ == '__main__':
    outcome = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(DiskConsoleTests))
    failures = len(outcome.failures) + len(outcome.errors)
    print(f'通过 {outcome.testsRun - failures} 项，失败 {failures} 项')
    raise SystemExit(not outcome.wasSuccessful())
