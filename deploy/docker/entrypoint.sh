#!/bin/sh
# Container entrypoint. Runs as root only long enough to provision the token
# key, the MTProxy routing files, and the generated configuration, then drops to
# the unprivileged tproxy user for both long-running processes.
set -eu
umask 077

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

[ -n "${TPROXY_HOSTNAME:-}" ] || die "TPROXY_HOSTNAME is required"
[ -n "${TPROXY_SECRET:-}" ] || die "TPROXY_SECRET is required"

case "$TPROXY_HOSTNAME" in
	*[!a-z0-9.-]*|.*|*.|*..*) die "TPROXY_HOSTNAME must be a lowercase ASCII DNS hostname" ;;
esac
case "$TPROXY_HOSTNAME" in
	*.*) ;;
	*) die "TPROXY_HOSTNAME must contain a dot" ;;
esac

# Default proxy keeps the carrier off the host root. An explicitly empty value
# selects the root, matching the systemd installer's --base-path none.
TPROXY_BASE_PATH="${TPROXY_BASE_PATH-proxy}"
if [ -n "$TPROXY_BASE_PATH" ]; then
	[ "${#TPROXY_BASE_PATH}" -le 128 ] || die "TPROXY_BASE_PATH must be at most 128 characters"
	printf '%s' "$TPROXY_BASE_PATH" |
		grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$' ||
		die "TPROXY_BASE_PATH segments must match [A-Za-z0-9][A-Za-z0-9_-]* joined by /"
fi

printf '%s' "$TPROXY_SECRET" | grep -Eq '^([0-9a-f]{32}|dd[0-9a-f]{32})$' ||
	die "TPROXY_SECRET must be 32 lowercase hex characters, optionally prefixed with dd"
secret_hex="$TPROXY_SECRET"
if [ "${#secret_hex}" -eq 34 ]; then
	secret_hex="${secret_hex#dd}"
fi

TPROXY_LISTEN="${TPROXY_LISTEN:-0.0.0.0:65501}"
TPROXY_ADMIN_LISTEN="${TPROXY_ADMIN_LISTEN:-127.0.0.1:65502}"
TPROXY_CARRIER_MODE="${TPROXY_CARRIER_MODE:-https}"
TPROXY_STATE_DIR="${TPROXY_STATE_DIR:-/data}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-8888}"

case "$TPROXY_CARRIER_MODE" in
	https|https-lanes|websocket|websocket-lanes) ;;
	*) die "TPROXY_CARRIER_MODE must be https, https-lanes, websocket, or websocket-lanes" ;;
esac
case "$MTPROXY_WORKERS" in
	''|*[!0-9]*) die "MTPROXY_WORKERS must be a positive integer" ;;
esac
[ "$MTPROXY_WORKERS" -ge 1 ] || die "MTPROXY_WORKERS must be a positive integer"
case "$MTPROXY_MAX_CONNECTIONS" in
	''|*[!0-9]*) die "MTPROXY_MAX_CONNECTIONS must be a positive integer" ;;
esac
[ "$MTPROXY_MAX_CONNECTIONS" -ge 1 ] || die "MTPROXY_MAX_CONNECTIONS must be a positive integer"

# The operator website. Unauthenticated requests under the prefix must receive
# the same responses as the real site, so this is either a copy of that site or
# a loopback/container-reachable mirror of it. The image ships a placeholder at
# /srv/site so the container starts with no host mount at all.
if [ -z "${TPROXY_PUBLIC_DIR:-}" ] && [ -z "${TPROXY_PUBLIC_UPSTREAM:-}" ]; then
	TPROXY_PUBLIC_DIR=/srv/site
fi
site_hint() {
	cat >&2 <<EOF
The image ships a placeholder site at /srv/site, so this error means an explicit
setting pointed somewhere else. Fix one of these, then restart the container:

  A. Use the built-in placeholder (no flags needed):
       unset TPROXY_PUBLIC_DIR TPROXY_PUBLIC_UPSTREAM

  B. Serve your real website instead. Either mount a copy:
       docker run ... -v /srv/www/site:/srv/site:ro -e TPROXY_PUBLIC_DIR=/srv/site

     ...or point at a loopback-reachable mirror of it:
       docker run ... -e TPROXY_PUBLIC_UPSTREAM=http://172.17.0.1:3000

Docker creates a bind-mount source directory that does not exist as an empty
directory, so a mistyped host path looks exactly like this. Check the host:
       ls -la $(printf '%s' "${TPROXY_PUBLIC_DIR:-<host path>}")
EOF
}

