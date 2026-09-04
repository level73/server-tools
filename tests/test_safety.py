"""Non-privileged regression tests; no provisioning commands are executed.

Until production functions are moved into importable libraries, extract only
named, top-level functions with an unindented closing brace. Fail if a function
cannot be located. Never source an entire provisioning script.
"""

import os
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(os.environ.get("SERVER_TOOLS_ROOT", Path(__file__).resolve().parents[1]))
BASH = os.environ.get("BASH_BIN", "bash")
SCRIPTS = ("addhost.sh", "install.sh", "provision.sh", "setmysql.sh", "setssl.sh", "wphost.sh")

if hasattr(os, "geteuid") and os.geteuid() == 0:
    raise RuntimeError("Run these tests as an unprivileged user, never with sudo")


def source_text(name):
    return (ROOT / name).read_text(encoding="utf-8")


def function(name, script):
    matches = re.findall(
        rf"^{re.escape(name)}\(\) \{{\n.*?^\}}[ \t]*$",
        source_text(script),
        re.MULTILINE | re.DOTALL,
    )
    if len(matches) != 1:
        raise AssertionError(f"Expected one top-level {name} in {script}")
    return matches[0]


def bash(code, *arguments):
    env = os.environ.copy()
    for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"):
        env.pop(key, None)
    # ANSI-C byte escapes preserve CR/LF, quotes and Unicode without depending
    # on Windows/MSYS argv quoting or physical line-ending conversion.
    literals = ["$'" + "".join(f"\\x{byte:02x}" for byte in arg.encode("utf-8")) + "'"
                for arg in arguments]
    program = "set -Eeuo pipefail\nset -- " + " ".join(literals) + "\n" + code + "\n"
    return subprocess.run(
        [BASH, "--noprofile", "--norc", "-s"], input=program,
        text=True, capture_output=True, timeout=10, env=env,
    )


class Validators(unittest.TestCase):
    def check_values(self, script, name, accepted, rejected):
        code = function(name, script) + f'\n{name} "$1"'
        for value in accepted:
            with self.subTest(script=script, value=repr(value), expected="accept"):
                result = bash(code, value)
                self.assertEqual(result.returncode, 0, result.stderr)
        for value in rejected:
            with self.subTest(script=script, value=repr(value), expected="reject"):
                result = bash(code, value)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_hostname_contract_in_all_commands(self):
        accepted = ["example.com", "app.example.com", "a-b.example", "a" * 63 + ".com"]
        rejected = [
            "", "localhost", "https://example.com", "example.com:80",
            "example.com/a", "../example.com", ".example.com", "example.com.",
            "a..com", "-a.com", "a-.com", "*.example.com", "a_b.com",
            "example.com\n", "example.com\ntrailing", "example.com\r\ntrailing",
            "example.com other", "$(id).com", "a" * 64 + ".com",
            ".".join(["a" * 63] * 4), "éxample.com",
        ]
        for script in ("addhost.sh", "provision.sh", "setssl.sh"):
            self.check_values(script, "validate_hostname", accepted, rejected)

    def test_relative_paths(self):
        for script in ("addhost.sh", "provision.sh"):
            self.check_values(script, "validate_relative_doc_root",
                              ["example.com", "clients/example.com", "client_1/app-2"],
                              ["", "/etc", "..", "a/../b", "a/./b", "a//b", "a/",
                               ".hidden", "a/.hidden", "a b", "a\nb", "a\\b", "-a",
                               "a" * 256])

    def test_database_identifiers(self):
        for script in ("setmysql.sh", "provision.sh"):
            for name, maximum in (("validate_database_name", 64), ("validate_database_user", 32)):
                self.check_values(script, name, ["app_db", "app123", "a" * maximum],
                                  ["", "a" * (maximum + 1), "a-b", "a b", "a`b", "a'b",
                                   "a;b", "a\nb", "a%b"])

    def test_wordpress_version_and_locale(self):
        for script, version, locale in (
            ("wphost.sh", "validate_version", "validate_locale"),
            ("addhost.sh", "validate_wordpress_version", "validate_wordpress_locale"),
            ("provision.sh", "validate_wordpress_version", "validate_wordpress_locale"),
        ):
            self.check_values(script, version, ["6.8", "6.8.2"], ["latest", "6", "6.8;id", "6.8\n"])
            self.check_values(script, locale, ["en_US", "it_IT"], ["", "../it_IT", "it IT", "it_IT\n"])

    def test_sql_quote_escaping(self):
        code = function("escape_sql_string", "setmysql.sh") + '\nescape_sql_string "$1"'
        result = bash(code, "test'quote\\backslash")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "test''quote\\backslash")


