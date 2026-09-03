#!/bin/bash

set -Eeuo pipefail

readonly WEB_ROOT='/var/www'
readonly VHOSTS_AVAILABLE='/etc/apache2/sites-available'
readonly VHOSTS_ENABLED='/etc/apache2/sites-enabled'

usage() {
    local command_name=${0##*/}

    printf '%s\n' \
        "Usage: $command_name COMMAND [OPTIONS]" \
        '' \
        'Provision and activate server environments managed by server-tools.' \
        '' \
        'Commands:' \
        '  prepare     Create the database and prepare the site environment.' \
        '  activate    Validate and enable the site, optionally configuring SSL.' \
        '' \
        "Run '$command_name COMMAND -h' for command-specific help."
}

prepare_usage() {
    local command_name=${0##*/}

    printf '%s\n' \
        "Usage: $command_name prepare OPTIONS" \
        '' \
        'Required for every profile:' \
        '  -t PROFILE      wordpress, generic or loom73' \
        '  -u HOSTNAME     Primary hostname' \
        '  -d PATH         Site path relative to /var/www' \
        '' \
        'Optional common argument:' \
        '  -a HOSTNAME     Additional hostname; repeat for more aliases' \
        '' \
        'WordPress options:' \
        '  -b DATABASE     MySQL database name' \
        '  -r DB_USER      MySQL username' \
        '  -v VERSION      WordPress version' \
        '  -l LOCALE       WordPress locale; defaults to en_US' \
        '' \
        'Required for loom73:' \
        '  -b DATABASE     MySQL database name' \
        '  -r DB_USER      MySQL username' \
        '  -o USER         Existing deploy user' \
        '' \
        'Other:' \
        '  -h              Show this help message' \
        '' \
        'The generic profile does not create a database.' \
        '' \
        'Examples:' \
        "  sudo $command_name prepare -t generic \\" \
        '      -u example.com -d example.com' \
        "  sudo $command_name prepare -t wordpress \\" \
        '      -u example.com -d example.com \' \
        '      -b example_wp -r example_wp -v 6.8.2' \
        "  sudo $command_name prepare -t loom73 \\" \
        '      -u app.example.com -d app.example.com \' \
        '      -b app_db -r app_db -o deploy'
}

activate_usage() {
    local command_name=${0##*/}

    printf '%s\n' \
        "Usage: $command_name activate OPTIONS" \
        '' \
        'Required:' \
        '  -t PROFILE      wordpress, generic or loom73' \
        '  -u HOSTNAME     Primary hostname' \
        '  -d PATH         Site path relative to /var/www' \
        '' \
        'Optional SSL arguments:' \
        '  -e MODE         staging or production; omit to skip SSL' \
        '  -m EMAIL        ACME account email; required with -e' \
        '  -a HOSTNAME     Certificate alias; repeat for more aliases' \
        '' \
        'Other:' \
        '  -h              Show this help message' \
        '' \
        'Examples:' \
        "  sudo $command_name activate -t loom73 \\" \
        '      -u app.example.com -d app.example.com' \
        "  sudo $command_name activate -t loom73 \\" \
        '      -u app.example.com -d app.example.com \' \
        '      -m admin@example.com -e staging'
}

validate_hostname() {
    local candidate=${1-}
    local label
    local label_regex='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    local -a labels

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 253 )) || return 1
    [[ $candidate =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ $candidate != .* ]] || return 1
    [[ $candidate != *. ]] || return 1
    [[ $candidate != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$candidate"
    (( ${#labels[@]} >= 2 )) || return 1

    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ $label =~ $label_regex ]] || return 1
    done
}

validate_relative_doc_root() {
    local candidate=${1-}
    local component
    local component_regex='^[A-Za-z0-9][A-Za-z0-9._-]*$'
    local -a components

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 2048 )) || return 1
    [[ $candidate =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    [[ $candidate != /* ]] || return 1
    [[ $candidate != */ ]] || return 1
    [[ $candidate != *//* ]] || return 1

    IFS='/' read -r -a components <<< "$candidate"

    for component in "${components[@]}"; do
        [[ $component =~ $component_regex ]] || return 1
        (( ${#component} <= 255 )) || return 1
    done
}

validate_database_name() {
    local candidate=${1-}

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 64 )) || return 1
    [[ $candidate =~ ^[A-Za-z0-9_]+$ ]]
}

validate_database_user() {
    local candidate=${1-}

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 32 )) || return 1
    [[ $candidate =~ ^[A-Za-z0-9_]+$ ]]
}

validate_wordpress_version() {
    [[ ${1-} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

validate_wordpress_locale() {
    [[ ${1-} =~ ^[A-Za-z][A-Za-z0-9_.@-]{1,31}$ ]]
}

validate_email() {
    local candidate=${1-}

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 254 )) || return 1
    [[ $candidate =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

require_root() {
    if (( EUID != 0 )); then
        printf 'Error: root privileges are required; run with sudo\n' >&2
        exit 77
    fi
}

resolve_command() {
    local requested_command=${1-}
    local resolved_command
    local sibling_command

    if [[ -z ${SCRIPT_DIRECTORY-} ]]; then
        if ! SCRIPT_DIRECTORY=$(
            cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
        ); then
            printf 'Error: unable to determine script directory\n' >&2
            return 1
        fi
    fi

    sibling_command="$SCRIPT_DIRECTORY/${requested_command}.sh"

    if [[ -e $sibling_command || -L $sibling_command ]]; then
        if [[ ! -f $sibling_command ||
              -L $sibling_command ||
              ! -x $sibling_command ]]
        then
            printf 'Error: sibling command is not a regular executable: %s\n' \
                "$sibling_command" >&2
            return 1
        fi

        printf '%s' "$sibling_command"
        return 0
    fi

    if ! resolved_command=$(command -v "$requested_command"); then
        printf 'Error: required command not found: %s\n' \
            "$requested_command" >&2
        return 1
    fi

    if [[ $resolved_command != /* ||
          ! -f $resolved_command ||
          ! -x $resolved_command ]]
    then
        printf 'Error: command does not resolve to an executable file: %s\n' \
            "$requested_command" >&2
        return 1
    fi

    printf '%s' "$resolved_command"
}

validate_common_input() {
    local alias_index
    local normalized_alias
    local -A seen_aliases=()

    site_profile=${site_profile,,}
    site_url=${site_url,,}

    case "$site_profile" in
        wordpress|generic|loom73) ;;
        *)
            printf 'Error: -t must be wordpress, generic or loom73\n' >&2
            return 1
            ;;
    esac

    if ! validate_hostname "$site_url"; then
        printf 'Error: invalid primary hostname: %q\n' "$site_url" >&2
        return 1
    fi

    if ! validate_relative_doc_root "$relative_doc_root"; then
        printf 'Error: invalid relative document root: %q\n' \
            "$relative_doc_root" >&2
        return 1
    fi

    for alias_index in "${!site_aliases[@]}"; do
        normalized_alias=${site_aliases[$alias_index],,}
        site_aliases[$alias_index]=$normalized_alias

        if ! validate_hostname "$normalized_alias"; then
            printf 'Error: invalid hostname alias: %q\n' \
                "$normalized_alias" >&2
            return 1
        fi

        if [[ $normalized_alias == "$site_url" ]]; then
            printf 'Error: alias duplicates the primary hostname: %s\n' \
                "$normalized_alias" >&2
            return 1
        fi

        if [[ -n ${seen_aliases["$normalized_alias"]+present} ]]; then
            printf 'Error: duplicate hostname alias: %s\n' \
                "$normalized_alias" >&2
            return 1
        fi

        seen_aliases["$normalized_alias"]=1
    done
}

site_profile=''
site_url=''
relative_doc_root=''
deploy_user=''
database_name=''
database_user=''
wordpress_version=''
wordpress_locale='en_US'
wordpress_options_used=false
account_email=''
certificate_mode=''
declare -a site_aliases=()

parse_prepare_options() {
    OPTIND=1

    while getopts ':t:u:a:d:o:b:r:v:l:h' option; do
        case "$option" in
            t) site_profile=$OPTARG ;;
            u) site_url=$OPTARG ;;
            a) site_aliases+=("$OPTARG") ;;
            d) relative_doc_root=$OPTARG ;;
            o) deploy_user=$OPTARG ;;
            b) database_name=$OPTARG ;;
            r) database_user=$OPTARG ;;
            v)
                wordpress_version=$OPTARG
                wordpress_options_used=true
                ;;
            l)
                wordpress_locale=$OPTARG
                wordpress_options_used=true
                ;;
            h)
                prepare_usage
                exit 0
                ;;
            :)
                printf 'Error: -%s requires an argument\n' "$OPTARG" >&2
                prepare_usage >&2
                exit 64
                ;;
            \?)
                printf 'Error: unknown prepare option: -%s\n' "$OPTARG" >&2
                prepare_usage >&2
                exit 64
                ;;
        esac
    done

    shift "$((OPTIND - 1))"

    if (( $# > 0 )); then
        printf 'Error: unexpected prepare argument: %q\n' "$1" >&2
        prepare_usage >&2
        exit 64
    fi
}

validate_prepare_options() {
    if [[ -z $site_profile || -z $site_url || -z $relative_doc_root ]]; then
        printf 'Error: prepare requires -t, -u and -d\n' >&2
        prepare_usage >&2
        exit 64
    fi

    if ! validate_common_input; then
        exit 64
    fi

    case "$site_profile" in
        wordpress)
            if [[ -n $deploy_user ]]; then
                printf 'Error: -o is only valid for loom73\n' >&2
                exit 64
            fi

            if [[ -z $database_name ||
                  -z $database_user ||
                  -z $wordpress_version ]]
            then
                printf 'Error: wordpress requires -b, -r and -v\n' >&2
                exit 64
            fi

            if ! validate_database_name "$database_name"; then
                printf 'Error: invalid database name: %q\n' \
                    "$database_name" >&2
                exit 64
            fi

            if ! validate_database_user "$database_user"; then
                printf 'Error: invalid database user: %q\n' \
                    "$database_user" >&2
                exit 64
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
            ;;

        loom73)
            if [[ -z $database_name ||
                  -z $database_user ||
                  -z $deploy_user ]]
            then
                printf 'Error: loom73 requires -b, -r and -o\n' >&2
                exit 64
            fi

            if [[ $wordpress_options_used == true ]]; then
                printf 'Error: -v and -l are only valid for wordpress\n' >&2
                exit 64
            fi

            if ! validate_database_name "$database_name"; then
                printf 'Error: invalid database name: %q\n' \
                    "$database_name" >&2
                exit 64
            fi

            if ! validate_database_user "$database_user"; then
                printf 'Error: invalid database user: %q\n' \
                    "$database_user" >&2
                exit 64
            fi
            ;;

        generic)
            if [[ -n $database_name ||
                  -n $database_user ||
                  -n $deploy_user ||
                  $wordpress_options_used == true ]]
            then
                printf '%s\n' \
                    'Error: generic does not accept database, deploy-user or WordPress options' >&2
                exit 64
            fi
            ;;
    esac
}

parse_activate_options() {
    OPTIND=1

    while getopts ':t:u:a:d:m:e:h' option; do
        case "$option" in
            t) site_profile=$OPTARG ;;
            u) site_url=$OPTARG ;;
            a) site_aliases+=("$OPTARG") ;;
            d) relative_doc_root=$OPTARG ;;
            m) account_email=$OPTARG ;;
            e) certificate_mode=$OPTARG ;;
            h)
                activate_usage
                exit 0
                ;;
            :)
                printf 'Error: -%s requires an argument\n' "$OPTARG" >&2
                activate_usage >&2
                exit 64
                ;;
            \?)
                printf 'Error: unknown activate option: -%s\n' "$OPTARG" >&2
                activate_usage >&2
                exit 64
                ;;
        esac
    done

    shift "$((OPTIND - 1))"

    if (( $# > 0 )); then
        printf 'Error: unexpected activate argument: %q\n' "$1" >&2
        activate_usage >&2
        exit 64
    fi
}

validate_activate_options() {
    if [[ -z $site_profile || -z $site_url || -z $relative_doc_root ]]; then
        printf 'Error: activate requires -t, -u and -d\n' >&2
        activate_usage >&2
        exit 64
    fi

    if ! validate_common_input; then
        exit 64
    fi

    if [[ -z $certificate_mode ]]; then
        if [[ -n $account_email || ${#site_aliases[@]} -gt 0 ]]; then
            printf 'Error: -m and -a require SSL mode -e\n' >&2
            exit 64
        fi
        return 0
    fi

    certificate_mode=${certificate_mode,,}

    case "$certificate_mode" in
        staging|production) ;;
        *)
            printf 'Error: -e must be staging or production\n' >&2
            exit 64
            ;;
    esac

    if ! validate_email "$account_email"; then
        printf 'Error: a valid ACME email is required with -e\n' >&2
        exit 64
    fi
}

run_prepare() {
    local addhost_command
    local setmysql_command=''
    local status
    local site_alias
    local -a addhost_arguments

    if ! addhost_command=$(resolve_command addhost); then
        exit 69
    fi

    # WordPress is installed by addhost through wphost. Check the complete
    # command chain before creating the mandatory database.
    if [[ $site_profile == wordpress ]] &&
        ! resolve_command wphost >/dev/null
    then
        exit 69
    fi

    if [[ $site_profile == wordpress || $site_profile == loom73 ]]; then
        if ! setmysql_command=$(resolve_command setmysql); then
            exit 69
        fi

        printf 'Preparing mandatory database for %s...\n' "$site_profile"

        if "$setmysql_command" -d "$database_name" -u "$database_user"; then
            printf 'Database provisioning completed.\n'
        else
            status=$?
            printf 'Error: database provisioning failed\n' >&2
            exit "$status"
        fi
    fi

    addhost_arguments=(
        -t "$site_profile"
        -u "$site_url"
        -d "$relative_doc_root"
    )

    for site_alias in "${site_aliases[@]}"; do
        addhost_arguments+=(-a "$site_alias")
    done

    case "$site_profile" in
        wordpress)
            addhost_arguments+=(
                -v "$wordpress_version"
                -l "$wordpress_locale"
            )
            ;;
        loom73)
            addhost_arguments+=(-o "$deploy_user")
            ;;
    esac

    printf 'Preparing %s site environment...\n' "$site_profile"

    if "$addhost_command" "${addhost_arguments[@]}"; then
        :
    else
        status=$?
        printf 'Error: site-environment provisioning failed\n' >&2

        if [[ $site_profile == wordpress || $site_profile == loom73 ]]; then
            printf '%s\n' \
                'The database was intentionally not removed; inspect it before retrying.' >&2
        fi

        exit "$status"
    fi

    printf 'Preparation completed for %s.\n' "$site_url"

    if [[ $site_profile == loom73 ]]; then
        printf '%s\n' \
            'Next steps:' \
            '  1. Deploy Loom73.' \
            '  2. Configure its .env with the provisioned database credentials.' \
            '  3. Run Shuttle to create runtime directories, tables and seed data.' \
            '  4. Run provision activate.'
    else
        printf '%s\n' \
            'The HTTP virtual host is active.' \
            'Run provision activate with -e when DNS is ready for SSL.'
    fi
}

ACTIVATION_CREATED=false
ACTIVATION_SITE_URL=''

rollback_activation() {
    if [[ $ACTIVATION_CREATED == true && -n $ACTIVATION_SITE_URL ]]; then
        printf 'Rolling back virtual-host activation for %s...\n' \
            "$ACTIVATION_SITE_URL" >&2

        if a2dissite "$ACTIVATION_SITE_URL.conf" >/dev/null 2>&1; then
            ACTIVATION_CREATED=false
        else
            printf 'Warning: unable to disable virtual host during rollback\n' >&2
        fi
    fi
}

run_activate() {
    local apache2ctl_command
    local a2ensite_command
    local realpath_command
    local setssl_command=''
    local systemctl_command
    local canonical_web_root
    local absolute_doc_root
    local site_public_root
    local canonical_public_root
    local available_vhost
    local enabled_vhost
    local available_target
    local enabled_target
    local site_alias
    local status
    local -a setssl_arguments

    for required_command in apache2ctl a2ensite a2dissite realpath systemctl awk; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            printf 'Error: required command not found: %s\n' \
                "$required_command" >&2
            exit 69
        fi
    done

    apache2ctl_command=$(command -v apache2ctl)
    a2ensite_command=$(command -v a2ensite)
    realpath_command=$(command -v realpath)
    systemctl_command=$(command -v systemctl)

    if [[ -n $certificate_mode ]]; then
        if ! setssl_command=$(resolve_command setssl); then
            exit 69
        fi

        if ! resolve_command certbot >/dev/null ||
            ! resolve_command curl >/dev/null
        then
            exit 69
        fi
    fi

    if ! canonical_web_root=$(
        "$realpath_command" -e -- "$WEB_ROOT"
    ); then
        printf 'Error: web root does not exist: %s\n' "$WEB_ROOT" >&2
        exit 72
    fi

    if ! absolute_doc_root=$(
        "$realpath_command" -m -- "$canonical_web_root/$relative_doc_root"
    ); then
        printf 'Error: unable to resolve document root\n' >&2
        exit 72
    fi

    if [[ $absolute_doc_root != "$canonical_web_root/"* ]]; then
        printf 'Error: document root escapes the web root\n' >&2
        exit 64
    fi

    case "$site_profile" in
        wordpress) site_public_root="$absolute_doc_root/wordpress" ;;
        generic) site_public_root="$absolute_doc_root/public_html" ;;
        loom73) site_public_root="$absolute_doc_root/public_html/public" ;;
    esac

    if [[ ! -d $site_public_root ]]; then
        printf 'Error: expected public root does not exist: %s\n' \
            "$site_public_root" >&2
        exit 72
    fi

    if ! canonical_public_root=$(
        "$realpath_command" -e -- "$site_public_root"
    ); then
        printf 'Error: unable to resolve public root: %s\n' \
            "$site_public_root" >&2
        exit 72
    fi

    if [[ $canonical_public_root != "$canonical_web_root/"* ]]; then
        printf 'Error: public root resolves outside %s\n' "$WEB_ROOT" >&2
        exit 73
    fi

    available_vhost="$VHOSTS_AVAILABLE/$site_url.conf"
    enabled_vhost="$VHOSTS_ENABLED/$site_url.conf"

    if [[ ! -f $available_vhost || -L $available_vhost ]]; then
        printf 'Error: expected a regular virtual-host file: %s\n' \
            "$available_vhost" >&2
        exit 66
    fi

    if [[ ! -r $available_vhost ]]; then
        printf 'Error: virtual-host file is not readable: %s\n' \
            "$available_vhost" >&2
        exit 66
    fi

    if ! awk -v expected="$site_url" '
        $1 == "ServerName" && $2 == expected && NF == 2 { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$available_vhost"
    then
        printf 'Error: virtual host does not declare ServerName %s\n' \
            "$site_url" >&2
        exit 78
    fi

    if ! awk -v expected="$site_public_root" '
        $1 == "DocumentRoot" {
            value = $2
            gsub(/^"|"$/, "", value)
            if (value == expected) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$available_vhost"
    then
        printf 'Error: virtual host does not use expected DocumentRoot %s\n' \
            "$site_public_root" >&2
        exit 78
    fi

    if ! "$apache2ctl_command" configtest; then
        printf 'Error: existing Apache configuration is invalid\n' >&2
        exit 78
    fi

    ACTIVATION_SITE_URL=$site_url
    ACTIVATION_CREATED=false
    trap rollback_activation EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    if [[ -L $enabled_vhost ]]; then
        if ! available_target=$(
            "$realpath_command" -e -- "$available_vhost"
        ) || ! enabled_target=$(
            "$realpath_command" -e -- "$enabled_vhost"
        ); then
            printf 'Error: unable to resolve enabled virtual host\n' >&2
            exit 78
        fi

        if [[ $available_target != "$enabled_target" ]]; then
            printf 'Error: enabled virtual host targets an unexpected file\n' >&2
            exit 78
        fi

        printf 'Virtual host is already enabled: %s\n' "$site_url"
    elif [[ -e $enabled_vhost ]]; then
        printf 'Error: enabled virtual-host path is not a symbolic link: %s\n' \
            "$enabled_vhost" >&2
        exit 78
    else
        if ! "$a2ensite_command" "$site_url.conf"; then
            printf 'Error: unable to enable virtual host: %s\n' \
                "$site_url" >&2
            exit 78
        fi

        ACTIVATION_CREATED=true
    fi

    if ! "$apache2ctl_command" configtest; then
        printf 'Error: Apache rejected the activated virtual host\n' >&2
        rollback_activation

        if ! "$apache2ctl_command" configtest; then
            printf 'Critical: Apache remains invalid after rollback\n' >&2
        fi

        exit 78
    fi

    if ! "$systemctl_command" reload apache2; then
        printf 'Error: Apache reload failed\n' >&2
        rollback_activation

        if "$apache2ctl_command" configtest; then
            "$systemctl_command" reload apache2 >/dev/null 2>&1 || true
        fi

        exit 78
    fi

    ACTIVATION_CREATED=false
    trap - EXIT INT TERM HUP

    printf 'Virtual host activated successfully: %s\n' "$site_url"

    if [[ -z $certificate_mode ]]; then
        printf 'SSL was not requested.\n'
        return 0
    fi

    setssl_arguments=(
        -u "$site_url"
        -m "$account_email"
        -e "$certificate_mode"
    )

    for site_alias in "${site_aliases[@]}"; do
        setssl_arguments+=(-a "$site_alias")
    done

    if "$setssl_command" "${setssl_arguments[@]}"; then
        printf 'SSL step completed successfully for %s.\n' "$site_url"
    else
        status=$?
        printf '%s\n' \
            'Error: SSL configuration failed; the HTTP virtual host remains active.' >&2
        exit "$status"
    fi
}

if (( $# == 0 )); then
    usage >&2
    exit 64
fi

operation=$1
shift

case "$operation" in
    -h|--help)
        usage
        exit 0
        ;;
    prepare)
        parse_prepare_options "$@"
        validate_prepare_options
        require_root
        run_prepare
        ;;
    activate)
        parse_activate_options "$@"
        validate_activate_options
        require_root
        run_activate
        ;;
    *)
        printf 'Error: unknown command: %q\n' "$operation" >&2
        usage >&2
        exit 64
        ;;
esac