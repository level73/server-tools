"""Opt-in Linux/root fixture tests; never execute provisioning entry points.

Run on a disposable Linux host:
    sudo env SERVER_TOOLS_RUN_PRIVILEGED_TESTS=1 python3 -B tests/test_paths_linux.py

Uses existing nobody identity and an isolated directory under /var/lib.
No services, account creation, package installation or network access.
"""

import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(os.environ.get("SERVER_TOOLS_ROOT", Path(__file__).resolve().parents[1]))
ENABLED = (sys.platform.startswith("linux") and os.geteuid() == 0
           and os.environ.get("SERVER_TOOLS_RUN_PRIVILEGED_TESTS") == "1")


def extract(name, script):
    text = (ROOT / script).read_text(encoding="utf-8")
    matches = re.findall(rf"^{name}\(\) \{{\n.*?^\}}[ \t]*$", text, re.M | re.S)
    if len(matches) != 1:
        raise AssertionError(f"Expected exactly one {name} in {script}")
    return matches[0]


@unittest.skipUnless(ENABLED, "Requires explicit opt-in and root on disposable Linux")
class LinuxPathSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import pwd

        for command in ("bash", "stat", "mkdir", "mv", "runuser", "ln", "rm"):
            if shutil.which(command) is None:
                raise RuntimeError(f"Missing required command: {command}")
        for directory in (Path("/"), Path("/var"), Path("/var/lib")):
            metadata = directory.lstat()
            if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0
                    or metadata.st_mode & 0o022):
                raise RuntimeError(f"Unsafe fixture ancestor: {directory}")
        identity = pwd.getpwnam("nobody")
        if identity.pw_uid == 0 or identity.pw_gid == 0:
            raise RuntimeError("Fixture identity must not use root UID/GID")
        cls.uid, cls.gid = identity.pw_uid, identity.pw_gid
        import grp
        cls.group = grp.getgrgid(cls.gid).gr_name
        cls.base = Path(tempfile.mkdtemp(prefix="server-tools-r04-tests.", dir="/var/lib"))
        print(f"Linux filesystem fixture: {cls.base}", flush=True)
        cls.base.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        # Only remove the exact private fixture returned by mkdtemp. Do not
        # follow links, accept arbitrary paths or clean any application tree.
        if (cls.base.parent != Path("/var/lib")
                or not cls.base.name.startswith("server-tools-r04-tests.")
                or cls.base.is_symlink()):
            raise RuntimeError("Refusing unexpected fixture cleanup target")
        shutil.rmtree(cls.base)

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case-", dir=self.base))
        self.case.chmod(0o755)
        self.site = self.case / "site"
        self.site.mkdir(mode=0o755)
        os.chown(self.site, self.uid, self.gid)
        self.site.chmod(0o755)

    def run_functions(self, command, *args, extra=""):
        functions = "\n".join(extract(name, "addhost.sh") for name in (
            "require_trusted_directory", "trusted_directory_chain", "ensure_site_directory"))
        functions += "\n" + extract("publish_wordpress_tree", "wphost.sh")
        functions += "\n" + extract("cleanup_staging", "wphost.sh")
        arguments = [str(self.site), str(self.uid), str(self.gid), self.group, *map(str, args)]
        literals = ["$'" + "".join(f"\\x{b:02x}" for b in value.encode()) + "'" for value in arguments]
        code = "set -Eeuo pipefail\nset -- " + " ".join(literals) + "\n" + functions + r'''
absolute_doc_root=$1
SITE_UID=$2
SITE_GID=$3
SITE_USER=nobody
SITE_GROUP=$4
shift 4
''' + extra + "\n" + command + "\n"
        env = os.environ.copy()
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"):
            env.pop(key, None)
        return subprocess.run(["bash", "--noprofile", "--norc", "-s"], input=code,
                              text=True, capture_output=True, timeout=15, env=env)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_root_managed_parents_are_created_without_repairing_existing_ones(self):
        parent = self.case / "clients" / "client1"
        self.assert_success(self.run_functions('trusted_directory_chain "$1" true', parent))
        self.assertEqual(parent.stat().st_uid, 0)
        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o755)

    def test_symlink_and_dangling_parent_are_rejected(self):
        for name, target in (("link", self.case), ("dangling", self.case / "missing")):
            link = self.case / name
            link.symlink_to(target, target_is_directory=True)
            self.assert_rejected(self.run_functions('trusted_directory_chain "$1" true', link / "child"))
        self.assertFalse((self.case / "child").exists())
        self.assertFalse((self.case / "missing").exists())

    def test_application_owned_parent_is_rejected(self):
        self.assert_rejected(self.run_functions('trusted_directory_chain "$1" true', self.site / "nested"))
        self.assertFalse((self.site / "nested").exists())

    def test_group_or_world_writable_parent_is_rejected(self):
        parent = self.case / "unsafe"
        parent.mkdir()
        for mode in (0o775, 0o757, 0o1777):
            parent.chmod(mode)
            self.assert_rejected(self.run_functions('trusted_directory_chain "$1" true', parent / "child"))
            self.assertFalse((parent / "child").exists())
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), mode)

    def test_site_directories_are_created_as_site_user_and_reused_without_changes(self):
        for name, mode in (("logs", "750"), ("public_html", "755")):
            self.assert_success(self.run_functions('ensure_site_directory "$1" "$2"', name, mode))
            directory = self.site / name
            before = directory.stat()
            self.assertEqual((before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode)),
                             (self.uid, self.gid, int(mode, 8)))
            self.assert_success(self.run_functions('ensure_site_directory "$1" "$2"', name, mode))
            self.assertEqual(directory.stat().st_ctime_ns, before.st_ctime_ns)

    def test_existing_wrong_metadata_is_not_repaired(self):
        directory = self.site / "logs"
        directory.mkdir(mode=0o700)
        before = directory.stat()
        self.assert_rejected(self.run_functions('ensure_site_directory logs 750'))
        after = directory.stat()
        self.assertEqual((after.st_uid, after.st_gid, after.st_mode, after.st_ctime_ns),
                         (before.st_uid, before.st_gid, before.st_mode, before.st_ctime_ns))

    def test_site_symlinks_are_rejected_without_touching_their_targets(self):
        target = self.case / "outside-site"
        target.mkdir(mode=0o700)
        before = target.stat()
        (self.site / "logs").symlink_to(target, target_is_directory=True)
        (self.site / "public_html").symlink_to(self.case / "missing", target_is_directory=True)
        self.assert_rejected(self.run_functions('ensure_site_directory logs 750'))
        self.assert_rejected(self.run_functions('ensure_site_directory public_html 755'))
        self.assertEqual(target.stat().st_ctime_ns, before.st_ctime_ns)
        self.assertFalse((self.case / "missing").exists())

    def test_concurrent_child_insertion_cannot_trigger_privileged_repair(self):
        target = self.case / "outside-site"
        target.mkdir(mode=0o700)
        before = target.stat()
        extra = r'''
race_target=$1
runuser() {
    command ln -s -- "$race_target" "$absolute_doc_root/logs"
    command runuser "$@"
}
'''
        self.assert_rejected(self.run_functions('ensure_site_directory logs 750', target, extra=extra))
        self.assertEqual(target.stat().st_ctime_ns, before.st_ctime_ns)

    def staging_tree(self):
        private = Path(tempfile.mkdtemp(prefix=".wphost.", dir=self.case))
        tree = private / "wordpress"
        tree.mkdir(mode=0o755)
        (tree / "marker").write_text("fixture", encoding="utf-8")
        os.chown(tree, self.uid, self.gid)
        return private, tree

    def test_private_staging_cannot_be_accessed_by_site_user(self):
        _, tree = self.staging_tree()
        self.assert_rejected(self.run_functions('runuser --user "$SITE_USER" -- test -r "$1"', tree / "marker"))

    def test_wordpress_publication_succeeds(self):
        _, tree = self.staging_tree()
        destination = self.site / "wordpress"
        self.assert_success(self.run_functions('publish_wordpress_tree "$1" "$2"', tree, destination))
        self.assertFalse(tree.exists())
        self.assertEqual((destination / "marker").read_text(), "fixture")

    def test_wordpress_publication_refuses_existing_directory_or_link(self):
        for kind in ("directory", "link", "dangling"):
            _, tree = self.staging_tree()
            destination = self.site / kind
            if kind == "directory":
                destination.mkdir()
            else:
                destination.symlink_to(self.case if kind == "link" else self.case / "missing",
                                       target_is_directory=True)
            self.assert_rejected(self.run_functions('publish_wordpress_tree "$1" "$2"', tree, destination))
            self.assertTrue(tree.exists())
            self.assertTrue(destination.exists() or destination.is_symlink())

    def test_silent_mv_skip_is_not_success(self):
        _, tree = self.staging_tree()
        self.assert_rejected(self.run_functions('publish_wordpress_tree "$1" "$2"', tree,
                                               self.site / "wordpress", extra='mv() { return 0; }'))
        self.assertTrue(tree.exists())

    def test_different_devices_are_rejected_before_mv(self):
        _, tree = self.staging_tree()
        extra = r'''
staged_source=$1
stat() { if [[ $4 == "$staged_source" ]]; then printf 1; else printf 2; fi; }
mv() { printf 'UNEXPECTED MOVE\n'; return 99; }
'''
        result = self.run_functions('publish_wordpress_tree "$1" "$2"', tree,
                                    self.site / "wordpress", extra=extra)
        self.assert_rejected(result)
        self.assertNotIn("UNEXPECTED MOVE", result.stdout)
        self.assertTrue(tree.exists())

    def test_cleanup_only_removes_private_staging(self):
        private, _ = self.staging_tree()
        self.assert_success(self.run_functions('staging_parent=$1; staging_dir=$2; cleanup_staging',
                                               self.case, private))
        self.assertFalse(private.exists())
        self.assert_success(self.run_functions('staging_parent=$1; staging_dir=$2; cleanup_staging',
                                               self.case, self.site))
        self.assertTrue(self.site.exists())


if __name__ == "__main__":
    if not ENABLED:
        raise SystemExit("Use explicit opt-in with sudo on a disposable Linux host; see module instructions")
    unittest.main(verbosity=2)
