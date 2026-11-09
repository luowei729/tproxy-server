#!/usr/bin/env bash
# Prints the values to enter in a Telegram client, plus a shareable link, for the
# deployment described by .env.
#
# Two secret spellings exist and they are not interchangeable:
#
#   typed entry  the plain hex secret, unchanged even under a base path,
#                because the user supplies the path in the server field;
#   link secret  base64url of the marker byte 0x70 followed by the raw secret,
#                so a client without base path support rejects the link instead
#                of connecting to a pathless proxy on an empty host.
#
# Some clients reject the marked form when it is typed by hand, and some reject
# a link carrying an unmarked secret, so print both under distinct labels.
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

server="$TPROXY_HOSTNAME"
if [[ -n "$base_path" ]]; then
	server="$server/$base_path"
fi

if [[ -z "$base_path" ]]; then
	link_secret="$TPROXY_SECRET"
else
	# Never capture the raw secret in a variable: it can contain NUL bytes,
	# which command substitution drops.
	link_secret="$({
		printf '\x70'
		printf "$(printf '%s' "$TPROXY_SECRET" | sed 's/../\\x&/g')"
	} | base64 | tr '+/' '-_' | tr -d '=\n')"
fi

printf 'Proxy server:         %s\n' "$server"
printf 'Proxy secret (typed): %s\n' "$TPROXY_SECRET"
if [[ -n "$base_path" ]]; then
	printf 'Link secret (marked): %s\n' "$link_secret"
fi
printf 'Proxy link:           https://t.me/webproxy?server=%s&secret=%s\n' \
	"${server//\//%2F}" "$link_secret"
