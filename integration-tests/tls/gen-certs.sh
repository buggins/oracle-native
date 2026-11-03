#!/bin/sh
# Generates the test CA and the server certificate (for localhost and 127.0.0.1) used by
# start-proxy.sh. Test material only: the keys are public.
set -e
cd "$(dirname "$0")"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=oracle-native test CA" \
    -keyout ca.key -out ca.pem
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile server.ext \
    -out server.crt
cat server.crt server.key > server.pem
rm -f server.csr server.ext server.crt server.key ca.srl
