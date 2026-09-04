# server-tools

Bash scripts maintained by Level73 to prepare website and PHP application environments on an existing Linux server.

The suite creates Apache virtual hosts, dedicated system accounts and PHP-FPM pools, MySQL databases and users, and optional Let's Encrypt certificates. It supports generic websites, WordPress and Loom73.

It does not install the server stack or deploy application releases.

## Engineering approach

We automate repeatable server configuration and keep application initialization separate. The result is ordinary Apache and PHP-FPM configuration that can be inspected and maintained without the scripts.

Profiles make operational choices explicit: which account runs PHP, where the public directory lives, whether a database is required, and when a virtual host becomes active. These scripts are provisioning tools, not a desired-state configuration manager. Failed runs can leave completed steps in place; recovery starts by inspecting that state.

## Requirements

The scripts target a Debian/Ubuntu-style server layout with systemd and GNU command-line utilities. They are not a distribution-independent installer.

Required for site provisioning:

- Bash and the system utilities used by the scripts, including Linux account-management tools and util-linux `runuser`.
- Root privileges through `sudo` or a root session.
- Apache 2.4, with `a2ensite`, `a2dissite` and `apache2ctl` available.
- Apache modules `proxy`, `proxy_fcgi`, `headers` and `rewrite`. Loom73 also requires `expires` and `mime`.
- PHP-FPM **8.4**, using `php8.4-fpm.service`, `/usr/sbin/php-fpm8.4` and `/etc/php/8.4/fpm/pool.d`.
- An existing, root-owned `/var/www` directory and the `www-data` account and group used for PHP-FPM socket access. See the path requirements below before using nested site paths.

PHP 8.4 is currently fixed in the scripts, not an optional recommendation. Review the scripts and blueprints before using another PHP version or server layout.

Additional requirements depend on the operation:

