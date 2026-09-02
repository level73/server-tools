#!/bin/bash

set -Eeuo pipefail

readonly WEB_ROOT='/var/www'

usage() {
    printf '%s\n' \
        "Usage: sudo ${0##*/} \\" \
        '  -d DOCUMENT_ROOT \' \
        '  -v VERSION \' \
        '  -o SITE_USER \' \
        '  [-l LOCALE]'
}

resolve_site_user() {
    local requested_user=${1-}

    if ! validate_site_user "$requested_user"; then
        printf 'Error: invalid site user: %q\n' "$requested_user" >&2
        return 1
    fi

    if ! getent passwd "$requested_user" >/dev/null; then
        printf 'Error: site user does not exist: %q\n' \
            "$requested_user" >&2
        return 1
    fi

    SITE_USER=$requested_user

    if ! SITE_UID=$(id -u -- "$SITE_USER"); then
        printf 'Error: unable to resolve UID for %q\n' "$SITE_USER" >&2
        return 1
    fi
    if (( SITE_UID == 0 )); then
        printf 'Error: root cannot be used as site user\n' >&2
        return 1
    fi
    if [[ $SITE_USER == 'www-data' ]]; then
        printf 'Error: shared PHP user cannot be used as site owner: %s\n' \
            "$SITE_USER" >&2
        return 1
    fi
    if ! SITE_GID=$(id -g -- "$SITE_USER"); then
        printf 'Error: unable to resolve GID for %q\n' "$SITE_USER" >&2
        return 1
    fi

    if ! SITE_GROUP=$(id -gn -- "$SITE_USER"); then
        printf 'Error: unable to resolve group for %q\n' "$SITE_USER" >&2
        return 1
    fi
}
validate_site_user() {
    [[ ${1-} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}
validate_version() {
    [[ ${1-} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

validate_locale() {
    [[ ${1-} =~ ^[A-Za-z][A-Za-z0-9_.@-]{1,31}$ ]]
}

is_wordpress_tree() {
    local wordpress_path=${1-}

    [[ -d $wordpress_path ]] &&
    [[ -f $wordpress_path/wp-settings.php ]] &&
    [[ -d $wordpress_path/wp-admin ]] &&
    [[ -d $wordpress_path/wp-content ]] &&
    [[ -d $wordpress_path/wp-includes ]]
}

cleanup_staging() {
    if [[ -n ${staging_dir-} &&
          -n ${absolute_doc_root-} &&
          $staging_dir == "$absolute_doc_root"/.wphost.* &&
          -d $staging_dir ]]
    then
        if ! rm -rf -- "$staging_dir"; then
            printf 'Warning: unable to remove staging directory: %s\n' \
                "$staging_dir" >&2
        fi
    fi
}
if (( EUID != 0 )); then
    printf 'Error: root privileges are required; run with sudo\n' >&2
    exit 77
fi

# CLI input
document_root=''
wordpress_version=''
wordpress_locale='en_US'
site_user=''

while getopts ':d:v:l:o:h' option; do
    case "$option" in
        d)
            document_root=$OPTARG
            ;;
        v)
            wordpress_version=$OPTARG
            ;;
        l)
            wordpress_locale=$OPTARG
            ;;
        o)
            site_user=$OPTARG
            ;;
        h)
            usage
            exit 0
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

if [[ -z $document_root ||
      -z $wordpress_version ||
      -z $site_user ]]
then
    printf 'Error: document root, version and site user are required\n' >&2
    usage >&2
    exit 64
fi

if ! validate_version "$wordpress_version"; then
    printf 'Error: invalid WordPress version: %q\n' \
        "$wordpress_version" >&2
    exit 64
fi

if ! validate_locale "$wordpress_locale"; then
    printf 'Error: invalid WordPress locale: %q\n' \
        "$wordpress_locale" >&2
    exit 64
fi

if ! validate_site_user "$site_user"; then
    printf 'Error: invalid site user: %q\n' "$site_user" >&2
    exit 64
fi

for required_command in \
    id \
    getent \
    realpath \
    stat \
    wp \
    mktemp \
    mkdir \
    find \
    chmod \
    chown \
    mv \
    rm
do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' \
            "$required_command" >&2
        exit 69
    fi
done

if ! resolve_site_user "$site_user"; then
    exit 77
