#!/bin/bash

echo "Testing with LOWERED limit (max_cost=200)"
echo "==========================================="

pkill -9 -f ensv2-api
sleep 1

./zig-out/bin/ensv2-api > /tmp/api_lowered.log 2>&1 &
API_PID=$!
sleep 3

echo ""
echo "=== Startup logs (should show max_cost=200) ==="
grep "GraphQL" /tmp/api_lowered.log

echo ""
echo "=== Test: Query with cost=300 (should be REJECTED) ==="
curl -s -X POST http://localhost:8085/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{domains(first:100){name}events(first:100){type}registrations(first:100){name}}"}' \
  | python3 -m json.tool

echo ""
echo "=== Test: Simple query with cost < 200 (should pass) ==="
curl -s -X POST http://localhost:8085/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{domains(first:10){name}}"}' \
  | python3 -m json.tool

kill $API_PID 2>/dev/null