if [ -n "${TPROXY_PUBLIC_DIR:-}" ]; then
	case "$TPROXY_PUBLIC_DIR" in
		*\"*|*\\*) die "TPROXY_PUBLIC_DIR must not contain quotes or backslashes" ;;
	esac
	if [ ! -d "$TPROXY_PUBLIC_DIR" ]; then
		log "error: TPROXY_PUBLIC_DIR is not a directory: $TPROXY_PUBLIC_DIR"
		site_hint
		exit 1
	fi
	if [ ! -r "$TPROXY_PUBLIC_DIR/index.html" ]; then
		log "error: TPROXY_PUBLIC_DIR must contain a readable index.html: $TPROXY_PUBLIC_DIR"
		if [ -z "$(ls -A "$TPROXY_PUBLIC_DIR" 2>/dev/null)" ]; then
			log "error: $TPROXY_PUBLIC_DIR is empty, so the host bind-mount source was probably missing"
		fi
		site_hint
		exit 1
	fi
	public_source="\"public_dir\": \"$TPROXY_PUBLIC_DIR\","
elif [ -n "${TPROXY_PUBLIC_UPSTREAM:-}" ]; then
	case "$TPROXY_PUBLIC_UPSTREAM" in
		*\"*|*\\*) die "TPROXY_PUBLIC_UPSTREAM must not contain quotes or backslashes" ;;
	esac
	public_source="\"public_upstream\": \"$TPROXY_PUBLIC_UPSTREAM\","
else
	log "error: neither public_dir nor public_upstream resolved"
	site_hint
	exit 1
fi

state="$TPROXY_STATE_DIR"
mkdir -p "$state" /run/tproxy
# umask 077 would leave the runtime directory unreadable to the unprivileged
# user that has to traverse it. The directory holds no secret itself: the files
# inside are 0400/0600 and owned by tproxy.
chmod 0755 /run/tproxy

# Persistent 32-byte token signing key. Replacing it loses token provenance for
# sessions issued by an earlier run; the key is never derived from the secret.
# The file must be owned by tproxy with mode 0400, which the relay enforces.
#
# Only a newly created key is chmod/chowned. An existing one is verified, never
# repaired: this script runs as root but without DAC_OVERRIDE, so once the key
# belongs to tproxy, root can neither chmod it nor read it back. Metadata alone
# is enough to check, and stat needs no read access to the file.
ensure_token_key() {
	path="$1"
	if [ ! -e "$path" ]; then
		head -c 32 /dev/urandom >"$path"
		chmod 0400 "$path"
		chown tproxy:tproxy "$path"
		return 0
	fi
	[ -f "$path" ] || die "$path must be a regular file"
	size="$(stat -c '%s' "$path")" || die "cannot stat $path"
	owner="$(stat -c '%u' "$path")" || die "cannot stat $path"
	mode="$(stat -c '%a' "$path")" || die "cannot stat $path"
	[ "$size" -eq 32 ] || die "$path must contain exactly 32 bytes; refusing to replace it"
	if [ "$owner" != "$(id -u tproxy)" ] || [ "$mode" != "400" ]; then
		die "$path must be owned by tproxy (uid $(id -u tproxy)) with mode 400, but it is uid $owner mode $mode; fix it on the host: docker run --rm -v tproxy-data:/data --entrypoint /bin/sh $(image_name) -c 'chown 65532:65532 /data/token.key && chmod 400 /data/token.key'"
	fi
}

image_name="${TPROXY_IMAGE_NAME:-ghcr.io/luowei729/tproxy-server:latest}"
ensure_token_key "$state/token.key"

fetch_mtproxy_file() {
	url="$1"
	destination="$2"
	[ -s "$destination" ] && return 0
	temporary="$destination.tmp"
	curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
		--max-time 60 -o "$temporary" "$url" || die "cannot download $url"
	mv -f "$temporary" "$destination"
}

