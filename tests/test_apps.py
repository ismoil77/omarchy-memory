"""apps.py against a fake /proc: grouping, kernel threads, swap, unreadable pids."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import apps  # noqa: E402


def proc(root, pid, cmdline, rss, swap=0):
    d = os.path.join(root, str(pid))
    os.makedirs(d)
    with open(os.path.join(d, "cmdline"), "wb") as f:
        f.write(cmdline)
    with open(os.path.join(d, "status"), "w") as f:
        f.write("Name:\tx\nVmRSS:\t%d kB\nVmSwap:\t%d kB\n" % (rss, swap))


class Apps(unittest.TestCase):
    def test_groups_like_ps_args(self):
        with tempfile.TemporaryDirectory() as root:
            proc(root, 1, b"/opt/google/chrome/chrome\0--type=renderer\0", 100, 5)
            # Chromium helpers rewrite argv into one space-separated string.
            proc(root, 2, b"/opt/google/chrome/chrome --type=gpu-process", 50, 1)
            proc(root, 3, b"node\0server.js\0", 300)
            proc(root, 4, b"", 999)                      # kernel thread
            proc(root, 5, b"sshd:\0", 10)               # "sshd:" -> "sshd"
            proc(root, 6, b"idle\0", 0)                  # no resident memory
            os.makedirs(os.path.join(root, "self"))
            os.makedirs(os.path.join(root, "7"))        # vanished: no files
            out = apps.collect(root)
        self.assertEqual([(g["name"], g["rss"], g["swap"], g["count"]) for g in out],
                         [("node", 300, 0, 1), ("chrome", 150, 6, 2), ("sshd", 10, 0, 1)])

    def test_app_name(self):
        self.assertEqual(apps.app_name(b"/usr/bin/python3\0x.py"), "python3")
        self.assertEqual(apps.app_name(b"php-fpm: pool www"), "php-fpm")
        self.assertEqual(apps.app_name(b"\xff\xfe\0"), "��")

    def test_status_kb(self):
        self.assertEqual(apps.status_kb("VmRSS:\t  42 kB\n", "VmRSS:"), 42)
        self.assertEqual(apps.status_kb("nothing", "VmSwap:"), 0)


if __name__ == "__main__":
    unittest.main()
