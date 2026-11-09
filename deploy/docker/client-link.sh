#!/usr/bin/env bash
# Prints the client-facing proxy address, marked secret, and link for the
# deployment described by .env. The marked secret is base64url of the marker
# byte 0x70 followed by the raw secret, so clients without base path support
# report an unsupported proxy type instead of connecting to an empty host.
set -euo pipefail

directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${1:-$directory/.env}"
if [[ ! -f "$env_file" ]]; then
	echo "missing $env_file; copy .env.example and fill it in" >&2
	exit 1
fi
# shellcheck disable=SC1090
. "$env_file"

: "${TPROXY_HOSTNAME:?TPROXY_HOSTNAME is required}"
: "${TPROXY_SECRET:?TPROXY_SECRET is required}"
base_path="${TPROXY_BASE_PATH-proxy}"

if [[ -z "$base_path" ]]; then
	marked_secret="$TPROXY_SECRET"
else
	# Never capture the raw secret in a variable: it can contain NUL bytes,
	# which command substitution drops.
	marked_secret="$({
		printf '\x70'
		printf "$(printf '%s' "$TPROXY_SECRET" | sed 's/../\\x&/g')"
	} | base64 | tr '+/' '-_' | tr -d '=\n')"
fi

server="$TPROXY_HOSTNAME"
if [[ -n "$base_path" ]]; then
	server="$server/$base_path"
fi

printf 'Proxy server: %s\n' "$server"
printf 'Proxy secret: %s\n' "$marked_secret"
printf 'Proxy link:   https://t.me/webproxy?server=%s&secret=%s\n' \
	"${server//\//%2F}" "$marked_secret"