| Operation | Requirements |
| --- | --- |
| WordPress or Loom73 database provisioning | Local MySQL server and client; administrative access as `root@localhost` using a password |
| WordPress download | PHP CLI and [WP-CLI](https://make.wordpress.org/cli/handbook/guides/installing/) |
| Loom73 preparation | An existing non-root deploy account |
| Certificate issuance | Certbot with its Apache plugin, `curl`, correct public DNS and reachable HTTP/HTTPS ports |

Install and maintain these dependencies separately. For Certbot, follow the [official instructions for the target operating system](https://certbot.eff.org/instructions). Check that the plugin list includes `apache`:

```bash
certbot --version
certbot plugins
```

Application-specific PHP extensions and services remain application requirements. The suite does not install or validate all of them.

## Installation

Clone the repository, review its scripts and blueprints, then run from the repository directory:

```bash
sudo bash ./install.sh
```

The installer copies `provision`, `addhost`, `wphost`, `setmysql` and `setssl` into `/usr/local/bin`, without the `.sh` suffix. Blueprints are installed in `/usr/local/bin/blueprints`.

If installed files differ, installation stops before replacing them. To apply a reviewed update:

```bash
sudo bash ./install.sh -f
```

Identical files are skipped. Replacement is atomic per file, not across the whole suite. Installing updated blueprints does not change existing virtual hosts or pools, and installation does not reload services.

The examples below use installed commands. Keep shell scripts in LF format; the repository includes `.gitattributes` for this purpose.

## Provisioning workflow

Use `provision` as the entry point. Individual scripts remain available for specific operations.

```bash
provision -h
provision prepare -h
provision activate -h
```

`prepare` creates the server-side resources for a profile. `activate` validates the public directory and virtual host, enables the host if necessary, reloads Apache, and optionally requests HTTPS.

| Profile | Database created by `prepare` | Public directory beneath `/var/www/<path>` | HTTP virtual host after `prepare` |
| --- | --- | --- | --- |
| `generic` | No | `public_html` | Enabled |
| `wordpress` | Required | `wordpress` | Enabled |
| `loom73` | Required | `public_html/public` | Left disabled |

Every profile gets a dedicated system account and PHP-FPM pool. The `generic` profile also configures PHP; it is not a static-only profile.

Hostnames must be plain names such as `app.example.com`, without a scheme, port or path. `-d` is a path relative to `/var/www`, not an absolute path. Aliases are explicit: repeat `-a` for each additional hostname. No `www` alias is added automatically.

Replace all example domains, account names and database names before running these commands.

### Path ownership and existing directories

The application root is `/var/www/<path>`. Every ancestor, from `/` through `/var/www` to its immediate parent, must be a real directory owned by root, without group or other write permission. Symlinks, including dangling links, are rejected. For `-d clients/example.com`, `/var/www/clients` is an infrastructure container, not a deploy-owned application directory. Missing containers beneath `/var/www` are created with mode `0755`; existing incompatible containers are rejected, not repaired.

The final application root has different ownership by profile:

| Profile | Application root owner and group | Mode |
| --- | --- | --- |
| `generic`, `wordpress` | Site account and site group | `0755` |
| `loom73` | Deploy account and site group | `2751` |

For generic and WordPress sites, `logs` is created as the site account with mode `0750`; generic `public_html` uses `0755`. Existing directories must match the expected ownership and mode and must not be symlinks. The scripts do not recursively repair an existing tree. Inspect a rejected path before changing its permissions, especially when other applications use it.

### Generic website

```bash
sudo provision prepare -t generic \
    -u example.com -a www.example.com -d example.com
```

Deploy the website into `/var/www/example.com/public_html`. The HTTP virtual host is already enabled. An empty directory can return `403` because directory listing is disabled; preparation does not create an index page.

This profile does not create a database. Use `setmysql` separately if the application needs one.

### WordPress

Choose an explicit WordPress release. Replace `X.Y.Z` below with its numeric version; `latest` is not accepted.

```bash
sudo provision prepare -t wordpress \
    -u example.com -a www.example.com -d example.com \
    -b example_wp -r example_wp -v X.Y.Z -l en_US
```

The database step runs first and prompts for the required credentials. WordPress is then downloaded into `/var/www/example.com/wordpress`, its core checksums are verified, and the HTTP virtual host is enabled. The default locale is `en_US`.

Download and verification take place in a private, root-owned staging directory with mode `0700`, under the application root's parent. The verified tree is then moved into place without replacing an existing destination. Staging and the application root must be on the same filesystem; a site root mounted on a different filesystem from its parent is not supported by this workflow.

This prepares WordPress files and a database. It does not create `wp-config.php`, install database tables, create an administrator account or configure plugins. Complete WordPress setup separately, using the database credentials supplied during provisioning. Configure HTTPS before entering administrative credentials through the browser.

WordPress files are owned by the site's PHP-FPM account so that core, plugin and theme updates can run through WordPress, including the MainWP workflow used by Level73. MainWP is not installed or configured by these scripts.

### Loom73

Loom73 is Level73's PHP application foundation. Server preparation must not replace its deployment and initialization workflow.

```bash
sudo provision prepare -t loom73 \
    -u app.example.com -d app.example.com \
    -b app_db -r app_db -o deploy
```

The `deploy` account must already exist. Preparation creates the database and MySQL user, the site account, the application root, the PHP-FPM pool and the virtual host configuration. It adds the deploy account to the site group; start a new login session before relying on that membership.

The application root is owned by the deploy account and site group, with mode `2751`. No application or runtime directories are created. The PHP-FPM pool is enabled, but the Apache virtual host remains disabled.

Continue with the existing application workflow:

1. Deploy Loom73 into `/var/www/app.example.com/public_html`.
2. Configure its `.env`, including the provisioned database credentials.
3. Run Shuttle to create application tables, seed data and runtime directories.
4. Activate the virtual host once the application is ready.

```bash
sudo provision activate -t loom73 \
    -u app.example.com -d app.example.com
```

The expected public root is `/var/www/app.example.com/public_html/public`. Activation refuses a missing public directory. It validates Apache configuration, not application readiness: `.env`, database migrations and application health must be checked separately.

## HTTPS

HTTPS is opt-in during activation. Without `-e`, no certificate operation is performed.

Use real domains under your control. Every requested hostname must resolve to the intended server, including any published IPv6 records. HTTP must be reachable on port 80 for validation and HTTPS on port 443 for normal service. DNS, firewall and proxy configuration are not managed by the suite.

Validate the certificate request first:

```bash
sudo provision activate -t loom73 \
    -u app.example.com -d app.example.com \
    -m admin@example.com -e staging
```

Staging uses Certbot's dry run. No certificate is saved or installed. It is not a read-only operation: activation can enable the virtual host, and Certbot can temporarily change Apache configuration for validation.

Then request or deploy the production certificate:

```bash
sudo provision activate -t loom73 \
    -u app.example.com -d app.example.com \
    -m admin@example.com -e production
```

Use the same activation pattern for `generic` or `wordpress`, with the corresponding profile and path. Repeat `-a` for any certificate aliases; activation does not infer them from an earlier `prepare` command. Configure those aliases on the virtual host and in DNS first.

Production mode requests an HTTP-to-HTTPS redirect and keeps an existing certificate when it is not due for renewal. The script checks Apache configuration and verifies the redirect locally. Check the public endpoint separately:

```bash
curl -sS -o /dev/null -w 'code=%{http_code} redirect=%{redirect_url}\n' \
    http://app.example.com/
curl -I https://app.example.com/
```

The HTTP request should redirect to HTTPS. The HTTPS response depends on the deployed application; a valid certificate alone does not guarantee a working website.

Renewal scheduling belongs to the Certbot installation. Verify its renewal mechanism and test renewal for the certificate:

```bash
sudo certbot renew --cert-name app.example.com --dry-run
```

HSTS is not configured automatically. Apply it separately once the HTTPS policy for the domain and its subdomains has been decided.

## Individual commands

| Command | Responsibility |
| --- | --- |
| `provision` | Coordinate preparation and activation |
| `addhost` | Create the site account, directories, PHP-FPM pool and Apache virtual host; invoke `wphost` for WordPress |
| `wphost` | Download and verify WordPress files with site-specific ownership |
| `setmysql` | Create a MySQL database and user, and grant access to that database |
| `setssl` | Validate or install a certificate through Certbot and check the production redirect |

Use each command's `-h` option for its arguments. Calling `addhost` directly does not provision a database or request a certificate.

## Logs

- Apache access and error logs use `${APACHE_LOG_DIR}`, as configured by Apache, outside the application tree.
- PHP application errors for generic and WordPress sites use `/var/www/<path>/logs/php-error.log`.
- PHP application errors for Loom73 use `syslog`.

Apache logging and PHP application logging are configured separately. The suite does not configure log rotation or retention; review these for each destination. Updating a blueprint does not migrate existing virtual hosts or PHP-FPM pools.

## Checks

Run the non-privileged regression suite from the repository root, without `sudo`:

```bash
python3 -B -m unittest discover -s tests -p test_safety.py -v
```

It requires Python 3.8+ and Bash. The 20 tests cover syntax, input validation, SQL generation, mocked orchestration and path-policy checks. To check all scripts with ShellCheck separately:

```bash
shellcheck --severity=style ./*.sh
```

The **Path safety checks** GitHub Actions workflow is started manually from the repository's Actions tab. It runs the 20 ordinary tests, followed by 14 filesystem tests on a separate GitHub-hosted Ubuntu 24.04 runner with root privileges. No deployment secrets or VPS connection are required. Use reviewed revisions and GitHub-hosted runners, not a production self-hosted runner.

The filesystem tests exercise ownership, permissions, symlinks and WordPress tree publication using temporary fixtures. They do not provision Apache, PHP-FPM, MySQL or certificates, or perform a full WordPress installation. Passing them is not an end-to-end deployment check. ShellCheck and secret scanning are not part of this manual workflow. See [tests/README.md](tests/README.md) for scope and local Linux execution.

## Security and operational limits

- **Root-level changes.** Review the scripts and installed blueprints before use. They modify system accounts, groups, server configuration and application directories. Use backups and a test environment appropriate to the server.
- **Trusted administration and tooling.** Path checks assume normal Linux ownership and permissions, trusted administrators and no concurrent privileged mount or path reconfiguration. `wphost` invokes WP-CLI as root from its private staging directory; its executable, packages and applicable configuration must be trusted. Private staging does not sandbox WP-CLI.
- **Dedicated PHP identities, not a sandbox.** Each site runs PHP under a separate account. This reduces the use of shared credentials and ownership, but does not provide container isolation or prevent access to files readable by other users.
- **Writable WordPress code.** Site ownership permits WordPress and MainWP updates. It also permits a compromised PHP process to modify that site's application code. This is an operational trade-off, not an uploads-only permission model.
- **Application secrets remain an application responsibility.** The suite does not write `.env` or WordPress configuration. Set their permissions as part of deployment so that only the intended accounts can read them.
- **Database credentials are interactive.** Passwords are not command-line arguments. Existing MySQL users keep their passwords and any pre-existing grants; the scripts do not reconcile or remove those grants. Use a distinct database account for each application.
- **Preparation is not a general-purpose rerun operation.** Existing virtual host files are rejected. The database step may already have succeeded before a later step fails. Inspect databases, accounts, directories and configurations before retrying.
- **There is no suite-wide transaction.** Some steps attempt local cleanup, but a failure does not undo every earlier change. In particular, an SSL failure does not undo HTTP activation and may leave Certbot changes to inspect.

## License

GNU GPL v3. See [LICENSE](LICENSE).
