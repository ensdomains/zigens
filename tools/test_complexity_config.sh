#!/bin/bash

# Test configurable complexity limits

echo "Starting API server..."
./zig-out/bin/ensv2-api > /tmp/api.log 2>&1 &
API_PID=$!
sleep 3

echo ""
echo "=== Test 1: Normal query (should pass) ==="
curl -s -X POST http://localhost:8085/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{domains(first:2){name owner{id}}}"}' \
  | python3 -m json.tool

echo ""
echo "=== Test 2: Moderate complexity (cost=300, should pass) ==="
curl -s -X POST http://localhost:8085/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{domains(first:100){name}events(first:100){type}registrations(first:100){name}}"}' \
  | python3 -m json.tool

echo ""
echo "=== Check startup logs for configured limits ==="
grep "GraphQL" /tmp/api.log

kill $API_PID 2>/dev/null
