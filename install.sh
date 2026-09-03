#!/bin/bash

set -Eeuo pipefail

readonly INSTALL_DIRECTORY='/usr/local/bin'
readonly BLUEPRINT_DIRECTORY="$INSTALL_DIRECTORY/blueprints"

readonly -a SCRIPT_FILES=(
    'addhost.sh'
    'wphost.sh'
    'setmysql.sh'
    'setssl.sh'
    'provision.sh'
)

readonly -a BLUEPRINT_FILES=(
    'php-fpm-pool.blueprint.conf'
    'vhost.blueprint.conf'
    'vhost.loom73.blueprint.conf'
)

usage() {
    local command_name=${0##*/}

    printf '%s\n' \
        "Usage: sudo $command_name [-f]" \
        '' \
        'Install server-tools commands and blueprints.' \
        '' \
        'Options:' \
        '  -f  Replace installed files when their content differs.' \
        '  -h  Show this help message and exit.' \
        '' \
        'A first installation does not require -f.' \
        'Existing identical files are left untouched.'
}

force_install=false

while getopts ':fh' option; do
    case "$option" in
        f)
            force_install=true
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
    printf 'Error: unexpected positional argument: %q\n' "$1" >&2
    usage >&2
    exit 64
fi

if (( EUID != 0 )); then
    printf 'Error: root privileges are required; run with sudo\n' >&2
    exit 77
fi

for required_command in \
    bash \
    chmod \
    chown \
    cmp \
    dirname \
    install \
    mktemp \
    mv \
    pwd \
    rm \
    stat
do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' \
            "$required_command" >&2
        exit 69
    fi
done

if ! source_directory=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
); then
    printf 'Error: unable to determine installer directory\n' >&2
    exit 72
fi

if [[ ! -d $INSTALL_DIRECTORY || -L $INSTALL_DIRECTORY ]]; then
    printf 'Error: installation directory is not a regular directory: %s\n' \
        "$INSTALL_DIRECTORY" >&2
    exit 73
fi

if [[ ! -w $INSTALL_DIRECTORY ]]; then
    printf 'Error: installation directory is not writable: %s\n' \
        "$INSTALL_DIRECTORY" >&2
    exit 73
fi

if [[ -e $BLUEPRINT_DIRECTORY || -L $BLUEPRINT_DIRECTORY ]]; then
    if [[ ! -d $BLUEPRINT_DIRECTORY || -L $BLUEPRINT_DIRECTORY ]]; then
        printf 'Error: blueprint destination is not a regular directory: %s\n' \
            "$BLUEPRINT_DIRECTORY" >&2
        exit 73
    fi
fi

declare -a source_paths=()
declare -a target_paths=()
declare -a target_modes=()
declare -a display_names=()
declare -a replacement_names=()
declare -a changed_indexes=()
declare -a temporary_paths=()

for script_file in "${SCRIPT_FILES[@]}"; do
    source_path="$source_directory/$script_file"
    command_name=${script_file%.sh}
    target_path="$INSTALL_DIRECTORY/$command_name"

    if [[ ! -f $source_path || -L $source_path || ! -r $source_path ]]; then
        printf 'Error: invalid script source: %s\n' "$source_path" >&2
        exit 66
    fi

    if ! bash -n -- "$source_path"; then
        printf 'Error: Bash syntax check failed: %s\n' "$source_path" >&2
        exit 65
    fi

    if [[ -e $target_path || -L $target_path ]]; then
        if [[ ! -f $target_path || -L $target_path ]]; then
            printf 'Error: installed command is not a regular file: %s\n' \
                "$target_path" >&2
            exit 73
        fi
    fi

    source_paths+=("$source_path")
    target_paths+=("$target_path")
    target_modes+=('0755')
    display_names+=("$command_name")
done

for blueprint_file in "${BLUEPRINT_FILES[@]}"; do
    source_path="$source_directory/blueprints/$blueprint_file"
    target_path="$BLUEPRINT_DIRECTORY/$blueprint_file"

    if [[ ! -f $source_path || -L $source_path || ! -r $source_path ]]; then
        printf 'Error: invalid blueprint source: %s\n' "$source_path" >&2
        exit 66
    fi

    if [[ -e $target_path || -L $target_path ]]; then
        if [[ ! -f $target_path || -L $target_path ]]; then
            printf 'Error: installed blueprint is not a regular file: %s\n' \
                "$target_path" >&2
            exit 73
        fi
    fi

    source_paths+=("$source_path")
    target_paths+=("$target_path")
    target_modes+=('0644')
    display_names+=("blueprints/$blueprint_file")
