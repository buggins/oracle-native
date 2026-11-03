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

# A client certificate and a PEM wallet with it (as `orapki wallet pem_asn1` writes one: the
# encrypted private key, then the certificates), for mutual TLS tests (start-proxy.sh with
# client verification); wallet password Wallet_pw123.
openssl req -newkey rsa:2048 -nodes -subj "/CN=oracle-native test client" -keyout client.key -out client.csr
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > client.ext
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile client.ext \
    -out client.crt
mkdir -p wallet
openssl pkcs8 -topk8 -in client.key -v2 aes-256-cbc -passout pass:Wallet_pw123 -out wallet/ewallet.pem
cat client.crt ca.pem >> wallet/ewallet.pem
chmod 644 wallet/ewallet.pem
rm -f client.csr client.ext client.crt client.key ca.srl