fetch_mtproxy_file https://core.telegram.org/getProxySecret "$state/proxy-secret"
fetch_mtproxy_file https://core.telegram.org/getProxyConfig "$state/proxy-multi.conf"
[ "$(wc -c <"$state/proxy-secret")" -eq 128 ] || die "$state/proxy-secret is not 128 bytes"
[ "$(wc -c <"$state/proxy-multi.conf")" -ge 100 ] || die "$state/proxy-multi.conf is too short"
grep -q '^default ' "$state/proxy-multi.conf" || die "$state/proxy-multi.conf has no default line"
grep -q '^proxy_for ' "$state/proxy-multi.conf" || die "$state/proxy-multi.conf has no proxy_for line"

cat >/run/tproxy/config.json <<EOF
{
  "public_hostname": "$TPROXY_HOSTNAME",
  "base_path": "$TPROXY_BASE_PATH",
  "listen": "$TPROXY_LISTEN",
  "admin_listen": "$TPROXY_ADMIN_LISTEN",
  "container_network": true,
  $public_source
  "static_routes": "exact",
  "token_key_file": "$state/token.key",
  "profiles_file": "/run/tproxy/profiles.json"
}
EOF
cat >/run/tproxy/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$TPROXY_SECRET","backend":"127.0.0.1:2398","carrier_mode":"$TPROXY_CARRIER_MODE"}]}
EOF

# Set modes before changing owners: without DAC_OVERRIDE, root cannot chmod a
# file it no longer owns. The token key was already handled by ensure_token_key,
# which must not touch an existing key for exactly that reason.
chmod 0600 /run/tproxy/config.json /run/tproxy/profiles.json
chown tproxy:tproxy /run/tproxy/config.json /run/tproxy/profiles.json
# MTProxy routing files stay owned by root so this script can validate them on
# every start; the tproxy group only needs read access.
chmod 0640 "$state/proxy-secret" "$state/proxy-multi.conf"
chown root:tproxy "$state/proxy-secret" "$state/proxy-multi.conf"

# MTProxy derives the AES keys for its Telegram middle-end session from its own
# source address. A container is always translated by the Docker bridge, so the
# middle-end would derive a different address and drop every connection right
# after the handshake. --nat-info tells MTProxy both halves.
local_address="${MTPROXY_LOCAL_IP:-}"
if [ -z "$local_address" ] && command -v ip >/dev/null 2>&1; then
	local_address="$(ip -4 route get 149.154.175.50 2>/dev/null |
		sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n 1)"
fi
if [ -z "$local_address" ]; then
	local_address="$(hostname -i 2>/dev/null | awk '{print $1}')"
fi
public_address="${MTPROXY_PUBLIC_IP:-}"
if [ -z "$public_address" ]; then
	for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
		candidate="$(curl -fsSL --ipv4 --max-time 10 "$probe" 2>/dev/null |
			tr -d '[:space:]')" || continue
		case "$candidate" in
			''|*[!0-9.]*) continue ;;
		esac
		public_address="$candidate"
		break
	done
fi
MTPROXY_NAT_ARGS="${MTPROXY_NAT_ARGS:-}"
if [ -z "$MTPROXY_NAT_ARGS" ] && [ -n "$local_address" ] && [ -n "$public_address" ] &&
	[ "$local_address" != "$public_address" ]; then
	MTPROXY_NAT_ARGS="--nat-info $local_address:$public_address"
fi
if [ -z "$public_address" ] && [ -z "$MTPROXY_NAT_ARGS" ]; then
	log "warning: could not determine the public address; set MTPROXY_PUBLIC_IP or"
	log "warning: MTProxy will accept clients and answer none (see README.md)"
fi

export MTPROXY_SECRET_HEX="$secret_hex"
export MTPROXY_NAT_ARGS
export MTPROXY_WORKERS MTPROXY_MAX_CONNECTIONS MTPROXY_STATS_PORT
export MTPROXY_STATE_DIR="$state"
export TPROXY_CONFIG=/run/tproxy/config.json

log "validating configuration"
setpriv --reuid=tproxy --regid=tproxy --clear-groups \
	tproxy-server -config "$TPROXY_CONFIG" \
	-profiles-file /run/tproxy/profiles.json -check

log "hostname=$TPROXY_HOSTNAME base_path=$TPROXY_BASE_PATH listen=$TPROXY_LISTEN"
if [ -n "$MTPROXY_NAT_ARGS" ]; then
	log "mtproxy $MTPROXY_NAT_ARGS"
fi

exec setpriv --reuid=tproxy --regid=tproxy --clear-groups /usr/local/bin/tproxy-run
