#!/bin/sh
# Runs both long-lived processes as the unprivileged tproxy user. The relay is
# the only public listener; MTProxy stays reachable at 127.0.0.1:2398 inside the
# container, and the container publishes only the relay port on host loopback.
set -eu

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

: "${MTPROXY_SECRET_HEX:?}"
: "${TPROXY_CONFIG:?}"
: "${MTPROXY_STATE_DIR:?}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-8888}"
MTPROXY_NAT_ARGS="${MTPROXY_NAT_ARGS:-}"

set -- -u tproxy -p "$MTPROXY_STATS_PORT" -H 2398 -S "$MTPROXY_SECRET_HEX" \
	--aes-pwd "$MTPROXY_STATE_DIR/proxy-secret" \
	"$MTPROXY_STATE_DIR/proxy-multi.conf" \
	-M "$MTPROXY_WORKERS" -C "$MTPROXY_MAX_CONNECTIONS"
if [ -n "$MTPROXY_NAT_ARGS" ]; then
	# shellcheck disable=SC2086 # two validated words: --nat-info <local>:<public>
	set -- "$@" $MTPROXY_NAT_ARGS
fi

log "starting mtproto-proxy"
mtproto-proxy "$@" &
mtpid=$!

log "starting tproxy-server"
tproxy-server -config "$TPROXY_CONFIG" &
relaypid=$!

stopping=0
stop_children() {
	[ "$stopping" -eq 1 ] && return 0
	stopping=1
	kill -TERM "$relaypid" 2>/dev/null || true
	kill -TERM "$mtpid" 2>/dev/null || true
	wait "$relaypid" 2>/dev/null || true
	wait "$mtpid" 2>/dev/null || true
}
trap 'stop_children; exit 0' TERM INT

while :; do
	if ! kill -0 "$mtpid" 2>/dev/null; then
		log "mtproto-proxy exited unexpectedly"
		stop_children
		exit 1
	fi
	if ! kill -0 "$relaypid" 2>/dev/null; then
		log "tproxy-server exited unexpectedly"
		stop_children
		exit 1
	fi
	sleep 1
done
