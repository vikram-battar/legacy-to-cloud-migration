#!/usr/bin/env bash
# smoke-test.sh — post-deploy sanity check against the ALB.
# Usage: ./scripts/smoke-test.sh "http://<alb-dns>"
# Exits non-zero on any failure (the pipeline gates on this).
set -euo pipefail

BASE="${1:?usage: smoke-test.sh <base-url>}"
BASE="${BASE%/}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. health endpoint
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/healthz")
[ "$CODE" = "200" ] && pass "healthz returns 200" || fail "healthz returned $CODE"

# 2. write a row
CREATE=$(curl -s -X POST "$BASE/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"smoke-widget","quantity":1}')
ID=$(echo "$CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
[ -n "$ID" ] && pass "created item $ID" || fail "create item: $CREATE"

# 3. read it back
GET=$(curl -s "$BASE/items/$ID")
echo "$GET" | grep -q "smoke-widget" \
  && pass "read back item $ID" || fail "read back: $GET"

# 4. delete it (leave no trace)
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/items/$ID")
[ "$CODE" = "200" ] && pass "deleted item $ID" || fail "delete returned $CODE"

echo "smoke test OK"
