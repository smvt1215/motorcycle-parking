"""The staging release notes: unchanged without a notice, notice appended with one."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

import staging_release_notes as notes

HEAD = "Alpha（內部預覽）\n0123abcd\nfix: something\n"


class ComposeTest(unittest.TestCase):
    def test_without_a_notice_the_notes_are_unchanged(self):
        self.assertEqual(notes.compose(HEAD, ""), HEAD)

    def test_a_notice_follows_after_one_empty_line(self):
        self.assertEqual(
            notes.compose(HEAD, "隱私權政策更新"),
            "Alpha（內部預覽）\n0123abcd\nfix: something\n\n隱私權政策更新\n",
        )

    def test_an_oversized_notice_fails_instead_of_being_cut(self):
        with self.assertRaises(SystemExit):
            notes.compose(HEAD, "字" * (notes.NOTICE_LIMIT + 1))


class ReadNoticeTest(unittest.TestCase):
    def test_missing_and_blank_files_mean_no_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "notice.txt"
            self.assertEqual(notes.read_notice(path), "")
            path.write_text("  \n\n", encoding="utf-8")
            self.assertEqual(notes.read_notice(path), "")
            path.write_text("\n公告\n第二行\n\n", encoding="utf-8")
            self.assertEqual(notes.read_notice(path), "公告\n第二行")

    def test_the_committed_notice_fits(self):
        self.assertLessEqual(len(notes.read_notice()), notes.NOTICE_LIMIT)


class MainTest(unittest.TestCase):
    def test_writes_the_git_head_and_the_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "notes.txt"
            subprocess.run([sys.executable, notes.__file__, str(out)], check=True, cwd=notes.ROOT)
            head = subprocess.run(
                ["git", "log", "-1", f"--format={notes.HEAD_FORMAT}"],
                check=True,
                capture_output=True,
                encoding="utf-8",
                cwd=notes.ROOT,
            ).stdout
            self.assertEqual(out.read_text(encoding="utf-8"), notes.compose(head, notes.read_notice()))


if __name__ == "__main__":
    unittest.main()