class CommandLine(unittest.TestCase):
    def test_syntax(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                result = subprocess.run([BASH, "-n"], input=source_text(script),
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_options_before_privileged_operations(self):
        cases = [
            ("install.sh", ["-z"]),
            ("addhost.sh", ["-u"]),
            ("setmysql.sh", ["-d", "bad;name", "-u", "app"]),
            ("setssl.sh", ["-u", "../bad", "-m", "admin@example.com", "-e", "staging"]),
            ("provision.sh", ["prepare", "-t", "generic", "-u", "example.com", "-d", "../bad"]),
            ("provision.sh", ["prepare", "-t", "wordpress", "-u", "example.com", "-d", "example.com"]),
            ("provision.sh", ["prepare", "-t", "generic", "-u", "example.com", "-d", "example.com", "-b", "app"]),
            ("provision.sh", ["activate", "-t", "generic", "-u", "example.com", "-d", "example.com", "-m", "admin@example.com"]),
            ("provision.sh", ["prepare", "-t", "generic", "-u", "example.com", "-d", "example.com", "-a", "example.com"]),
        ]
        for script, arguments in cases:
            with self.subTest(script=script, arguments=arguments):
                # Cases above must reject before any root-level operation.
                result = bash('PATH=/usr/bin:/bin:$PATH\nbash "$@" </dev/null',
                              str(ROOT / script), *arguments)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)


class Orchestration(unittest.TestCase):
    def prepare(self, profile, db_status=0, host_status=0):
        # Load only orchestration. Replace every dependency with a Bash mock.
        # No account, database, package, configuration or network operation.
        code = function("run_prepare", "provision.sh") + r'''
site_profile=$1
site_url=example.com
relative_doc_root=example.com
database_name=app_db
database_user=app_user
wordpress_version=6.8.2
wordpress_locale=en_US
deploy_user=deploy
site_aliases=(www.example.com)
db_status=$2
host_status=$3
resolve_command() { printf 'mock_%s' "$1"; }
mock_setmysql() { printf 'CALL database'; printf ' <%s>' "$@"; printf '\n'; return "$db_status"; }
mock_addhost() { printf 'CALL host'; printf ' <%s>' "$@"; printf '\n'; return "$host_status"; }
run_prepare
'''
        return bash(code, profile, str(db_status), str(host_status))

    def test_database_failure_stops_site_creation(self):
        for profile in ("wordpress", "loom73"):
            with self.subTest(profile=profile):
                result = self.prepare(profile, db_status=70)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertNotIn("CALL host", result.stdout)
                self.assertNotIn("Preparation completed", result.stdout)

    def test_site_failure_is_not_success(self):
        result = self.prepare("wordpress", host_status=73)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("database was intentionally not removed", result.stderr)
        self.assertNotIn("Preparation completed", result.stdout)

    def test_generic_skips_database(self):
        result = self.prepare("generic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("CALL database", result.stdout)
        self.assertIn("CALL host <-t> <generic>", result.stdout)

    def test_wordpress_argument_forwarding_and_order(self):
        result = self.prepare("wordpress")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index("CALL database"), result.stdout.index("CALL host"))
        self.assertIn("<-d> <app_db> <-u> <app_user>", result.stdout)
        self.assertIn("<-a> <www.example.com> <-v> <6.8.2> <-l> <en_US>", result.stdout)

    def test_loom_preserves_deployment_handoff(self):
        result = self.prepare("loom73")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("<-o> <deploy>", result.stdout)
        self.assertNotIn("<-v>", result.stdout)
        self.assertIn("Run Shuttle", result.stdout)


class SecurityRegressions(unittest.TestCase):
    def test_apache_logs_are_outside_application_tree(self):
        for name in ("vhost.blueprint.conf", "vhost.loom73.blueprint.conf"):
            with self.subTest(blueprint=name):
                text = source_text("blueprints/" + name)
                directives = re.findall(r'^\s*(?:ErrorLog|CustomLog)\s+"([^"]+)"', text, re.MULTILINE)
                self.assertEqual(len(directives), 2)
                for path in directives:
                    self.assertTrue(path.startswith("${APACHE_LOG_DIR}/"),
                                    "Apache must not open logs beneath a site-writable parent: " + path)


class TrustedPaths(unittest.TestCase):
    def test_shared_path_helpers_are_identical(self):
        for name in ("require_trusted_directory", "trusted_directory_chain"):
            self.assertEqual(function(name, "addhost.sh"), function(name, "wphost.sh"))

    def test_parent_metadata_policy(self):
        code = function("require_trusted_directory", "addhost.sh") + r'''
test_metadata=$1
stat() { printf '%s' "$test_metadata"; }
require_trusted_directory /
'''
        for metadata in ("0:755", "0:700", "0:2755"):
            with self.subTest(metadata=metadata):
                result = bash(code, metadata)
                self.assertEqual(result.returncode, 0, result.stderr)
        for metadata in ("1000:755", "0:775", "0:757", "0:1777", "0:invalid", "0:888"):
            with self.subTest(metadata=metadata):
                result = bash(code, metadata)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_chain_validates_before_any_creation_and_visits_all_ancestors(self):
        code = function("trusted_directory_chain", "addhost.sh") + r'''
require_trusted_directory() { printf 'CHECK %s\n' "$1"; }
mkdir() { printf 'UNEXPECTED CREATE\n'; return 99; }
trusted_directory_chain "$1" false
'''
        result = bash(code, "/var/www/clients")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "CHECK /\nCHECK /var\nCHECK /var/www\nCHECK /var/www/clients\n")
        for path in ("relative", "/var/../etc", "/var/./www", "/var//www",
                     "/var/www/", "/var/www\nother", "/var/.hidden"):
            with self.subTest(path=path):
                result = bash(code, path)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")


