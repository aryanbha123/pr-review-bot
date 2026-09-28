#!/bin/bash
# One HTTP request per process. launchd owns 127.0.0.1:$PORT and starts this script
# only when a connection arrives (inetd-style), with the socket on stdin/stdout.
export LC_ALL=C   # ${#body} counts bytes, needed for Content-Length
DIR="$(cd "$(dirname "$0")" && pwd)"
BOT_DIR="$(dirname "$DIR")"
. "$BOT_DIR/config.sh"

respond() {  # status content-type body
  printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nConnection: close\r\n\r\n%s' \
    "$1" "$2" "${#3}" "$3"
}
fail() { respond "$1" "application/json" "{\"ok\":false,\"error\":\"$2\"}"; exit 0; }

IFS=' ' read -r -t 5 METHOD TARGET _ || exit 0
HOST=""; ORIGIN=""; CLEN=0; CTYPE=""; XPRBOT=""
while IFS= read -r -t 5 h; do
  h="${h%$'\r'}"
  [ -z "$h" ] && break
  name="$(printf '%s' "${h%%:*}" | tr 'A-Z' 'a-z')"
  value="${h#*:}"; value="${value# }"
  case "$name" in
    host) HOST="$value" ;;
    origin) ORIGIN="$value" ;;
    content-length) CLEN="$value" ;;
    content-type) CTYPE="$value" ;;
    x-prbot) XPRBOT="$value" ;;
  esac
done
PATH_ONLY="${TARGET%%\?*}"

# DNS-rebinding guard: only answer requests addressed to this machine by name.
case "$HOST" in
  "localhost:$PORT"|"127.0.0.1:$PORT") ;;
  *) fail "421 Misdirected Request" "bad host" ;;
esac

if [ "$METHOD" = "POST" ]; then
  # CSRF guard: same-origin page only. The custom header forces a CORS preflight,
  # which this server never approves, so other sites cannot send it.
  case "$ORIGIN" in
    "http://localhost:$PORT"|"http://127.0.0.1:$PORT") ;;
    *) fail "403 Forbidden" "bad origin" ;;
  esac
  [ "$XPRBOT" = "1" ] || fail "403 Forbidden" "missing X-PRBot header"
  case "$CTYPE" in application/json*) ;; *) fail "415 Unsupported Media Type" "json only" ;; esac
  case "$CLEN" in ''|*[!0-9]*) fail "411 Length Required" "bad length" ;; esac
  [ "$CLEN" -le 65536 ] || fail "413 Payload Too Large" "too large"
  BODY="$(head -c "$CLEN")"
fi

case "$METHOD $PATH_ONLY" in
  "GET /")             respond "200 OK" "text/html; charset=utf-8" "$(cat "$DIR/index.html")" ;;
  "GET /api/status")   respond "200 OK" "application/json" "$("$DIR/api.sh" status 2>&1)" ;;
  "GET /api/settings") respond "200 OK" "application/json" "$("$DIR/api.sh" settings 2>&1)" ;;
  "POST /api/settings") respond "200 OK" "application/json" "$(printf '%s' "$BODY" | "$DIR/api.sh" save-settings 2>&1)" ;;
  "POST /api/keys")    respond "200 OK" "application/json" "$(printf '%s' "$BODY" | "$DIR/api.sh" save-keys 2>&1)" ;;
  "POST /api/test")    respond "200 OK" "application/json" "$(printf '%s' "$BODY" | "$DIR/api.sh" test 2>&1)" ;;
  *)                   respond "404 Not Found" "text/plain" "not found" ;;
esac