fi

readonly SITE_UID SITE_GID SITE_USER SITE_GROUP

if ! canonical_web_root=$(realpath -e -- "$WEB_ROOT"); then
    printf 'Error: web root does not exist: %s\n' "$WEB_ROOT" >&2
    exit 72
fi

if ! absolute_doc_root=$(realpath -e -- "$document_root"); then
    printf 'Error: document root does not exist: %s\n' \
        "$document_root" >&2
    exit 72
fi

if [[ ! -d $absolute_doc_root ]]; then
    printf 'Error: document root is not a directory: %s\n' \
        "$absolute_doc_root" >&2
    exit 73
fi

if [[ $absolute_doc_root != "$canonical_web_root/"* ]]; then
    printf 'Error: document root escapes the web root: %s\n' \
        "$absolute_doc_root" >&2
    exit 64
fi

if ! current_owner=$(stat -c '%u:%g' -- "$absolute_doc_root"); then
    printf 'Error: unable to inspect document root ownership\n' >&2
    exit 73
fi

expected_owner="${SITE_UID}:${SITE_GID}"

if [[ $current_owner != "$expected_owner" ]]; then
    printf 'Error: unexpected document root ownership\n' >&2
    printf 'Expected: %s\n' "$expected_owner" >&2
    printf 'Current:  %s\n' "$current_owner" >&2
    exit 73
fi

wordpress_dir="$absolute_doc_root/wordpress"

if [[ -e $wordpress_dir || -L $wordpress_dir ]]; then
    printf 'Error: WordPress destination already exists: %s\n' \
        "$wordpress_dir" >&2
    printf 'Refusing to overwrite it.\n' >&2
    exit 73
fi

if ! staging_dir=$(
    mktemp -d "${absolute_doc_root}/.wphost.XXXXXX"
); then
    printf 'Error: unable to create staging directory\n' >&2
    exit 73
fi

trap cleanup_staging EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

staged_wordpress="$staging_dir/wordpress"

if ! mkdir -m 0700 -- "$staged_wordpress"; then
    printf 'Error: unable to create staged WordPress directory\n' >&2
    exit 73
fi

printf 'Downloading WordPress %s (%s)...\n' \
    "$wordpress_version" "$wordpress_locale"

if ! wp core download \
    --path="$staged_wordpress" \
    --version="$wordpress_version" \
    --locale="$wordpress_locale" \
    --allow-root
then
    printf 'Error: WordPress download failed\n' >&2
    exit 70
fi

printf 'Verifying WordPress checksums...\n'

if ! wp core verify-checksums \
    --path="$staged_wordpress" \
    --version="$wordpress_version" \
    --locale="$wordpress_locale" \
    --include-root \
    --allow-root
then
    printf 'Error: WordPress checksum verification failed\n' >&2
    exit 70
fi

if ! is_wordpress_tree "$staged_wordpress"; then
    printf 'Error: downloaded WordPress tree is incomplete\n' >&2
    exit 70
fi

if [[ -n $(find "$staged_wordpress" -type l -print -quit) ]]; then
    printf 'Error: downloaded WordPress tree contains symbolic links\n' >&2
    exit 70
fi

if ! find "$staged_wordpress" -type d -exec chmod 0755 {} +; then
    printf 'Error: unable to set WordPress directory permissions\n' >&2
    exit 73
fi

if ! find "$staged_wordpress" -type f -exec chmod 0644 {} +; then
    printf 'Error: unable to set WordPress file permissions\n' >&2
    exit 73
fi

# Safe because staged_wordpress is a new, private staging tree.
if ! chown -R -- "$expected_owner" "$staged_wordpress"; then
    printf 'Error: unable to set WordPress ownership\n' >&2
    exit 73
fi

# Staging and destination are on the same filesystem.
if ! mv -T -- "$staged_wordpress" "$wordpress_dir"; then
    printf 'Error: unable to publish WordPress directory\n' >&2
    exit 73
fi

cleanup_staging
staging_dir=''

trap - EXIT INT TERM HUP

printf 'WordPress %s installed successfully.\n' "$wordpress_version"
printf 'Path: %s\n' "$wordpress_dir"
printf 'Owner: %s:%s\n' "$SITE_USER" "$SITE_GROUP"
printf 'Database configuration has not been performed.\n'