class MySQLGrants(unittest.TestCase):
    def render(self, name, mode, create="false", password=""):
        code = "\n".join(function(fn, "setmysql.sh") for fn in (
            "validate_database_name", "database_grant_identifier",
            "escape_sql_string", "emit_mysql_configuration",
        )) + r'''
database_name=$1
database_user=app_user
grant_database_name=$(database_grant_identifier "$database_name" "$2")
create_database_user=$3
escaped_password=$(escape_sql_string "$4")
emit_mysql_configuration
'''
        return bash(code, name, mode, create, password)

    def test_grant_scope_for_both_modes(self):
        for name in ("appdb", "app_db", "app_test_db", "_app_", "a" * 64):
            for mode in ("OFF", "ON"):
                with self.subTest(name=name, mode=mode):
                    result = self.render(name, mode)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    grant = name.replace("_", "\\_") if mode == "OFF" else name
                    self.assertIn(f"CREATE DATABASE IF NOT EXISTS `{name}`;", result.stdout)
                    self.assertIn(f"GRANT ALL PRIVILEGES ON `{grant}`.* TO 'app_user'@'localhost';", result.stdout)
                    self.assertNotIn("CREATE USER", result.stdout)
                    self.assertNotIn("ON *.*", result.stdout)
                    self.assertNotIn("GRANT OPTION", result.stdout)

    def test_new_user_password_is_quoted_without_changing_database_name(self):
        result = self.render("app_db", "OFF", "true", "test'quote\\backslash")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';", result.stdout)
        self.assertIn("IDENTIFIED BY 'test''quote\\backslash';", result.stdout)
        self.assertIn("CREATE DATABASE IF NOT EXISTS `app_db`;", result.stdout)
        self.assertIn("GRANT ALL PRIVILEGES ON `app\\_db`.*", result.stdout)

    def test_invalid_mode_or_identifier_emits_no_sql(self):
        for name, mode in (("app_db", ""), ("app_db", "unknown"),
                           ("app%db", "OFF"), ("app`db", "ON")):
            with self.subTest(name=name, mode=mode):
                result = self.render(name, mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_preflight_response(self):
        code = function("parse_mysql_preflight", "setmysql.sh") + r'''
parse_mysql_preflight "$1"
printf '%s:%s' "$user_exists" "$partial_revokes"
'''
        for exists in ("0", "1"):
            for mode in ("OFF", "ON"):
                with self.subTest(exists=exists, mode=mode):
                    result = bash(code, f"{exists}\npartial_revokes\t{mode}")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, f"{exists}:{mode}")
            with self.subTest(exists=exists, mode="legacy"):
                result = bash(code, exists)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"{exists}:OFF")

        for response in ("", "2", "0\npartial_revokes\tUNKNOWN",
                         "1\npartial_revokes\tON\nextra", "1\nother\tOFF"):
            with self.subTest(response=response):
                result = bash(code, response)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
