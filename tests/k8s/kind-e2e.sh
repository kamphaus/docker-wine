#!/usr/bin/env bash
# Deploy IMAGE to the current kind cluster under Pod Security "restricted" and connect through oc-rdp.
# Usage: tests/k8s/kind-e2e.sh IMAGE      (requires kind, kubectl, docker and an existing kind cluster)
set -euo pipefail
image=${1:?usage: tests/k8s/kind-e2e.sh IMAGE}
cd "$(dirname "$0")/../.."
cluster=${KIND_CLUSTER:-kind}
ns=desktop-e2e

docker tag "$image" docker-wine:kind-e2e
kind load docker-image docker-wine:kind-e2e --name "$cluster"
docker build -q -t desktop-test-rdp-client tests/rdp-client >/dev/null

tunnel=""
finish() {
    [ -z "$tunnel" ] || kill "$tunnel" 2>/dev/null || true
    docker rm -f kind-e2e-client >/dev/null 2>&1 || true
}
trap finish EXIT

kubectl apply -k tests/k8s/overlay
if ! kubectl -n "$ns" rollout status deployment/wine-desktop --timeout=600s; then
    kubectl -n "$ns" describe pods
    kubectl -n "$ns" logs deployment/wine-desktop --tail=100 || true
    echo "FAIL [kind-e2e]: deployment did not become ready" >&2
    exit 1
fi

scripts/oc-rdp -n "$ns" wine-desktop 13389 >/dev/null 2>&1 &
tunnel=$!
up=no
for _ in $(seq 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/13389) 2>/dev/null; then up=yes; break; fi
    sleep 1
done
if [ "$up" != yes ]; then
    echo "FAIL [kind-e2e]: port-forward on 127.0.0.1:13389 never opened" >&2
    exit 1
fi
# -i --init: xfreerdp exits on stdin=/dev/null, and xvfb-run as PID 1 would never start the client
docker run -d -i --init --name kind-e2e-client --network host desktop-test-rdp-client \
    xvfb-run -a xfreerdp /v:127.0.0.1:13389 /cert:ignore /sec:tls /u:wineuser /p:unused /sound:sys:fake +clipboard >/dev/null

for _ in $(seq 60); do
    # capture first: never pipe into grep -q under pipefail
    log=$(kubectl -n "$ns" exec deployment/wine-desktop -- cat /run/desktop/log/xrdp.log 2>/dev/null || true)
    if grep -q 'connected to X11rdp_pid' <<<"$log"; then
        echo "PASS [kind-e2e]"
        exit 0
    fi
    sleep 2
done
kubectl -n "$ns" logs deployment/wine-desktop --tail=100 || true
docker logs kind-e2e-client 2>&1 | tail -20 || true
echo "FAIL [kind-e2e]: no RDP session through the port-forward tunnel" >&2
exit 1
