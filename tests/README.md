# Regression tests

## Non-privileged checks

From the repository root:

```bash
python3 -B -m unittest discover -s tests -v
```

Requires Python 3.8+ and Bash, with no Python packages. The 20 tests in `test_safety.py` cover syntax, validators, MySQL SQL generation, mocked orchestration, root-directory metadata policy and ancestor traversal. Production functions are extracted by name; entire provisioning scripts are never sourced. Keep the duplicated parent-check functions in addhost and wphost identical; a test checks this.

The suite refuses to run `test_safety.py` as root. The separate Linux fixture class is skipped during ordinary discovery. A green ordinary test run does not mean the privileged filesystem tests have run.

`SERVER_TOOLS_ROOT` can select another checkout and `BASH_BIN` can select a Bash executable. On Windows, Git Bash permits the non-privileged checks, but does not validate Linux ownership, runuser or filesystem semantics.

## Opt-in Linux filesystem checks

Run this separately on a disposable Linux machine after reviewing the test:

```bash
sudo env SERVER_TOOLS_RUN_PRIVILEGED_TESTS=1 \
    python3 -B tests/test_paths_linux.py
```

This test requires GNU tools, util-linux `runuser`, the existing `nobody` account, and root-managed `/var/lib` with safe ancestors. It creates only an isolated `/var/lib/server-tools-r04-tests.*` fixture. It creates no accounts and uses no network, Apache, PHP-FPM, MySQL, Certbot or WordPress download.

The 14 tests exercise actual directory ownership, permissions and symlinks; site-user directory creation; refusal to repair existing metadata; an injected link between check and mkdir; private staging; no-overwrite publication; simulated differing filesystem devices; silent mv skip handling; and bounded staging cleanup.

The fixture is removed on normal completion, including ordinary test failures. An interrupted process may leave the printed test namespace discoverable under `/var/lib/server-tools-r04-tests.*`; inspect its exact path before any manual cleanup. Never use a broad wildcard deletion.

These are helper-level filesystem tests, not a full provisioning integration test or proof against all concurrent operations. After they pass, verify one new generic, WordPress and Loom73 environment on a disposable host. In particular, Loom73 must continue to leave application/runtime directories absent and its virtual host disabled after preparation.
