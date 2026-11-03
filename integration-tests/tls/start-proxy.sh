#!/bin/sh
# Starts a TLS-terminating proxy in front of an Oracle listener, as a stand-in for a TCPS
# endpoint (Oracle's TCPS is TLS from the first byte, then the same TNS traffic):
#   sh integration-tests/tls/start-proxy.sh [listener host:port] [TLS port] [container name] [client]
# then run the tests with ORACLE_TLS_HOST=127.0.0.1:<TLS port> ORACLE_TLS_CA=integration-tests/tls/ca.pem.
# With "client" as the fourth argument the proxy requires a client certificate signed by the test CA
# (mutual TLS; tests: ORACLE_TLS_CLIENT_HOST=127.0.0.1:<TLS port>).
set -e
target=${1:-127.0.0.1:1521}
port=${2:-2484}
name=${3:-oracle-native-tls}
verify="verify=0"
if [ "${4:-}" = "client" ]; then
    verify="verify=1,cafile=/tls/ca.pem"
fi
dir=$(cd "$(dirname "$0")" && pwd)
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --network host -v "$dir:/tls:ro" alpine/socat:1.8.0.3 \
    "openssl-listen:$port,reuseaddr,fork,cert=/tls/server.pem,$verify" "tcp:$target"
