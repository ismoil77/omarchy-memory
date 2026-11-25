"""kill_group.py: a signal reaches only the process whose name was checked."""
import os
import signal
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import kill_group  # noqa: E402


class PidReuse(unittest.TestCase):
    def setUp(self):
        self.kid = subprocess.Popen(["sleep", "60"])
        self.addCleanup(lambda: self.kid.poll() is None and self.kid.kill())

    def test_a_process_that_ends_after_the_check_started_is_not_signalled_by_number(self):
        # The process ends (and is reaped, so its PID is free for reuse) while
        # its name is being read; the name still comes back as a match. A
        # signal sent to the number could now hit whoever got that PID.
        real_kill = os.kill  # the test's own way to end the process; os.kill is trapped below

        def gone_then_match(pid, proc="/proc"):
            if pid == self.kid.pid:
                real_kill(pid, signal.SIGKILL)
                self.kid.wait()
            return "sleep" if pid == self.kid.pid else None

        with mock.patch.object(kill_group, "row_name", gone_then_match), \
                mock.patch.object(os, "kill", side_effect=AssertionError("signalled by PID number")):
            self.assertEqual(kill_group.signal_group("sleep", signal.SIGTERM, {self.kid.pid}), (0, 0, []))

    def test_a_live_process_of_the_row_is_signalled_through_its_pidfd(self):
        with mock.patch.object(os, "kill", side_effect=AssertionError("signalled by PID number")):
            self.assertEqual(kill_group.signal_group("sleep", signal.SIGTERM, {self.kid.pid}), (1, 0, []))
        self.assertEqual(self.kid.wait(timeout=5), -signal.SIGTERM)

    def test_a_pid_that_now_belongs_to_another_program_is_left_alone(self):
        self.assertEqual(kill_group.signal_group("not-sleep", signal.SIGKILL, {self.kid.pid}), (0, 0, []))
        self.assertIsNone(self.kid.poll())


class Arguments(unittest.TestCase):
    def test_bad_arguments_signal_nothing(self):
        with mock.patch.object(kill_group, "signal_group", side_effect=AssertionError("signalled")):
            for argv in ([], ["", "TERM"], ["x", "BOGUS"], ["x", "TERM", "12", "-1"], ["x", "TERM", "abc"]):
                self.assertEqual(kill_group.main(argv), 2, argv)

    def test_without_pidfds_nothing_is_signalled(self):
        with mock.patch.object(kill_group, "signal_group", side_effect=AssertionError("signalled")), \
                mock.patch.object(kill_group.os, "pidfd_open", create=True) as p:
            del kill_group.os.pidfd_open
            self.assertEqual(kill_group.main(["x", "TERM"]), 3)


if __name__ == "__main__":
    unittest.main()
