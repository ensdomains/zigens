#!/usr/bin/env bash
# Quick curl probes of the content-negotiation + status-code behavior.
# Usage: ./probe.sh [http://localhost:8080/graphql]
set -u
U="${1:-http://localhost:8080/graphql}"

p() { # prints "<status> <content-type>"
  curl -sS -m 8 -o /dev/null -w '%{http_code} %{content_type}' "$@" "$U"
}
J='content-type: application/json'
A='accept: application/graphql-response+json'

echo "== LEGACY path (default Accept) — MUST stay '200 application/json' (client-compatible) =="
echo "  valid query      -> $(p -X POST -H "$J" -d '{"query":"{ __typename }"}')"
echo "  parse error      -> $(p -X POST -H "$J" -d '{"query":"{ bad"}')"
echo "  validation error -> $(p -X POST -H "$J" -d '{"query":"{ nope }"}')"
echo "  Accept: app/json -> $(p -X POST -H "$J" -H 'accept: application/json' -d '{"query":"{ __typename }"}')"

echo "== STRICT path (Accept: application/graphql-response+json) — spec status codes =="
echo "  valid query      -> $(p -X POST -H "$J" -H "$A" -d '{"query":"{ __typename }"}')   (expect 200 application/graphql-response+json)"
echo "  parse error      -> $(p -X POST -H "$J" -H "$A" -d '{"query":"{ bad"}')   (expect 400)"
echo "  validation error -> $(p -X POST -H "$J" -H "$A" -d '{"query":"{ nope }"}')   (expect 400)"
echo "  bad variables    -> $(p -X POST -H "$J" -H "$A" -d '{"query":"{ __typename }","variables":5}')   (expect 400)"
