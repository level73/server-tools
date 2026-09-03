#!/bin/bash

set -Eeuo pipefail

usage() {
    local command_name=${0##*/}

    printf '%s\n' \
        "Usage: $command_name [OPTIONS]" \
        '' \
        'Create an isolated Apache/PHP-FPM site environment.' \
        '' \
        'Options:' \
        '  -t PROFILE      Site profile: wordpress, generic or loom73.' \
        '                  Defaults to wordpress when omitted.' \
        '  -u HOSTNAME     Primary hostname, for example app.example.com.' \
        '  -a HOSTNAME     Additional ServerAlias; repeat for more aliases.' \
        '  -d PATH         Site path relative to /var/www.' \
        '                  Do not include a leading or trailing slash.' \
        '  -o USER         Existing deploy user; valid only for loom73.' \
        '  -v VERSION      WordPress version; valid only for the wordpress profile.' \
        '  -l LOCALE       WordPress locale; defaults to en_US.' \
        '  -h              Show this help message and exit.' \
        '' \
        'Profiles:' \
        '  wordpress       Installs WordPress in PATH/wordpress.' \
        '  generic         Creates PATH/public_html.' \
        '  loom73          Prepares the server environment; leaves the vhost disabled.' \
        '' \
        'Examples:' \
        "  sudo $command_name -t generic -u example.com -d example.com" \
        "  sudo $command_name -t wordpress -u example.com \\" \
        '      -a www.example.com -d example.com' \
        "  sudo $command_name -t loom73 -u app.example.com \\" \
        '      -d app.example.com -o deploy'
}



validate_site_user() {
    [[ ${1-} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

derive_site_user() {
    local hostname=${1-}
    local prefix=${2-}
    local slug
    local digest

    [[ $prefix =~ ^[a-z][a-z0-9_]*$ ]] || {
        printf 'Error: invalid site user prefix: %q\n' "$prefix" >&2
        return 1
    }

    slug=${hostname//./_}
    slug=${slug//-/_}

    if ! digest=$(printf '%s' "$hostname" | sha256sum); then
        printf 'Error: unable to derive site user\n' >&2
        return 1
    fi

    digest=${digest%% *}

    printf -v SITE_USER '%s_%s_%s' \
        "$prefix" \
        "${slug:0:18}" \
        "${digest:0:8}"

    if ! validate_site_user "$SITE_USER"; then
        printf 'Error: generated invalid site user: %q\n' \
            "$SITE_USER" >&2
        return 1
    fi
}

resolve_or_create_site_user() {
    local expected_home=${1-}
    local passwd_entry
    local account_name
    local account_password
    local account_uid
    local account_gid
    local account_gecos
    local account_home
    local account_shell

    if passwd_entry=$(getent passwd "$SITE_USER"); then
        IFS=':' read -r \
            account_name \
            account_password \
            account_uid \
            account_gid \
            account_gecos \
            account_home \
            account_shell \
            <<< "$passwd_entry"

        if [[ $account_name != "$SITE_USER" ]]; then
            printf 'Error: inconsistent account record for %q\n' \
                "$SITE_USER" >&2
            return 1
        fi

        if [[ $account_uid == 0 ]]; then
            printf 'Error: root cannot be used as site user\n' >&2
            return 1
        fi

        if [[ $account_home != "$expected_home" ]]; then
            printf 'Error: existing site user has unexpected home\n' >&2
            printf 'User:     %s\n' "$SITE_USER" >&2
            printf 'Expected: %s\n' "$expected_home" >&2
            printf 'Current:  %s\n' "$account_home" >&2
            return 1
        fi

        if [[ $account_shell != "$SITE_SHELL" &&
              $account_shell != '/bin/false' ]]
        then
            printf 'Error: existing site user has an interactive shell: %s\n' \
                "$account_shell" >&2
            return 1
        fi

        site_user_created=false
    else
        if ! useradd \
            --system \
            --user-group \
            --no-create-home \
            --home-dir "$expected_home" \
            --shell "$SITE_SHELL" \
            -- "$SITE_USER"
        then
            printf 'Error: unable to create site user: %s\n' \
                "$SITE_USER" >&2
            return 1
        fi

        site_user_created=true
    fi

    if ! SITE_UID=$(id -u -- "$SITE_USER"); then
        printf 'Error: unable to resolve UID for %s\n' "$SITE_USER" >&2
        return 1
    fi

    if ! SITE_GID=$(id -g -- "$SITE_USER"); then
        printf 'Error: unable to resolve GID for %s\n' "$SITE_USER" >&2
        return 1
    fi

    if ! SITE_GROUP=$(id -gn -- "$SITE_USER"); then
        printf 'Error: unable to resolve group for %s\n' "$SITE_USER" >&2
        return 1
    fi

    if [[ $SITE_GROUP != "$SITE_USER" ]]; then
        printf 'Error: site user does not have a dedicated primary group\n' >&2
        printf 'User:  %s\n' "$SITE_USER" >&2
        printf 'Group: %s\n' "$SITE_GROUP" >&2
        return 1
    fi
}

resolve_deploy_user() {
    local requested_user=${1-}
    local passwd_entry
    local account_name
    local account_password
    local account_uid
    local account_gid
    local account_gecos
    local account_home
    local account_shell

    if ! validate_site_user "$requested_user"; then
        printf 'Error: invalid deploy user: %q\n' \
            "$requested_user" >&2
        return 1
    fi

    if ! passwd_entry=$(getent passwd "$requested_user"); then
        printf 'Error: deploy user does not exist: %s\n' \
            "$requested_user" >&2
        return 1
    fi

    IFS=':' read -r \
        account_name \
        account_password \
        account_uid \
        account_gid \
        account_gecos \
        account_home \
        account_shell \
        <<< "$passwd_entry"

    if [[ $account_name != "$requested_user" ]]; then
        printf 'Error: inconsistent deploy user record\n' >&2
        return 1
    fi

    if [[ $account_uid == 0 ]]; then
        printf 'Error: root cannot be used as deploy user\n' >&2
        return 1
    fi

    case "$account_shell" in
        /usr/sbin/nologin|/sbin/nologin|/bin/false)
            printf 'Error: deploy user has a non-interactive shell: %s\n' \
                "$account_shell" >&2
            return 1
            ;;
    esac

    DEPLOY_USER=$account_name
    DEPLOY_UID=$account_uid
    DEPLOY_GID=$account_gid
}

validate_hostname() {
    local hostname=${1-}
    local label
    local label_regex='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    local -a labels

    [[ -n $hostname ]] || return 1
    (( ${#hostname} <= 253 )) || return 1

    # Allowlist applied to whole string.
    # Refuses whitespace, newline, slash, colon, wildcard and Unicode.
    [[ $hostname =~ ^[a-z0-9.-]+$ ]] || return 1

    # No starting/ending with dots or empty labels.
    [[ $hostname != .* ]] || return 1
    [[ $hostname != *. ]] || return 1
    [[ $hostname != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$hostname"

    # Requires at least "example.com".
    # For local hosts, use something like  "myapp.test".
    (( ${#labels[@]} >= 2 )) || return 1

    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ $label =~ $label_regex ]] || return 1
    done
}

validate_relative_doc_root() {
    local relative_path=${1-}
    local component
    local component_regex='^[A-Za-z0-9][A-Za-z0-9._-]*$'
    local -a components

    [[ -n $relative_path ]] || return 1
    (( ${#relative_path} <= 2048 )) || return 1

    # Full string: only explicitly allowed characters.
    # Refuses whitespace, newline, backslash, wildcard and Unicode.
    [[ $relative_path =~ ^[A-Za-z0-9._/-]+$ ]] || return 1

    # Must be relative and normalized.
    [[ $relative_path != /* ]] || return 1
    [[ $relative_path != */ ]] || return 1
    [[ $relative_path != *//* ]] || return 1

    IFS='/' read -r -a components <<< "$relative_path"

    for component in "${components[@]}"; do
        # Blocks ".", ".." and hidden directories.
        [[ $component =~ $component_regex ]] || return 1
        (( ${#component} <= 255 )) || return 1
    done
}
validate_wordpress_version() {
    [[ ${1-} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

validate_wordpress_locale() {
    [[ ${1-} =~ ^[A-Za-z][A-Za-z0-9_.@-]{1,31}$ ]]
}

# Configuration
if ! current_directory=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
); then
    printf 'Error: unable to determine script directory\n' >&2
    exit 72
fi

readonly PHP_VERSION='8.4'
readonly PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
readonly PHP_FPM_BINARY="/usr/sbin/php-fpm${PHP_VERSION}"
readonly PHP_POOL_DIRECTORY="/etc/php/${PHP_VERSION}/fpm/pool.d"
readonly PHP_SOCKET_DIRECTORY='/run/php'
readonly SITE_SHELL='/usr/sbin/nologin'

php_pool_blueprint="${current_directory}/blueprints/php-fpm-pool.blueprint.conf"

vhosts_path="/etc/apache2/sites-available"
vhost_blueprint="$current_directory/blueprints/vhost.blueprint.conf"
web_root="/var/www"

# CLI input
site_url=''
relative_doc_root=''
site_profile=''
deploy_user=''
site_aliases=()

wordpress_version=''
wordpress_locale='en_US'
wordpress_options_used=false

DEPLOY_USER=''
DEPLOY_UID=''
DEPLOY_GID=''

while getopts ':u:d:a:t:o:v:l:h' option; do
    case "$option" in
        u)
            site_url=$OPTARG
            ;;
        d)
            relative_doc_root=$OPTARG
            ;;
        a)
            site_aliases+=("${OPTARG,,}")
            ;;
        t)
            site_profile=${OPTARG,,}
            ;;
        o)
            deploy_user=$OPTARG
            ;;
        h)
            usage
            exit 0
            ;;
        v)
            wordpress_version=$OPTARG
            wordpress_options_used=true
            ;;
        l)
            wordpress_locale=$OPTARG
            wordpress_options_used=true
            ;;
        :)
            printf 'Error: -%s requires an argument\n' "$OPTARG" >&2
            usage >&2
            exit 64
            ;;
        \?)
            printf 'Error: unknown option: -%s\n' "$OPTARG" >&2
            usage >&2
            exit 64
            ;;
    esac
done

shift "$((OPTIND - 1))"

if (( $# > 0 )); then
    printf 'Error: unexpected positional arguments\n' >&2
    usage >&2
    exit 64
fi
# Requires sudo
if (( EUID != 0 )); then
    printf 'Error: root privileges are required; run with sudo\n' >&2
    exit 77
fi

for required_command in \
    sha256sum \
    getent \
    id \
    useradd
do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' \
            "$required_command" >&2
        exit 69
    fi
done


if [[ -z $site_profile ]]; then
    if ! IFS= read -r \
        -p "Site profile [wordpress/generic/loom73] (default: wordpress): " \
        site_profile
    then
        printf '\nError: unable to read site profile\n' >&2
        exit 64
    fi

    site_profile=${site_profile,,}
    site_profile=${site_profile:-wordpress}
fi

case "$site_profile" in
    wordpress)
        install_dir='wordpress'
        site_user_prefix='wp'
        ;;

    generic)
        install_dir='public_html'
        site_user_prefix='site'
        ;;

    loom73)
        install_dir=''
        site_user_prefix='loom'
        vhost_blueprint="${current_directory}/blueprints/vhost.loom73.blueprint.conf"
        ;;

    *)
        printf 'Error: unsupported site profile: %q\n' \
            "$site_profile" >&2
        printf 'Expected: wordpress, generic or loom73\n' >&2
        exit 64
        ;;
esac

if [[ $site_profile == 'wordpress' ]]; then
    if [[ -z $wordpress_version ]]; then
        if ! IFS= read -r \
            -p 'WordPress version to install: ' \
            wordpress_version
        then
            printf '\nError: unable to read WordPress version\n' >&2
            exit 64
        fi
    fi

    if ! validate_wordpress_version "$wordpress_version"; then
        printf 'Error: invalid WordPress version: %q\n' \
            "$wordpress_version" >&2
        exit 64
    fi

    if ! validate_wordpress_locale "$wordpress_locale"; then
        printf 'Error: invalid WordPress locale: %q\n' \
            "$wordpress_locale" >&2
        exit 64
    fi
elif [[ $wordpress_options_used == true ]]; then
    printf 'Error: -v and -l can only be used with -t wordpress\n' >&2
    exit 64
fi

readonly wordpress_version wordpress_locale


if [[ $site_profile == 'loom73' ]]; then
    if [[ -z $deploy_user ]]; then
        if ! IFS= read -r \
            -p "Existing Loom73 deploy user: " \
            deploy_user
        then
            printf '\nError: unable to read deploy user\n' >&2
            exit 64
        fi
    fi

    if ! resolve_deploy_user "$deploy_user"; then
        exit 77
    fi
elif [[ -n $deploy_user ]]; then
    printf 'Error: -o can only be used with -t loom73\n' >&2
    exit 64
fi

readonly site_profile install_dir site_user_prefix
readonly DEPLOY_USER DEPLOY_UID DEPLOY_GID

if [[ -z $site_url ]]; then
    IFS= read -r -p "Please enter the desired hostname: " site_url
fi

site_url=${site_url,,}

if ! validate_hostname "$site_url"; then
    printf 'Error: invalid hostname: %q\n' "$site_url" >&2
    printf 'Expected format: example.com or app.example.com\n' >&2
    exit 64
fi

declare -A seen_aliases=()

for site_alias in "${site_aliases[@]}"; do
    if ! validate_hostname "$site_alias"; then
        printf 'Error: invalid site alias: %q\n' \
            "$site_alias" >&2
        exit 64
    fi

    if [[ $site_alias == "$site_url" ]]; then
        printf 'Error: site alias duplicates the primary hostname: %s\n' \
            "$site_alias" >&2
        exit 64
    fi

    if [[ -n ${seen_aliases[$site_alias]+present} ]]; then
        printf 'Error: duplicate site alias: %s\n' \
            "$site_alias" >&2
        exit 64
    fi

    seen_aliases["$site_alias"]=1
done

readonly -a site_aliases

# Relative doc root
if [[ -z $relative_doc_root ]]; then
    IFS= read -r \
        -p "Please enter the site path relative to $web_root: " \
        relative_doc_root
fi

if ! validate_relative_doc_root "$relative_doc_root"; then
    printf 'Error: invalid relative document root: %q\n' \
        "$relative_doc_root" >&2
    printf 'Expected format: example.com or clients/example.com\n' >&2
    exit 64
fi

if ! command -v realpath >/dev/null 2>&1; then
    printf 'Error: required command not found: realpath\n' >&2
    exit 69
fi

canonical_web_root=$(realpath -e -- "$web_root") || {
    printf 'Error: web root does not exist: %s\n' "$web_root" >&2
    exit 72
}

absolute_doc_root=$(
    realpath -m -- "$canonical_web_root/$relative_doc_root"
) || {
    printf 'Error: unable to resolve document root\n' >&2
    exit 72
}

# Additional guard: the resolved path must be a descendant
# of the webroot, not the webroot itself.
if [[ $absolute_doc_root != "$canonical_web_root/"* ]]; then
    printf 'Error: document root escapes the web root: %q\n' \
        "$absolute_doc_root" >&2
    exit 64
fi

if [[ -e $absolute_doc_root && ! -d $absolute_doc_root ]]; then
    printf 'Error: document root exists but is not a directory: %s\n' \
        "$absolute_doc_root" >&2
    exit 73
fi

site_user_created=false

if ! derive_site_user "$site_url" "$site_user_prefix"; then
    exit 77
fi
if ! resolve_or_create_site_user "$absolute_doc_root"; then
    exit 77
fi
readonly SITE_UID SITE_GID SITE_USER SITE_GROUP
printf 'Site identity: %s:%s (UID %s, GID %s)\n' \
    "$SITE_USER" "$SITE_GROUP" "$SITE_UID" "$SITE_GID"
if [[ $site_user_created == true ]]; then
    printf 'Created dedicated site account: %s\n' "$SITE_USER"
else
    printf 'Reusing dedicated site account: %s\n' "$SITE_USER"
fi

php_pool_name=$SITE_USER
php_socket="${PHP_SOCKET_DIRECTORY}/php${PHP_VERSION}-fpm-${SITE_USER}.sock"
php_pool_file="${PHP_POOL_DIRECTORY}/${php_pool_name}.conf"

readonly php_pool_name php_socket php_pool_file

# Configure ownership for the selected profile
if [[ $site_profile == 'loom73' ]]; then
    if ! command -v usermod >/dev/null 2>&1; then
        printf 'Error: required command not found: usermod\n' >&2
        exit 69
    fi

    if ! deploy_groups=$(id -G -- "$DEPLOY_USER"); then
        printf 'Error: unable to inspect groups for deploy user: %s\n' \
            "$DEPLOY_USER" >&2
        exit 77
    fi

    case " $deploy_groups " in
        *" $SITE_GID "*)
            printf 'Deploy user already belongs to site group: %s\n' \
                "$SITE_GROUP"
            ;;

        *)
            if ! usermod \
                --append \
                --groups "$SITE_GROUP" \
                "$DEPLOY_USER"
            then
                printf 'Error: unable to add deploy user %s to group %s\n' \
                    "$DEPLOY_USER" "$SITE_GROUP" >&2
                exit 77
            fi

            if ! deploy_groups=$(id -G -- "$DEPLOY_USER"); then
                printf 'Error: unable to verify deploy user groups\n' >&2
                exit 77
            fi

            case " $deploy_groups " in
                *" $SITE_GID "*)
                    printf 'Added deploy user %s to site group %s\n' \
                        "$DEPLOY_USER" "$SITE_GROUP"
                    printf 'A new login session is required before using the new group.\n'
                    ;;

                *)
                    printf 'Error: deploy user group assignment was not applied\n' \
                        >&2
                    exit 77
                    ;;
            esac
            ;;
    esac

    root_owner_uid=$DEPLOY_UID
    root_owner_name=$DEPLOY_USER
    root_mode='2751'
else
    root_owner_uid=$SITE_UID
    root_owner_name=$SITE_USER
    root_mode='0755'
fi

expected_owner="${root_owner_uid}:${SITE_GID}"

# Create or verify the application root
if [[ -d $absolute_doc_root ]]; then
    if ! current_owner=$(
        stat -c '%u:%g' -- "$absolute_doc_root"
    ); then
        printf 'Error: unable to inspect application root: %s\n' \
            "$absolute_doc_root" >&2
        exit 73
    fi

    if [[ $current_owner != "$expected_owner" ]]; then
        printf 'Error: application root has unexpected ownership.\n' >&2
        printf 'Path:     %s\n' "$absolute_doc_root" >&2
        printf 'Expected: %s\n' "$expected_owner" >&2
        printf 'Current:  %s\n' "$current_owner" >&2
        printf 'Refusing to modify an existing tree recursively.\n' >&2
        exit 73
    fi

    # The setgid bit is required for Loom73 so that Shuttle-created
    # runtime directories inherit the dedicated site group.
    if [[ $site_profile == 'loom73' ]]; then
        if ! current_mode=$(stat -c '%a' -- "$absolute_doc_root"); then
            printf 'Error: unable to inspect application root mode\n' >&2
            exit 73
        fi

        if [[ $current_mode != "$root_mode" ]]; then
            printf 'Error: Loom73 application root has unexpected mode.\n' \
                >&2
            printf 'Path:     %s\n' "$absolute_doc_root" >&2
            printf 'Expected: %s\n' "$root_mode" >&2
            printf 'Current:  %s\n' "$current_mode" >&2
            printf 'Refusing to change an existing directory automatically.\n' \
                >&2
            exit 73
        fi
    fi

    printf 'Application root already exists: %s\n' \
        "$absolute_doc_root"
else
    if ! mkdir -p -- "$absolute_doc_root"; then
        printf 'Error: unable to create application root: %s\n' \
            "$absolute_doc_root" >&2
        exit 73
    fi

    # chown may clear setgid, so chmod must run afterwards.
    if ! chown \
        "${root_owner_uid}:${SITE_GID}" \
        "$absolute_doc_root"
    then
        printf 'Error: unable to set application root ownership: %s\n' \
            "$absolute_doc_root" >&2
        exit 73
    fi

    if ! chmod "$root_mode" "$absolute_doc_root"; then
        printf 'Error: unable to set application root permissions: %s\n' \
            "$absolute_doc_root" >&2
        exit 73
    fi

    printf 'Created application root %s owned by %s:%s, mode %s\n' \
        "$absolute_doc_root" \
        "$root_owner_name" \
        "$SITE_GROUP" \
        "$root_mode"
fi

# Loom73 application files and runtime directories are created later
# by the GitHub deploy and Shuttle.
if [[ $site_profile == 'loom73' ]]; then
    site_public_root="$absolute_doc_root/public_html/public"
    php_error_log='syslog'

    printf 'Loom73 deploy root: %s\n' "$absolute_doc_root"
    printf 'Expected public root after deploy: %s\n' \
        "$site_public_root"
else
    site_public_root="$absolute_doc_root/$install_dir"
    logs_dir="$absolute_doc_root/logs"
    php_error_log="$logs_dir/php-error.log"

    if [[ -e $logs_dir && ! -d $logs_dir ]]; then
        printf 'Error: logs path exists but is not a directory: %s\n' \
            "$logs_dir" >&2
        exit 73
    fi

    if ! install -d \
        -m 0750 \
        -o "$SITE_UID" \
        -g "$SITE_GID" \
        -- "$logs_dir"
    then
        printf 'Error: unable to create logs directory: %s\n' \
            "$logs_dir" >&2
        exit 73
    fi

    printf 'Installation directory: %s\n' "$site_public_root"
fi

readonly site_public_root php_error_log

printf 'Absolute Doc Root is: %s\n' "$absolute_doc_root"

# Create or verify the dedicated PHP-FPM pool
for required_command in cmp mktemp ln rm stat chown chmod systemctl sleep; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' \
            "$required_command" >&2
        exit 69
    fi
done

if [[ ! -f $php_pool_blueprint ||
      ! -r $php_pool_blueprint ]]
then
    printf 'Error: PHP-FPM pool blueprint is unavailable: %s\n' \
        "$php_pool_blueprint" >&2
    exit 66
fi

if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    printf 'Error: PHP-FPM service is not active: %s\n' \
        "$PHP_FPM_SERVICE" >&2
    exit 69
fi

# Ensure the existing PHP-FPM configuration is healthy.
if ! "$PHP_FPM_BINARY" -t; then
    printf 'Error: existing PHP-FPM configuration is invalid\n' >&2
    printf 'No PHP-FPM changes have been made.\n' >&2
    exit 78
fi

if ! php_pool=$(<"$php_pool_blueprint"); then
    printf 'Error: unable to read PHP-FPM pool blueprint\n' >&2
    exit 66
fi

php_pool=${php_pool//@pool_name@/$php_pool_name}
php_pool=${php_pool//@site_user@/$SITE_USER}
php_pool=${php_pool//@site_group@/$SITE_GROUP}
php_pool=${php_pool//@php_socket@/$php_socket}
php_pool=${php_pool//@site_docroot@/$absolute_doc_root}
php_pool=${php_pool//@php_error_log@/$php_error_log}


if [[ $php_pool == *'@pool_name@'* ||
      $php_pool == *'@site_user@'* ||
      $php_pool == *'@site_group@'* ||
      $php_pool == *'@php_socket@'* ||
      $php_pool == *'@php_error_log@'* ||
      $php_pool == *'@site_docroot@'* ]]
then
    printf 'Error: unresolved placeholders in PHP-FPM blueprint\n' >&2
    exit 65
fi

if ! php_pool_temp=$(
    mktemp "${PHP_POOL_DIRECTORY}/.${php_pool_name}.conf.XXXXXX"
); then
    printf 'Error: unable to create temporary PHP-FPM pool file\n' >&2
    exit 73
fi

cleanup_php_pool_temp() {
    if [[ -n ${php_pool_temp-} && -e $php_pool_temp ]]; then
        rm -f -- "$php_pool_temp"
    fi
}

trap cleanup_php_pool_temp EXIT

if ! printf '%s\n' "$php_pool" > "$php_pool_temp"; then
    printf 'Error: unable to write PHP-FPM pool configuration\n' >&2
    exit 74
fi

if ! chown root:root "$php_pool_temp" ||
   ! chmod 0644 "$php_pool_temp"
then
    printf 'Error: unable to secure PHP-FPM pool configuration\n' >&2
    exit 73
fi

php_pool_created=false

if [[ -e $php_pool_file || -L $php_pool_file ]]; then
    if [[ -L $php_pool_file || ! -f $php_pool_file ]]; then
        printf 'Error: invalid existing PHP-FPM pool path: %s\n' \
            "$php_pool_file" >&2
        exit 73
    fi

    if ! pool_metadata=$(stat -c '%u:%g:%a' -- "$php_pool_file"); then
        printf 'Error: unable to inspect existing PHP-FPM pool\n' >&2
        exit 73
    fi

    if [[ $pool_metadata != '0:0:644' ]]; then
        printf 'Error: unexpected PHP-FPM pool ownership or mode\n' >&2
        printf 'Expected: 0:0:644\n' >&2
        printf 'Current:  %s\n' "$pool_metadata" >&2
        exit 73
    fi

    if ! cmp -s -- "$php_pool_temp" "$php_pool_file"; then
        printf 'Error: PHP-FPM pool already exists with different content: %s\n' \
            "$php_pool_file" >&2
        exit 73
    fi

    rm -f -- "$php_pool_temp"
    php_pool_temp=''

    printf 'Reusing existing PHP-FPM pool: %s\n' "$php_pool_file"
else
    # Atomic publication that refuses an existing destination.
    if ! ln -- "$php_pool_temp" "$php_pool_file"; then
        printf 'Error: unable to publish PHP-FPM pool: %s\n' \
            "$php_pool_file" >&2
        exit 73
    fi

    php_pool_created=true

    rm -f -- "$php_pool_temp"
    php_pool_temp=''

    printf 'Created PHP-FPM pool: %s\n' "$php_pool_file"
fi
rollback_php_pool() {
    if [[ $php_pool_created != true ]]; then
        return 0
    fi

    printf 'Rolling back PHP-FPM pool: %s\n' \
        "$php_pool_file" >&2

    if ! rm -f -- "$php_pool_file"; then
        printf 'Critical: unable to remove PHP-FPM pool during rollback\n' \
            >&2
        return 1
    fi

    if ! "$PHP_FPM_BINARY" -t; then
        printf 'Critical: PHP-FPM remains invalid after rollback\n' >&2
        return 1
    fi

    if ! systemctl reload "$PHP_FPM_SERVICE"; then
        printf 'Critical: unable to reload PHP-FPM after rollback\n' >&2
        return 1
    fi

    printf 'PHP-FPM pool rollback completed\n' >&2
}

if ! "$PHP_FPM_BINARY" -t; then
    printf 'Error: PHP-FPM rejected the site pool\n' >&2
    rollback_php_pool || true
    exit 78
fi

if ! systemctl reload "$PHP_FPM_SERVICE"; then
    printf 'Error: unable to reload PHP-FPM\n' >&2
    rollback_php_pool || true
    exit 78
fi

# A graceful reload can recreate sockets asynchronously.
for (( socket_attempt = 0; socket_attempt < 20; socket_attempt++ )); do
    if [[ -S $php_socket && ! -L $php_socket ]]; then
        break
    fi

    sleep 0.1
done

if [[ -L $php_socket || ! -S $php_socket ]]; then
    printf 'Error: PHP-FPM socket was not created safely: %s\n' \
        "$php_socket" >&2
    rollback_php_pool || true
    exit 78
fi

if ! socket_metadata=$(
    stat -Lc '%U:%G:%a' -- "$php_socket"
); then
    printf 'Error: unable to inspect PHP-FPM socket\n' >&2
    rollback_php_pool || true
    exit 73
fi

if [[ $socket_metadata != 'www-data:www-data:660' ]]; then
    printf 'Error: unexpected PHP-FPM socket ownership or mode\n' >&2
    printf 'Socket:   %s\n' "$php_socket" >&2
    printf 'Expected: www-data:www-data:660\n' >&2
    printf 'Current:  %s\n' "$socket_metadata" >&2
    rollback_php_pool || true
    exit 73
fi

printf 'PHP-FPM pool enabled successfully: %s\n' "$php_pool_name"
printf 'PHP-FPM socket: %s\n' "$php_socket"

trap - EXIT

is_wordpress_tree() {
    local wordpress_path=${1-}

    [[ -d $wordpress_path ]] &&
    [[ -f $wordpress_path/wp-settings.php ]] &&
    [[ -d $wordpress_path/wp-admin ]] &&
    [[ -d $wordpress_path/wp-content ]] &&
    [[ -d $wordpress_path/wp-includes ]]
}

case "$site_profile" in
    wordpress)
        wordpress_dir="$absolute_doc_root/wordpress"

        if [[ -e $wordpress_dir && ! -d $wordpress_dir ]]; then
            printf 'Error: WordPress path exists but is not a directory: %s\n' \
                "$wordpress_dir" >&2
            exit 73
        fi

        if [[ -d $wordpress_dir ]]; then
            if ! is_wordpress_tree "$wordpress_dir"; then
                printf 'Error: incomplete or invalid WordPress directory: %s\n' \
                    "$wordpress_dir" >&2
                printf 'Refusing to overwrite it.\n' >&2
                exit 73
            fi

            printf 'Existing WordPress installation found: %s\n' \
                "$wordpress_dir"
        else
            sibling_wphost="$current_directory/wphost.sh"
            wphost_command=''

            if [[ -e $sibling_wphost || -L $sibling_wphost ]]; then
                if [[ ! -f $sibling_wphost ||
                      -L $sibling_wphost ||
                      ! -x $sibling_wphost ]]
                then
                    printf 'Error: sibling wphost is not a regular executable: %s\n' \
                        "$sibling_wphost" >&2
                    exit 69
                fi

                wphost_command=$sibling_wphost
            elif ! wphost_command=$(command -v wphost); then
                printf 'Error: required command not found: wphost\n' >&2
                exit 69
            elif [[ $wphost_command != /* ||
                    ! -f $wphost_command ||
                    ! -x $wphost_command ]]
            then
                printf 'Error: wphost does not resolve to an executable file\n' >&2
                exit 69
            fi

            if ! "$wphost_command" \
                -d "$absolute_doc_root" \
                -v "$wordpress_version" \
                -l "$wordpress_locale" \
                -o "$SITE_USER"
            then
                printf 'Error: WordPress installation failed\n' >&2
                exit 70
            fi

            # Don't trust the exit code of wphost.
            if ! is_wordpress_tree "$wordpress_dir"; then
                printf 'Error: WordPress installation is incomplete: %s\n' \
                    "$wordpress_dir" >&2
                exit 70
            fi

            printf 'WordPress installed in: %s\n' "$wordpress_dir"
        fi
        ;;

    generic)
        public_html_dir="$absolute_doc_root/public_html"

        if [[ -e $public_html_dir && ! -d $public_html_dir ]]; then
            printf 'Error: public_html exists but is not a directory: %s\n' \
                "$public_html_dir" >&2
            exit 73
        fi

        if ! install -d \
            -m 0755 \
            -o "$SITE_UID" \
            -g "$SITE_GID" \
            -- "$public_html_dir"
        then
            printf 'Error: unable to create public_html: %s\n' \
                "$public_html_dir" >&2
            exit 73
        fi
        ;;
    loom73)
            # GitHub Actions deploys the application tree.
            # Shuttle creates storage and initializes the database later.
            printf 'Loom73 environment prepared for deployment.\n'
            printf 'No application or runtime directories were created.\n'
            ;;
esac

# Build Aliases directive for the Vhost
server_alias_directive=''

if (( ${#site_aliases[@]} > 0 )); then
    printf -v server_alias_directive \
        'ServerAlias %s' \
        "${site_aliases[*]}"
fi

readonly server_alias_directive

# Render the virtual host configuration
if [[ ! -f $vhost_blueprint ]]; then
    printf 'Error: virtual host blueprint not found: %s\n' \
        "$vhost_blueprint" >&2
    exit 66
fi

if [[ ! -r $vhost_blueprint ]]; then
    printf 'Error: virtual host blueprint is not readable: %s\n' \
        "$vhost_blueprint" >&2
    exit 66
fi

if ! vhost=$(<"$vhost_blueprint"); then
    printf 'Error: unable to read virtual host blueprint: %s\n' \
        "$vhost_blueprint" >&2
    exit 66
fi

vhost=${vhost//@site_url@/$site_url}
vhost=${vhost//@server_alias@/$server_alias_directive}
vhost=${vhost//@site_docroot@/$absolute_doc_root}
vhost=${vhost//@install_dir@/$install_dir}
vhost=${vhost//@php_socket@/$php_socket}
vhost=${vhost//@site_public_root@/$site_public_root}

if [[ $vhost == *'@site_url@'* ||
      $vhost == *'@server_alias@'* ||
      $vhost == *'@site_docroot@'* ||
      $vhost == *'@install_dir@'* ||
      $vhost == *'@site_public_root@'* ||
      $vhost == *'@php_socket@'* ]]
then
    printf 'Error: unresolved placeholders in virtual host blueprint\n' >&2
    exit 65
fi

vhost_file="${vhosts_path}/${site_url}.conf"
enabled_vhost="/etc/apache2/sites-enabled/${site_url}.conf"

# Validate required Apache commands
for required_command in apache2ctl a2ensite a2dissite systemctl mktemp ln chown chmod; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' \
            "$required_command" >&2
        exit 69
    fi
done

if [[ ! -d $vhosts_path || ! -w $vhosts_path ]]; then
    printf 'Error: Apache sites directory is not writable: %s\n' \
        "$vhosts_path" >&2
    exit 73
fi

if [[ -e $vhost_file || -L $vhost_file ]]; then
    printf 'Error: virtual host configuration already exists: %s\n' \
        "$vhost_file" >&2
    exit 73
fi

if [[ -e $enabled_vhost || -L $enabled_vhost ]]; then
    printf 'Error: virtual host is already enabled or has a stale link: %s\n' \
        "$enabled_vhost" >&2
    exit 73
fi

# Verify that Apache is healthy before changing anything.
if ! apache2ctl configtest; then
    printf 'Error: the existing Apache configuration is invalid.\n' >&2
    printf 'No changes have been made.\n' >&2
    exit 78
fi

# Check Apache Modules
if ! apache_modules=$(apache2ctl -M 2>/dev/null); then
    printf 'Error: unable to inspect loaded Apache modules\n' >&2
    exit 78
fi

required_apache_modules=(
    proxy_module
    proxy_fcgi_module
    headers_module
    rewrite_module
)

if [[ $site_profile == 'loom73' ]]; then
    required_apache_modules+=(
        expires_module
        mime_module
    )
fi

readonly -a required_apache_modules

for required_module in "${required_apache_modules[@]}"; do
    if [[ $apache_modules != *"$required_module "* ]]; then
        printf 'Error: required Apache module is not loaded: %s\n' \
            "$required_module" >&2
        exit 69
    fi
done

# Build the final file privately in the destination filesystem.
if ! vhost_temp=$(
    mktemp "${vhosts_path}/.${site_url}.conf.XXXXXX"
); then
    printf 'Error: unable to create temporary vhost file\n' >&2
    exit 73
fi

cleanup_vhost_temp() {
    if [[ -n ${vhost_temp-} && -e $vhost_temp ]]; then
        rm -f -- "$vhost_temp"
    fi
}

trap cleanup_vhost_temp EXIT

if ! printf '%s\n' "$vhost" > "$vhost_temp"; then
    printf 'Error: unable to write temporary vhost configuration\n' >&2
    exit 74
fi

if ! chown -- root:root "$vhost_temp"; then
    printf 'Error: unable to set vhost ownership\n' >&2
    exit 73
fi

if ! chmod 0644 "$vhost_temp"; then
    printf 'Error: unable to set vhost permissions\n' >&2
    exit 73
fi

# A hard link makes publication atomic and refuses an existing target.
if ! ln -- "$vhost_temp" "$vhost_file"; then
    printf 'Error: unable to publish vhost configuration: %s\n' \
        "$vhost_file" >&2
    exit 73
fi

rm -f -- "$vhost_temp"
vhost_temp=''

rollback_vhost() {
    printf 'Rolling back virtual host configuration...\n' >&2

    a2dissite "$site_url.conf" >/dev/null 2>&1 || true
    rm -f -- "$vhost_file"
}

if [[ $site_profile == 'loom73' ]]; then
    printf 'Virtual host prepared but not enabled: %s\n' "$site_url"
    printf 'Configuration file: %s\n' "$vhost_file"
    printf 'Expected public root after deploy: %s\n' "$site_public_root"
    printf '%s\n' \
        'Complete the deploy, configure .env and run Shuttle before activation.'

    trap - EXIT
    printf 'Done\n'
    exit 0
fi

printf 'Enabling virtual host: %s\n' "$site_url"

if ! a2ensite "$site_url.conf"; then
    printf 'Error: unable to enable virtual host\n' >&2
    rollback_vhost
    exit 78
fi

# Test the complete configuration with the site enabled.
if ! apache2ctl configtest; then
    printf 'Error: Apache rejected the new virtual host\n' >&2
    rollback_vhost

    if ! apache2ctl configtest; then
        printf 'Critical: Apache configuration remains invalid after rollback\n' >&2
    fi

    exit 78
fi

# Reload avoids interrupting existing connections.
if ! systemctl reload apache2; then
    printf 'Error: Apache reload failed\n' >&2
    rollback_vhost

    if apache2ctl configtest; then
        systemctl reload apache2 >/dev/null 2>&1 || true
    fi

    exit 78
fi

printf 'Virtual host enabled successfully: %s\n' "$site_url"
printf 'Configuration file: %s\n' "$vhost_file"

trap - EXIT

printf "Done\n"