done

for index in "${!source_paths[@]}"; do
    source_path=${source_paths[$index]}
    target_path=${target_paths[$index]}

    if [[ -f $target_path ]] && cmp -s -- "$source_path" "$target_path"; then
        continue
    fi

    changed_indexes+=("$index")

    if [[ -e $target_path || -L $target_path ]]; then
        replacement_names+=("${display_names[$index]}")
    fi
done

if (( ${#changed_indexes[@]} == 0 )); then
    printf 'server-tools is already up to date.\n'
    exit 0
fi

if (( ${#replacement_names[@]} > 0 )) && [[ $force_install != true ]]; then
    printf 'Error: installed files differ from this checkout:\n' >&2

    for replacement_name in "${replacement_names[@]}"; do
        printf '  %s\n' "$replacement_name" >&2
    done

    printf '%s\n' \
        'Review the changes, then rerun the installer with -f to replace them.' >&2
    exit 73
fi

cleanup_temporary_files() {
    local temporary_path

    for temporary_path in "${temporary_paths[@]}"; do
        case "$temporary_path" in
            "$INSTALL_DIRECTORY"/.server-tools.*)
                if [[ -e $temporary_path || -L $temporary_path ]]; then
                    rm -f -- "$temporary_path" || true
                fi
                ;;
            *)
                printf 'Warning: refusing to remove unexpected temporary path: %s\n' \
                    "$temporary_path" >&2
                ;;
        esac
    done
}

trap cleanup_temporary_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Stage every changed component before publishing any of them.
for index in "${changed_indexes[@]}"; do
    source_path=${source_paths[$index]}
    target_mode=${target_modes[$index]}

    if ! temporary_path=$(
        mktemp "$INSTALL_DIRECTORY/.server-tools.${display_names[$index]//\//_}.XXXXXX"
    ); then
        printf 'Error: unable to create installation staging file\n' >&2
        exit 73
    fi

    temporary_paths[$index]=$temporary_path

    if ! install \
        -o root \
        -g root \
        -m "$target_mode" \
        -- "$source_path" "$temporary_path"
    then
        printf 'Error: unable to stage %s\n' "${display_names[$index]}" >&2
        exit 73
    fi

    if [[ $target_mode == '0755' ]] && ! bash -n -- "$temporary_path"; then
        printf 'Error: staged script failed syntax check: %s\n' \
            "${display_names[$index]}" >&2
        exit 65
    fi
done

if [[ ! -d $BLUEPRINT_DIRECTORY ]]; then
    if ! install -d \
        -o root \
        -g root \
        -m 0755 \
        -- "$BLUEPRINT_DIRECTORY"
    then
        printf 'Error: unable to create blueprint directory\n' >&2
        exit 73
    fi
else
    if ! chown -- root:root "$BLUEPRINT_DIRECTORY" ||
        ! chmod 0755 "$BLUEPRINT_DIRECTORY"
    then
        printf 'Error: unable to secure blueprint directory\n' >&2
        exit 73
    fi
fi

# Every file is already staged in the destination filesystem. Each rename is
# therefore atomic: a command is always either the previous or the new file.
for index in "${changed_indexes[@]}"; do
    temporary_path=${temporary_paths[$index]}
    target_path=${target_paths[$index]}

    if ! mv -fT -- "$temporary_path" "$target_path"; then
        printf 'Error: unable to publish %s\n' "${display_names[$index]}" >&2
        exit 73
    fi

    temporary_paths[$index]=''
    printf 'Installed: %s\n' "${display_names[$index]}"
done

trap - EXIT INT TERM HUP

for index in "${!source_paths[@]}"; do
    source_path=${source_paths[$index]}
    target_path=${target_paths[$index]}
    target_mode=${target_modes[$index]}

    if ! cmp -s -- "$source_path" "$target_path"; then
        printf 'Error: installed content verification failed: %s\n' \
            "$target_path" >&2
        exit 74
    fi

    if ! target_metadata=$(stat -Lc '%U:%G:%a' -- "$target_path"); then
        printf 'Error: unable to inspect installed file: %s\n' \
            "$target_path" >&2
        exit 73
    fi

    expected_metadata="root:root:${target_mode#0}"

    if [[ $target_metadata != "$expected_metadata" ]]; then
        printf 'Error: unexpected ownership or mode for %s\n' \
            "$target_path" >&2
        printf 'Expected: %s\nCurrent:  %s\n' \
            "$expected_metadata" "$target_metadata" >&2
        exit 73
    fi
done

printf 'server-tools installation completed successfully.\n'
