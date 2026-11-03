#!/usr/bin/env bash
# test-llm-gateway-auth.sh — check the llm-gateway's identity, model and content controls (parts 1 and 2).
#
#   case                                                         expected
#   gw-test-agent's token -> its own model                         200   (signature + audience + allow list + model)
#   a ServiceAccount that is not on the allow list (default)       403
#   gw-test-agent's token minted for the wrong audience            401
#   gw-test-agent's token with one signature character changed     401   (proves the JWKS is actually used)
#   gw-test-agent -> a model it is not allowed                     403   (per-agent model allow list)
#   forged x-llm-model header (body asks for another model)        403   (the header is overwritten from the body)
#   prompt containing a fake GitHub token                          403 + prompt-guard message, never sent upstream
#
# Runs from a throwaway pod in kagent labelled so the llm-gateway NetworkPolicy admits it. Needs kubectl access to
# mint tokens (kubectl create token). Run after any change to the gateway policies and after a cluster rebuild.
set -euo pipefail

ns=kagent
own="nvidia/nemotron-3.5-lightning:free"   # gw-test-agent's model (manifests/kagent/modelconfig.yaml)
other="openrouter/auto"                    # any model gw-test-agent is NOT allowed
tok() { kubectl create token "$1" -n "$ns" --audience "${2:-llm-gateway}" --duration 10m; }
good=$(tok gw-test-agent); notallowed=$(tok default); wrongaud=$(tok gw-test-agent not-llm-gateway)
# Flip one character in the middle of the signature segment
sig=${good##*.}; mid=$(( ${#sig} / 2 )); c=${sig:$mid:1}; [ "$c" = "A" ] && r=B || r=A
tampered="${good%.*}.${sig:0:$mid}${r}${sig:$((mid+1))}"
fake_pat="ghp_$(printf 'A%.0s' $(seq 1 36))"

kubectl run gwauth-$RANDOM -n "$ns" --rm -i --restart=Never --image=docker.io/alpine:3.20 \
  --labels=llm-gateway.example.com/client=true \
  --env="GOOD=$good" --env="NOTALLOWED=$notallowed" --env="WRONGAUD=$wrongaud" --env="TAMPERED=$tampered" \
  --env="OWN=$own" --env="OTHER=$other" --env="FAKE_PAT=$fake_pat" \
  --command -- sh -c '
apk add --no-cache curl >/dev/null 2>&1
url=http://llm-gateway.llm-gateway.svc.cluster.local/v1/chat/completions
body() { printf "{\"model\":\"%s\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"%s\"}]}" "$1" "${2:-Reply OK}"; }
fails=0
# check <desc> <token> <expected status> <model> [content] [extra header]
check() {
  out=$(curl -s -w "\n%{http_code}" --max-time 60 -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    ${6:+-H "$6"} -d "$(body "$4" "${5:-Reply OK}")" $url)
  code=$(echo "$out" | tail -1); LAST_BODY=$(echo "$out" | sed "\$d")
  if [ "$code" = "$3" ]; then r=PASS; else r=FAIL; fails=$((fails+1)); fi
  printf "%-4s %-52s expected %-4s got %s\n" "$r" "$1" "$3" "$code"
}
check "gw-test-agent -> own model"                  "$GOOD"       200 "$OWN"
check "ServiceAccount not on the allow list"        "$NOTALLOWED" 403 "$OWN"
check "wrong audience"                              "$WRONGAUD"   401 "$OWN"
check "tampered signature"                          "$TAMPERED"   401 "$OWN"
check "gw-test-agent -> a model it is not allowed"  "$GOOD"       403 "$OTHER"
check "forged x-llm-model header"                   "$GOOD"       403 "$OTHER" "Reply OK" "x-llm-model: $OWN"
check "prompt containing a fake GitHub token"       "$GOOD"       403 "$OWN" "my token is $FAKE_PAT"
if echo "$LAST_BODY" | grep -q "prompt guard"; then echo "PASS   ...rejected by the prompt guard (message matched)"
else echo "FAIL   ...403 did not come from the prompt guard"; fails=$((fails+1)); fi
exit $fails' 2>&1 | grep -v -E "^(All commands|If you don|pod .* deleted|Warning: would violate)"
