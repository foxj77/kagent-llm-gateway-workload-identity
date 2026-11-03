#!/usr/bin/env bash
# test-network-policies.sh — check that the NetworkPolicies are actually enforced, by real connection attempts.
#
# "The policy exists" proves nothing. Two things this script does because of that:
#  - Probes run inside a long-lived pod, via kubectl exec, after the pod is Ready. Some CNIs (kindnet, for one) only
#    start policing a pod once they have registered its IP, around the time it turns Ready; a probe that runs as the
#    pod's first command can see everything open.
#  - Agent egress is probed on every worker node. A CNI agent that has failed on one node stops policing new pods
#    there, while probes the scheduler happens to place elsewhere still pass.
set -uo pipefail

fails=0
pod=""
cleanup() { [ -n "$pod" ] && kubectl delete pod -n "$ns" "$pod" --wait=false >/dev/null 2>&1; pod=""; }
trap cleanup EXIT

# start_probe <namespace> <labels or -> [node]
start_probe() {
  cleanup
  ns=$1; pod="np-probe-$RANDOM"
  local args=(); [ "$2" != "-" ] && args+=(--labels="$2")
  [ -n "${3:-}" ] && args+=(--overrides="{\"spec\":{\"nodeName\":\"$3\"}}")
  kubectl run "$pod" -n "$ns" --restart=Never --image=busybox:1.36 "${args[@]}" --command -- sleep 600 >/dev/null
  kubectl wait -n "$ns" --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null
  sleep 3
}
# check <description> <OPEN|BLOCK> <shell test that exits 0 when reachable>
check() {
  local got
  got=$(kubectl exec -n "$ns" "$pod" -- sh -c "if $3 >/dev/null 2>&1; then echo OPEN; else echo BLOCK; fi" 2>/dev/null)
  if [ "$got" = "$2" ]; then r=PASS; else r=FAIL; fails=$((fails+1)); fi
  printf '%-4s %-58s expected %-5s got %s\n' "$r" "$1" "$2" "${got:-ERROR}"
}

gw="nc -z -w 3 llm-gateway.llm-gateway.svc.cluster.local 80"
agent="app.kubernetes.io/managed-by=kagent,app.kubernetes.io/name=np-probe,llm-gateway.example.com/client=true"

echo "== llm-gateway ingress"
start_probe kagent llm-gateway.example.com/client=true
check "kagent pod WITH client label -> llm-gateway:80"      OPEN  "$gw"
start_probe kagent -
check "kagent pod without client label -> llm-gateway:80"   BLOCK "$gw"
start_probe default llm-gateway.example.com/client=true
check "default ns pod WITH client label -> llm-gateway:80"  BLOCK "$gw"

# A probe labelled like an agent (managed-by=kagent) is selected by agent-egress.
echo "== agent egress"
start_probe kagent "$agent"
check "agent -> DNS"                              OPEN  "nslookup -timeout=3 kubernetes.default.svc.cluster.local"
check "agent -> llm-gateway:80"                   OPEN  "$gw"
check "agent -> kagent-controller:8083"           OPEN  "nc -z -w 3 kagent-controller.kagent 8083"
check "agent -> kagent-tools:8084"                OPEN  "nc -z -w 3 kagent-tools.kagent 8084"
check "agent -> internet 1.1.1.1:443"             BLOCK "nc -z -w 3 1.1.1.1 443"
check "agent -> openrouter.ai:443 (direct)"       BLOCK "nc -z -w 3 openrouter.ai 443"
check "agent -> Kubernetes API 10.96.0.1:443"     BLOCK "nc -z -w 3 10.96.0.1 443"

echo "== agent egress on every worker node"
for node in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}'); do
  start_probe kagent "$agent" "$node"
  check "agent on $node -> internet 1.1.1.1:443"  BLOCK "nc -z -w 3 1.1.1.1 443"
  check "agent on $node -> llm-gateway:80"        OPEN  "$gw"
done

cleanup
exit $fails
