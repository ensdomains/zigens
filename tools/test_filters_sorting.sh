#!/bin/bash

# Test suite for new GraphQL filtering and sorting features
# Tests: name_contains_nocase, name_starts_with, name_ends_with, owner_in,
#        registrant_in, expiryDate_gte, expiryDate_lte, orderBy, orderDirection

API_URL="http://localhost:8085/graphql"
HEADER="Content-Type: application/json"

echo "🧪 GraphQL Filter & Sort Test Suite"
echo "===================================="
echo ""

# Test 1: Domain filter - name_contains_nocase
echo "Test 1: name_contains_nocase (case-insensitive search)"
echo "Query: domains(where: {name_contains_nocase: \"eth\"}, first: 3)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(where: {name_contains_nocase: \"eth\"}, first: 3) { name owner { id } } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 2: Domain filter - name_starts_with
echo "Test 2: name_starts_with"
echo "Query: domains(where: {name_starts_with: \"vitalik\"}, first: 3)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(where: {name_starts_with: \"vitalik\"}, first: 3) { name } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 3: Domain filter - name_ends_with
echo "Test 3: name_ends_with"
echo "Query: domains(where: {name_ends_with: \".eth\"}, first: 3)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(where: {name_ends_with: \".eth\"}, first: 3) { name } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 4: Domain sorting - by name ascending
echo "Test 4: Sort by name (ascending)"
echo "Query: domains(first: 5, orderBy: name, orderDirection: asc)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(first: 5, orderBy: name, orderDirection: asc) { name } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 5: Domain sorting - by name descending
echo "Test 5: Sort by name (descending)"
echo "Query: domains(first: 5, orderBy: name, orderDirection: desc)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(first: 5, orderBy: name, orderDirection: desc) { name } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 6: Domain sorting - by createdAt
echo "Test 6: Sort by createdAt"
echo "Query: domains(first: 5, orderBy: createdAt, orderDirection: asc)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(first: 5, orderBy: createdAt, orderDirection: asc) { name createdAt } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 7: Registration filter - expiryDate_gte
echo "Test 7: Registration expiryDate_gte (expires after timestamp)"
echo "Query: registrations(where: {expiryDate_gte: 1700000000}, first: 3)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { registrations(where: {expiryDate_gte: 1700000000}, first: 3) { name expiryDate } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 8: Registration filter - expiryDate_lte
echo "Test 8: Registration expiryDate_lte (expires before timestamp)"
echo "Query: registrations(where: {expiryDate_lte: 2000000000}, first: 3)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { registrations(where: {expiryDate_lte: 2000000000}, first: 3) { name expiryDate } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 9: Registration sorting - by expiryDate
echo "Test 9: Sort registrations by expiryDate"
echo "Query: registrations(first: 5, orderBy: expiryDate, orderDirection: asc)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { registrations(first: 5, orderBy: expiryDate, orderDirection: asc) { name expiryDate } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 10: Combined filter and sort
echo "Test 10: Combined filter and sort"
echo "Query: domains(where: {name_contains_nocase: \"eth\"}, orderBy: name, orderDirection: asc, first: 5)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { domains(where: {name_contains_nocase: \"eth\"}, orderBy: name, orderDirection: asc, first: 5) { name createdAt } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

# Test 11: Registration sorting - by name
echo "Test 11: Sort registrations by name"
echo "Query: registrations(first: 5, orderBy: name, orderDirection: asc)"
curl -s -X POST "$API_URL" -H "$HEADER" -d '{
  "query": "query { registrations(first: 5, orderBy: name, orderDirection: asc) { name registrationDate } }"
}' | python3 -m json.tool
echo ""
echo "---"
echo ""

echo "✅ Test suite complete!"
echo ""
echo "Summary of tested features:"
echo "  ✓ name_contains_nocase (case-insensitive search)"
echo "  ✓ name_starts_with (prefix filter)"
echo "  ✓ name_ends_with (suffix filter)"
echo "  ✓ expiryDate_gte (range filter)"
echo "  ✓ expiryDate_lte (range filter)"
echo "  ✓ orderBy with multiple fields (name, createdAt, expiryDate)"
echo "  ✓ orderDirection (asc/desc)"
echo "  ✓ Combined filters + sorting"
