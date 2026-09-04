#!/bin/bash

set -Eeuo pipefail

readonly WEB_ROOT='/var/www'

usage() {
    printf '%s\n' \
        "Usage: sudo ${0##*/} \\" \
        "  -d DOCUMENT_ROOT \\" \
        "  -v VERSION \\" \
        "  -o SITE_USER \\" \
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
# Paths reaching this function must be normalized absolute directory names.
# Root ownership and a non-writable group/other mode protect every next entry
# against replacement by an application user. No existing metadata is changed.
require_trusted_directory() {
    local directory=${1-}
    local metadata
    local owner
    local mode

    if [[ -L $directory || ! -d $directory ]]; then
        printf 'Error: expected a real, root-managed directory: %s\n' "$directory" >&2
        return 1
    fi

    if ! metadata=$(stat -c '%u:%a' -- "$directory"); then
        printf 'Error: unable to inspect directory: %s\n' "$directory" >&2
        return 1
    fi

    owner=${metadata%%:*}
    mode=${metadata#*:}
    if [[ $owner != 0 || ! $mode =~ ^[0-7]{3,4}$ ]]; then
        printf 'Error: directory must be owned by root: %s\n' "$directory" >&2
        return 1
    fi
    if (( (8#$mode & 0022) != 0 )); then
        printf 'Error: directory is writable by group or others: %s\n' "$directory" >&2
        return 1
    fi
}

trusted_directory_chain() {
    local directory=${1-}
    local create_missing=${2-false}
    local current=''
    local component
    local -a components

    if [[ $directory != /* || $directory == *//* ||
          ( $directory != / && $directory == */ ) ]]; then
        printf 'Error: expected a normalized absolute directory path\n' >&2
        return 1
    fi
    [[ $create_missing == true || $create_missing == false ]] || return 1

    IFS='/' read -r -a components <<< "${directory#/}"
    # Validate the entire string as read consumes only the first line.
    [[ $directory =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    for component in "${components[@]}"; do
        [[ $component =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    done

    require_trusted_directory / || return 1
    for component in "${components[@]}"; do
        current+="/$component"
        if [[ ! -e $current && ! -L $current && $create_missing == true ]]; then
            # The parent has already been verified. Never use mkdir -p here.
            if ! mkdir -m 0755 -- "$current"; then
                printf 'Error: unable to create root-managed directory: %s\n' "$current" >&2
                return 1
            fi
        fi
        require_trusted_directory "$current" || return 1
    done
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
          -n ${staging_parent-} &&
          $staging_dir == "$staging_parent"/.wphost.* &&
          -d $staging_dir && ! -L $staging_dir ]]
    then
        if ! rm -rf -- "$staging_dir"; then
            printf 'Warning: unable to remove staging directory: %s\n' \
                "$staging_dir" >&2
        fi
    fi
}

publish_wordpress_tree() {
    local source=${1-}
    local destination=${2-}
    local source_device
    local destination_device

    # The caller verified the parent chain and created a private root-owned
    # staging directory. Avoid mv's cross-filesystem copy fallback entirely.
    if ! source_device=$(stat -c '%d' -- "$source") ||
        ! destination_device=$(stat -c '%d' -- "${destination%/*}"); then
        printf 'Error: unable to inspect publication filesystems\n' >&2
        return 1
    fi
    if [[ $source_device != "$destination_device" ]]; then
        printf 'Error: WordPress staging and destination must be on the same filesystem\n' >&2
        return 1
    fi
    if [[ -e $destination || -L $destination ]]; then
        printf 'Error: refusing to replace an existing WordPress destination\n' >&2
        return 1
    fi
    if ! mv -nT -- "$source" "$destination"; then
        printf 'Error: unable to publish WordPress without replacing existing data\n' >&2
        return 1
    fi
    # Some GNU mv versions return success when -n skips a concurrent entry.
    if [[ -e $source || -L $source ]]; then
        printf 'Error: WordPress publication was skipped; destination may have appeared\n' >&2
        return 1
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

if ! trusted_directory_chain "$WEB_ROOT"; then
    printf 'Error: web-root ancestors must be real root-managed directories\n' >&2
    exit 73
fi

if ! canonical_web_root=$(realpath -e -- "$WEB_ROOT"); then
    printf 'Error: web root does not exist: %s\n' "$WEB_ROOT" >&2
    exit 72
fi

if [[ $document_root != "$canonical_web_root/"* ||
      $document_root == */ || $document_root == *//* ]]; then
    printf 'Error: expected a normalized absolute path beneath %s\n' "$WEB_ROOT" >&2
    exit 64
fi

staging_parent=${document_root%/*}
root_component=${document_root##*/}
if [[ ! $root_component =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    ! trusted_directory_chain "$staging_parent"; then
    printf 'Error: application-root ancestors are not safe for privileged writes\n' >&2
    exit 73
fi
if [[ -L $document_root || ! -d $document_root ]]; then
    printf 'Error: expected a real application root: %s\n' "$document_root" >&2
    exit 73
fi

if ! absolute_doc_root=$(realpath -e -- "$document_root"); then
    printf 'Error: document root does not exist: %s\n' \
        "$document_root" >&2
    exit 72
fi

if [[ $absolute_doc_root != "$document_root" ]]; then
    printf 'Error: document root does not resolve to the supplied path\n' >&2
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
    mktemp -d "${staging_parent}/.wphost.XXXXXX"
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

if ! (
    cd -- "$staging_dir" || exit 1
    wp core download \
        --path="$staged_wordpress" \
        --version="$wordpress_version" \
        --locale="$wordpress_locale" \
        --allow-root
)
then
    printf 'Error: WordPress download failed\n' >&2
    exit 70
fi

printf 'Verifying WordPress checksums...\n'

if ! (
    cd -- "$staging_dir" || exit 1
    wp core verify-checksums \
        --path="$staged_wordpress" \
        --version="$wordpress_version" \
        --locale="$wordpress_locale" \
        --include-root \
        --allow-root
)
then
    printf 'Error: WordPress checksum verification failed\n' >&2
    exit 70
fi

if ! is_wordpress_tree "$staged_wordpress"; then
    printf 'Error: downloaded WordPress tree is incomplete\n' >&2
    exit 70
fi

if ! staged_symlink=$(find "$staged_wordpress" -type l -print -quit); then
    printf 'Error: unable to check staged WordPress for symbolic links\n' >&2
    exit 70
fi
if [[ -n $staged_symlink ]]; then
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

# Publish by same-filesystem rename, refusing any concurrent destination.
if ! publish_wordpress_tree "$staged_wordpress" "$wordpress_dir"; then
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
