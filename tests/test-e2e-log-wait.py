import pathlib
import subprocess
import tempfile
import threading
import unittest

HELPER=pathlib.Path(__file__).parent/'lib/e2e-log-wait.sh'
class WaitTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image=pathlib.Path(self.tmp.name)/'image.bin'
        self.image.write_bytes(b'\0'*1024)
    def run_shell(self,command):
        setup='source "$1"; IMG="$2"; QEMU_PID=$$; info(){ :; }; ok(){ printf "OK\\n"; }; bad(){ printf "BAD\\n"; }; shot(){ printf "SHOT:%s\\n" "$1"; }; sleep(){ command sleep 0.02; }; '
        return subprocess.run(['bash','-c',setup+command,'test',str(HELPER),str(self.image)],capture_output=True,text=True,timeout=6)
    def test_absent_anchor(self):
        self.assertEqual(self.run_shell("image_has 'Report PDF written'").returncode,1)
    def test_fresh_image_allowed(self):
        self.assertEqual(self.run_shell("require_absent_log_anchor 'Report PDF written'").returncode,0)
    def test_preexisting_completion_rejected(self):
        self.image.write_bytes(b'Report PDF written')
        self.assertEqual(self.run_shell("require_absent_log_anchor 'Report PDF written'").returncode,1)
    def test_anchor_crosses_binary_chunk_boundary(self):
        self.image.write_bytes(b'\0'*(1024*1024-5)+b'Report PDF written\0')
        self.assertEqual(self.run_shell("image_has 'Report PDF written'").returncode,0)
    def test_present_completion(self):
        self.image.write_bytes(b'Report PDF written')
        result=self.run_shell('wait_for_mem_report 2')
        self.assertEqual(result.returncode,0)
        self.assertEqual(result.stdout,'OK\nSHOT:mem-complete\n')
    def test_not_ready_is_failure_not_success(self):
        result=self.run_shell('wait_for_mem_report 1')
        self.assertEqual(result.returncode,1)
        self.assertEqual(result.stdout,'BAD\n')
    def test_late_completion_waits(self):
        timer=threading.Timer(0.15,lambda:self.image.write_bytes(b'Report PDF written'))
        timer.start()
        try: result=self.run_shell('wait_for_mem_report 2')
        finally: timer.join()
        self.assertEqual(result.returncode,0)
        self.assertEqual(result.stdout,'OK\nSHOT:mem-complete\n')
    def test_vm_exits_before_report(self):
        result=self.run_shell('command sleep 0.01 & QEMU_PID=$!; wait "$QEMU_PID"; wait_for_mem_report 2')
        self.assertEqual(result.returncode,1)
        self.assertEqual(result.stdout,'BAD\n')

if __name__=='__main__':
    result=unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(WaitTests))
    failed=len(result.failures)+len(result.errors)
    print('通过 %d 项，失败 %d 项' % (result.testsRun-failed-len(result.skipped),failed))
    raise SystemExit(not result.wasSuccessful())
