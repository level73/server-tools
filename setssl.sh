#!/bin/bash

set -Eeuo pipefail

usage() {
    printf '%s\n' \
        'Usage:' \
        '  setssl [-u HOSTNAME] [-a ALIAS ...] [-m EMAIL] [-e MODE]' \
        '' \
        'Options:' \
        '  -u HOSTNAME  Primary hostname configured in Apache; prompts if omitted.' \
        '  -a ALIAS     Additional hostname to include in the certificate.' \
        '               Repeat -a for more than one alias.' \
        '  -m EMAIL     ACME account email; prompts if omitted.' \
        '  -e MODE      Certificate mode: staging or production.' \
        '               Prompts if omitted and defaults to staging.' \
        '  -h           Show this help message.' \
        '' \
        'Examples:' \
        '  sudo setssl -u example.com -a www.example.com \' \
        '      -m admin@example.com -e staging' \
        '  sudo setssl -u example.com -a www.example.com \' \
        '      -m admin@example.com -e production' \
        '' \
        'The staging mode validates the complete ACME flow without saving' \
        'or installing a certificate. Production obtains and installs it.'
}

validate_hostname() {
    local candidate=$1
    local label
    local -a labels

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 253 )) || return 1
    [[ $candidate != .* ]] || return 1
    [[ $candidate != *. ]] || return 1
    [[ $candidate != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$candidate"
    (( ${#labels[@]} >= 2 )) || return 1

    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

validate_email() {
    local candidate=$1

    [[ -n $candidate ]] || return 1
    (( ${#candidate} <= 254 )) || return 1
    [[ $candidate =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

readonly VHOSTS_AVAILABLE='/etc/apache2/sites-available'
readonly VHOSTS_ENABLED='/etc/apache2/sites-enabled'
readonly LETSENCRYPT_LIVE='/etc/letsencrypt/live'

site_url=''
account_email=''
certificate_mode=''
declare -a requested_aliases=()

while getopts ':u:a:m:e:h' option; do
    case "$option" in
        u) site_url=$OPTARG ;;
        a) requested_aliases+=("$OPTARG") ;;
        m) account_email=$OPTARG ;;
        e) certificate_mode=$OPTARG ;;
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

if (( $# != 0 )); then
    printf 'Error: unexpected positional argument: %q\n' "$1" >&2
    usage >&2
    exit 64
fi

if [[ -z $site_url ]]; then
    IFS= read -r -p 'Primary hostname: ' site_url
fi
site_url=${site_url,,}

if ! validate_hostname "$site_url"; then
    printf 'Error: invalid primary hostname: %q\n' "$site_url" >&2
    printf 'Expected format: example.com or app.example.com\n' >&2
    exit 64
fi

declare -a site_aliases=()
declare -A seen_domains=(["$site_url"]=1)

for requested_alias in "${requested_aliases[@]}"; do
    normalized_alias=${requested_alias,,}

    if ! validate_hostname "$normalized_alias"; then
        printf 'Error: invalid hostname alias: %q\n' "$requested_alias" >&2
        exit 64
    fi

    if [[ -z ${seen_domains["$normalized_alias"]+present} ]]; then
        site_aliases+=("$normalized_alias")
        seen_domains["$normalized_alias"]=1
    fi
done

if [[ -z $account_email ]]; then
    IFS= read -r -p 'ACME account email: ' account_email
fi

if ! validate_email "$account_email"; then
    printf 'Error: invalid ACME account email: %q\n' "$account_email" >&2
    exit 64
fi

if [[ -z $certificate_mode ]]; then
    IFS= read -r \
        -p 'Certificate mode [staging/production] (default: staging): ' \
        certificate_mode
    certificate_mode=${certificate_mode:-staging}
fi
certificate_mode=${certificate_mode,,}

case "$certificate_mode" in
    staging|production) ;;
    *)
        printf 'Error: certificate mode must be staging or production\n' >&2
        exit 64
        ;;
esac

readonly site_url
readonly account_email
readonly certificate_mode
readonly -a site_aliases

if (( EUID != 0 )); then
    printf 'Error: root privileges are required; run this command with sudo\n' >&2
    exit 77
fi

for required_command in certbot apache2ctl realpath; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' "$required_command" >&2
        exit 69
    fi
done

vhost_file="$VHOSTS_AVAILABLE/$site_url.conf"
enabled_vhost="$VHOSTS_ENABLED/$site_url.conf"

if [[ ! -f $vhost_file || -L $vhost_file ]]; then
    printf 'Error: expected a regular Apache virtual-host file: %s\n' \
        "$vhost_file" >&2
    exit 66
fi

if [[ ! -r $vhost_file ]]; then
    printf 'Error: Apache virtual-host file is not readable: %s\n' \
        "$vhost_file" >&2
    exit 66
fi

if [[ ! -L $enabled_vhost ]]; then
    printf 'Error: Apache virtual host is not enabled: %s\n' \
        "$enabled_vhost" >&2
    exit 78
fi

if ! available_target=$(realpath -e -- "$vhost_file") ||
    ! enabled_target=$(realpath -e -- "$enabled_vhost")
then
    printf 'Error: unable to resolve the enabled Apache virtual host\n' >&2
    exit 78
fi

if [[ $available_target != "$enabled_target" ]]; then
    printf 'Error: enabled virtual host does not target %s\n' \
        "$vhost_file" >&2
    exit 78
fi

if ! apache2ctl configtest; then
    printf 'Error: Apache configuration test failed before Certbot\n' >&2
    exit 78
fi

declare -a certificate_domains=("$site_url" "${site_aliases[@]}")
declare -a certbot_command

if [[ $certificate_mode == staging ]]; then
    certbot_command=(
        certbot certonly
        --apache
        --dry-run
        --non-interactive
        --agree-tos
        --no-eff-email
        --email "$account_email"
    )
else
    certbot_command=(
        certbot run
        --apache
        --non-interactive
        --agree-tos
        --no-eff-email
        --email "$account_email"
        --redirect
        --keep-until-expiring
        --cert-name "$site_url"
    )
fi

for certificate_domain in "${certificate_domains[@]}"; do
    certbot_command+=(--domain "$certificate_domain")
done

printf 'Certificate mode: %s\n' "$certificate_mode"
printf 'Certificate domains:'
printf ' %s' "${certificate_domains[@]}"
printf '\n'

if ! "${certbot_command[@]}"; then
    printf 'Error: Certbot failed; no success is being reported\n' >&2
    exit 70
fi

if ! apache2ctl configtest; then
    printf 'Error: Apache configuration test failed after Certbot\n' >&2
    printf 'Review the Certbot changes before reloading Apache\n' >&2
    exit 78
fi

if [[ $certificate_mode == staging ]]; then
    printf '%s\n' \
        'Staging validation completed successfully.' \
        'No certificate was saved or installed.'
    exit 0
fi

certificate_directory="$LETSENCRYPT_LIVE/$site_url"
fullchain_file="$certificate_directory/fullchain.pem"
private_key_file="$certificate_directory/privkey.pem"

if [[ ! -r $fullchain_file || ! -r $private_key_file ]]; then
    printf 'Error: Certbot returned success, but certificate files are missing\n' >&2
    printf 'Expected: %s and %s\n' "$fullchain_file" "$private_key_file" >&2
    exit 70
fi

printf 'Certificate installed successfully for %s\n' "$site_url"
printf 'Certificate directory: %s\n' "$certificate_directory"
