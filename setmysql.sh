#!/bin/bash

set -Eeuo pipefail

# Provision one local application database and account.

usage() {
    printf 'Usage: %s [-d database] [-u user]\n' "${0##*/}"
    printf '\n'
    printf 'Create a local MySQL database and grant a local user access to it.\n'
    printf '\n'
    printf 'Options:\n'
    printf '  -d NAME  Database name\n'
    printf '  -u NAME  MySQL username\n'
    printf '  -h       Show this help\n'
}

validate_database_name() {
    local name=${1-}

    [[ -n $name ]] || return 1
    (( ${#name} <= 64 )) || return 1
    [[ $name =~ ^[A-Za-z0-9_]+$ ]]
}

validate_database_user() {
    local name=${1-}

    [[ -n $name ]] || return 1
    (( ${#name} <= 32 )) || return 1
    [[ $name =~ ^[A-Za-z0-9_]+$ ]]
}

escape_sql_string() {
    local value=${1-}

    # The caller enables NO_BACKSLASH_ESCAPES for the same SQL session.
    # With that mode active, doubling a quote is sufficient and backslashes
    # remain literal characters in the password.
    value=${value//\'/\'\'}
    printf '%s' "$value"
}

confirm_user_creation() {
    local requested_user=${1-}
    local answer

    while true; do
        if ! IFS= read -r \
            -p "MySQL user ${requested_user} does not exist. Create it? [Y/n] " \
            answer
        then
            printf '\nError: unable to read confirmation\n' >&2
            return 1
        fi

        case "$answer" in
            ''|[Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                printf 'Please answer yes or no.\n' >&2
                ;;
        esac
    done
}

database_name=''
database_user=''

while getopts ':d:u:h' option; do
    case "$option" in
        d)
            database_name=$OPTARG
            ;;
        u)
            database_user=$OPTARG
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

if [[ -z $database_name ]]; then
    if ! IFS= read -r -p 'Database name: ' database_name; then
        printf '\nError: unable to read database name\n' >&2
        exit 64
    fi
fi

if ! validate_database_name "$database_name"; then
    printf 'Error: invalid database name: %q\n' "$database_name" >&2
    printf 'Use 1-64 ASCII letters, digits or underscores.\n' >&2
    exit 64
fi

if [[ -z $database_user ]]; then
    if ! IFS= read -r -p 'MySQL username: ' database_user; then
        printf '\nError: unable to read MySQL username\n' >&2
        exit 64
    fi
fi

if ! validate_database_user "$database_user"; then
    printf 'Error: invalid MySQL username: %q\n' "$database_user" >&2
    printf 'Use 1-32 ASCII letters, digits or underscores.\n' >&2
    exit 64
fi

readonly database_name database_user

if (( EUID != 0 )); then
    printf 'Root privileges are required. Run this script with sudo.\n' >&2
    exit 77
fi

if ! command -v mysql >/dev/null 2>&1; then
    printf 'Error: required command not found: mysql\n' >&2
    exit 69
fi

mysql_command=(
    mysql
    --user=root
    --protocol=socket
    --password
    --batch
    --skip-column-names
)
readonly -a mysql_command

if ! user_exists=$(
    "${mysql_command[@]}" --execute="
        SELECT EXISTS(
            SELECT 1
            FROM mysql.user
            WHERE User = '${database_user}'
              AND Host = 'localhost'
        );
    "
); then
    printf 'Error: unable to check MySQL user: %s@localhost\n' \
        "$database_user" >&2
    exit 70
fi

case "$user_exists" in
    0)
        if ! confirm_user_creation "$database_user"; then
            printf 'No database changes were made.\n' >&2
            exit 1
        fi

        if ! IFS= read -r -s \
            -p "Password for ${database_user}@localhost: " \
            database_password
        then
            printf '\nError: unable to read password\n' >&2
            exit 64
        fi
        printf '\n'

        if [[ -z $database_password ]]; then
            printf 'Error: password cannot be empty\n' >&2
            exit 64
        fi

        if ! IFS= read -r -s \
            -p 'Confirm password: ' \
            password_confirmation
        then
            printf '\nError: unable to read password confirmation\n' >&2
            exit 64
        fi
        printf '\n'

        if [[ $database_password != "$password_confirmation" ]]; then
            unset database_password password_confirmation
            printf 'Error: passwords do not match\n' >&2
            exit 64
        fi

        unset password_confirmation
        create_database_user=true
        ;;
    1)
        create_database_user=false
        printf 'Reusing existing MySQL user: %s@localhost\n' \
            "$database_user"
        ;;
    *)
        printf 'Error: unexpected response while checking MySQL user: %q\n' \
            "$user_exists" >&2
        exit 70
        ;;
esac
if [[ $create_database_user == true ]]; then
    escaped_password=$(escape_sql_string "$database_password")
fi

# Apply all changes through one client session. Standard input remains attached
# to the terminal for the root password prompt. SQL is provided separately on
# file descriptor 3, so neither password is included in the process arguments.
if ! "${mysql_command[@]}" \
    --execute='source /dev/fd/3' \
    3< <(
    printf "%s\n" "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';"
    printf 'CREATE DATABASE IF NOT EXISTS `%s`;\n' "$database_name"

    if [[ $create_database_user == true ]]; then
        printf "CREATE USER '%s'@'localhost' IDENTIFIED BY '%s';\n" \
            "$database_user" \
            "$escaped_password"
    fi

    # ALL PRIVILEGES is intentionally limited to this database. It does not
    # grant global privileges or GRANT OPTION.
   printf 'GRANT ALL PRIVILEGES ON `%s`.* TO ' "$database_name"
   printf "'%s'@'localhost';\n" "$database_user"
) >/dev/null
then
    unset database_password escaped_password 2>/dev/null || true
    printf 'Error: unable to apply MySQL configuration\n' >&2
    printf 'Database: %s\n' "$database_name" >&2
    printf 'User:     %s@localhost\n' "$database_user" >&2
    exit 70
fi

unset database_password escaped_password 2>/dev/null || true

printf 'Database ready: %s\n' "$database_name"

if [[ $create_database_user == true ]]; then
    printf 'Created MySQL user: %s@localhost\n' "$database_user"
fi

printf 'Granted access to %s for %s@localhost.\n' \
    "$database_name" "$database_user"
printf 'MySQL configuration completed successfully.\n'