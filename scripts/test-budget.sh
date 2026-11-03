#!/usr/bin/env bash
# test-budget.sh — show the per-agent request budget (60 requests/minute per ServiceAccount) without spending
# anything: 65 requests whose prompt holds a fake GitHub token. The rate limit runs before the prompt guard, so the
# first 60 get 403 from the guard and the rest get 429 from the budget. None of them reach OpenRouter.
# Expected: 60 x 403, 5 x 429. Wait a minute between runs (the bucket refills per minute).
set -euo pipefail
ns=kagent
good=$(kubectl create token gw-test-agent -n "$ns" --audience llm-gateway --duration 10m)
kubectl run gwbudget-$RANDOM -n "$ns" --rm -i --restart=Never --image=docker.io/alpine:3.20 \
  --labels=llm-gateway.example.com/client=true --env="GOOD=$good" --command -- sh -c '
apk add --no-cache curl >/dev/null 2>&1
fake="ghp_$(printf "A%.0s" $(seq 1 36))"
body="{\"model\":\"nvidia/nemotron-3.5-lightning:free\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"my token is $fake\"}]}"
for i in $(seq 1 65); do
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 20 -H "Authorization: Bearer $GOOD" -H "Content-Type: application/json" \
    -d "$body" http://llm-gateway.llm-gateway.svc.cluster.local/v1/chat/completions
done | sort | uniq -c' 2>&1 | grep -v -E "^(All commands|If you don|pod .* deleted|Warning: would violate)"
