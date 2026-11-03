#!/usr/bin/env bash
# test-admission-policies.sh — check the ValidatingAdmissionPolicies in manifests/admission/.
# Server-side dry-run: admission policies run on dry-run, and nothing is created.
#   DENY  cases: manifests that would bring back a shared LLM key or bypass the llm-gateway
#   ALLOW cases: the example Agent and ModelConfig from this repo, and a chart-style Deployment with its own Secret
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
fails=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
n=0; m() { n=$((n+1)); cat > "$tmp/$n.yaml"; echo "$tmp/$n.yaml"; }   # stdin -> numbered temp manifest

# expect <DENY|ALLOW> <description> <manifest file>
expect() {
  local want=$1 desc=$2 out got
  out=$(kubectl apply --dry-run=server -f "$3" 2>&1)
  if echo "$out" | grep -q "ValidatingAdmissionPolicy"; then got=DENY; elif echo "$out" | grep -qiE "error|invalid"; then got=ERROR; else got=ALLOW; fi
  if [ "$got" = "$want" ]; then r=PASS; else r=FAIL; fails=$((fails+1)); fi
  printf '%-4s %-62s expected %-5s got %s\n' "$r" "$desc" "$want" "$got"
  [ "$got" = ERROR ] && echo "     $out" | head -2
}

deploy() { # deploy <name> <managed-by label> <env var name> <secret|value> <secret name | literal value>
  local envsrc
  if [ "$4" = secret ]; then
    envsrc=$(printf '              valueFrom:\n                secretKeyRef:\n                  name: %s\n                  key: k' "$5")
  else
    envsrc=$(printf '              value: %s' "$5")
  fi
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
  namespace: kagent
spec:
  selector:
    matchLabels:
      app: $1
  template:
    metadata:
      labels:
        app: $1
        app.kubernetes.io/managed-by: $2
    spec:
      containers:
        - name: c
          image: busybox:1.36
          env:
            - name: $3
$envsrc
EOF
}
agent() { kubectl kustomize manifests/kagent | yq 'select(.kind=="Agent")'; }

echo "== DENY: bringing the shared key back"
expect DENY "agent Deployment with OPENAI_API_KEY from a Secret" "$(deploy adm-test-agent kagent OPENAI_API_KEY secret some-key | m)"
expect DENY "any Deployment referencing kagent-openrouter" "$(deploy adm-test-any helm X secret kagent-openrouter | m)"
expect DENY "Agent without the llm-gateway label" "$(agent | yq '.metadata.name = "adm-test-agent" | del(.metadata.labels)' | m)"
expect DENY "Agent with a non-gw ModelConfig" "$(agent | yq '.metadata.name = "adm-test-agent" | .spec.declarative.modelConfig = "direct-openrouter"' | m)"
f=$(m <<'EOF'
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata: {name: adm-test-direct, namespace: kagent}
spec: {model: openrouter/auto, provider: OpenAI, apiKeySecret: some-key, apiKeySecretKey: k, openAI: {baseUrl: "https://openrouter.ai/api/v1"}}
EOF
)
expect DENY "ModelConfig with apiKeySecret" "$f"
f=$(m <<'EOF'
apiVersion: v1
kind: Secret
metadata: {name: kagent-openrouter, namespace: kagent}
stringData: {OPENROUTER_API_KEY: not-a-real-key}
EOF
)
expect DENY "Secret named kagent-openrouter" "$f"

echo "== ALLOW: what is meant to run"
expect ALLOW "the example Agent (rendered with the sidecar patch)" "$(agent | m)"
expect ALLOW "the gw-* ModelConfig" "$(kubectl kustomize manifests/kagent | yq 'select(.kind=="ModelConfig")' | m)"
expect ALLOW "chart Deployment (not an agent) with its own OpenAI Secret" "$(deploy adm-test-chart helm OPENAI_API_KEY secret kagent-tools-openai | m)"
expect ALLOW "agent Deployment with the placeholder OPENAI_API_KEY" "$(deploy adm-test-placeholder kagent OPENAI_API_KEY value unused-sidecar-injects-sa-token | m)"

exit $fails
