#!/bin/bash
#
# Makes sample certificates, keys and SSH keys for trying Diptych's
# certificate previews by hand.
#
#   ./make-certificate-samples.sh [folder]   (default: ../test_folder/18-certificates)
#
# Everything is made up: a "Diptych Sample Root CA", an issuing CA under it,
# and certificates for example.com names (reserved for documentation) and
# 192.0.2.10 / 2001:db8::10 (documentation addresses). It writes only into
# the folder given, and only the files named below; nothing is deleted.
# Needs OpenSSL 3.4 or later (for -not_before) and ssh-keygen.
#
# Passwords: every encrypted key here uses sample-pass.
#
#   certificates/  one certificate per file, PEM and DER, valid, expired,
#                  not yet valid, expiring within days; RSA, EC, Ed25519
#   bundles/       chains in and out of order, a certificate with its key and
#                  with someone else's, PKCS#7 bundles, a CRL
#   requests/      certificate signing requests, PEM and DER
#   keys/          private and public keys in PKCS#8, PKCS#1, SEC1, encrypted
#                  and not, PEM and DER
#   ssh/           OpenSSH keys with and without a passphrase, public keys,
#                  RFC 4716, authorized_keys, an SSH certificate

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/18-certificates}"

for tool in openssl ssh-keygen; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done
case "$(openssl version)" in
    "OpenSSL 3."[4-9]*|"OpenSSL 3."[1-9][0-9]*|"OpenSSL "[4-9]*) ;;
    *) echo "needs OpenSSL 3.4 or later, found: $(openssl version)" >&2; exit 1 ;;
esac

mkdir -p "$TARGET"/{certificates,bundles,requests,keys,ssh}
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
O="openssl"
q() { "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------ authorities
q $O req -x509 -newkey rsa:3072 -nodes -keyout root.key -out root.crt -days 3650 \
    -subj "/C=HU/O=Diptych Samples/CN=Diptych Sample Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
cat > ca.ext <<'EXT'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
EXT
q $O req -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -keyout issuing.key -out issuing.csr \
    -subj "/C=HU/O=Diptych Samples/CN=Diptych Sample Issuing CA"
q $O x509 -req -in issuing.csr -CA root.crt -CAkey root.key -out issuing.crt -days 1825 -extfile ca.ext

# ------------------------------------------------------------ certificates
cat > leaf.ext <<'EXT'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
EXT
q $O req -newkey rsa:2048 -nodes -keyout www.key -out www.csr \
    -subj "/C=HU/L=Budapest/O=Diptych Samples/OU=Web/CN=www.example.com" \
    -addext "subjectAltName=DNS:www.example.com,DNS:*.example.com,IP:192.0.2.10,IP:2001:db8::10,email:admin@example.com"
q $O x509 -req -in www.csr -CA issuing.crt -CAkey issuing.key -out www.crt -days 398 \
    -copy_extensions copy -extfile leaf.ext
q $O req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout api.key -out api.csr \
    -subj "/C=HU/O=Diptych Samples/CN=api.example.com" -addext "subjectAltName=DNS:api.example.com"
q $O x509 -req -in api.csr -CA issuing.crt -CAkey issuing.key -out api.crt -days 90 \
    -copy_extensions copy -extfile leaf.ext
q $O req -x509 -newkey ed25519 -nodes -keyout ed25519.key -out ed25519.crt -days 365 \
    -subj "/O=Diptych Samples/CN=ed25519.example.com"
q $O req -x509 -newkey rsa:2048 -nodes -keyout expired.key -out expired.crt \
    -not_before 20240101000000Z -not_after 20250101000000Z -subj "/O=Diptych Samples/CN=expired.example.com"
q $O req -x509 -newkey rsa:2048 -nodes -keyout future.key -out future.crt \
    -not_before 20300101000000Z -not_after 20310101000000Z -subj "/O=Diptych Samples/CN=future.example.com"
q $O req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout soon.key -out soon.crt \
    -days 10 -subj "/O=Diptych Samples/CN=soon.example.com"

C="$TARGET/certificates"
cp root.crt "$C/root-ca.pem"
cp issuing.crt "$C/issuing-ca.crt"
cp www.crt "$C/www.example.com.crt"
$O x509 -in www.crt -outform DER -out "$C/www.example.com.der"
$O x509 -in www.crt -outform DER -out "$C/www.example.com.cer"
cp api.crt "$C/api.example.com.crt"
cp ed25519.crt "$C/ed25519.example.com.crt"
cp expired.crt "$C/expired.crt"
cp future.crt "$C/not-yet-valid.crt"
cp soon.crt "$C/expiring-soon.crt"
printf 'This file is named like a certificate but holds only this sentence.\n' > "$C/not-a-certificate.crt"

# ----------------------------------------------------------------- bundles
B="$TARGET/bundles"
cat www.crt issuing.crt root.crt > "$B/fullchain.pem"
cat root.crt www.crt issuing.crt > "$B/chain-out-of-order.pem"
cat www.crt issuing.crt > "$B/chain-missing-root.pem"
cat www.crt www.key > "$B/www-with-its-key.pem"
cat api.crt expired.key > "$B/api-with-wrong-key.pem"
cat root.crt issuing.crt ed25519.crt expired.crt future.crt soon.crt > "$B/ca-bundle.crt"
$O crl2pkcs7 -nocrl -certfile "$B/fullchain.pem" -outform DER -out "$B/fullchain.p7b"
$O crl2pkcs7 -nocrl -certfile "$B/fullchain.pem" -out "$B/fullchain-pem.p7c"
# A CRL from the issuing CA, with the api certificate revoked.
mkdir ca && touch ca/index.txt && echo 1000 > ca/crlnumber
cat > ca.cnf <<'CNF'
[ ca ]
default_ca = sample
[ sample ]
database = ca/index.txt
crlnumber = ca/crlnumber
default_md = sha384
default_crl_days = 30
CNF
q $O ca -config ca.cnf -cert issuing.crt -keyfile issuing.key -revoke api.crt -crl_reason keyCompromise
q $O ca -config ca.cnf -cert issuing.crt -keyfile issuing.key -gencrl -out "$B/issuing-ca.crl"
$O crl -in "$B/issuing-ca.crl" -outform DER -out "$B/issuing-ca-der.crl"

# ---------------------------------------------------------------- requests
R="$TARGET/requests"
cp www.csr "$R/www.example.com.csr"
cp api.csr "$R/api.example.com.csr"
$O req -in www.csr -outform DER -out "$R/www.example.com-der.req"

# -------------------------------------------------------------------- keys
K="$TARGET/keys"
cp www.key "$K/rsa-pkcs8.key"
$O pkey -in www.key -traditional -out "$K/rsa-pkcs1.key"
$O pkey -in www.key -aes256 -passout pass:sample-pass -out "$K/rsa-pkcs8-encrypted.key"
$O pkey -in www.key -traditional -aes128 -passout pass:sample-pass -out "$K/rsa-pkcs1-encrypted.key"
$O pkey -in www.key -outform DER -out "$K/rsa-pkcs8.der"
$O pkey -in api.key -traditional -out "$K/ec-sec1.key"
$O ecparam -name prime256v1 -genkey -out "$K/ec-with-parameters.pem"
cp ed25519.key "$K/ed25519.key"
$O pkey -in www.key -pubout -out "$K/rsa-public.pem"
$O rsa -in www.key -RSAPublicKey_out -out "$K/rsa-public-pkcs1.pem" 2>/dev/null
$O pkey -in api.key -pubout -out "$K/ec-public.pem"

# --------------------------------------------------------------------- ssh
S="$TARGET/ssh"
rm -f id_* user_ca*
ssh-keygen -q -t ed25519 -N "" -C "sample@diptych.example" -f id_ed25519
ssh-keygen -q -t rsa -b 3072 -N "sample-pass" -C "deploy@diptych.example" -f id_rsa
ssh-keygen -q -t ecdsa -b 256 -N "" -C "ecdsa@diptych.example" -f id_ecdsa
ssh-keygen -q -t ed25519 -N "" -C "Diptych Sample SSH CA" -f user_ca
ssh-keygen -q -s user_ca -I "sample-user" -n alice,deploy -V -1d:+52w -z 42 id_ed25519.pub
# ssh-keygen -e writes the user and host it ran on into the comment; a
# sample says nothing about who made it.
ssh-keygen -e -f id_ed25519.pub | sed 's/^Comment: .*/Comment: "sample@diptych.example"/' > id_ed25519.rfc4716.pub
{
    echo "# Keys allowed to log in -- made-up samples."
    cat id_ed25519.pub
    printf 'from="192.0.2.0/24",no-port-forwarding,no-pty %s\n' "$(cat id_rsa.pub)"
    cat id_ecdsa.pub
    printf 'cert-authority,principals="alice" %s\n' "$(cat user_ca.pub)"
} > authorized_keys
cp id_ed25519 id_ed25519.pub id_rsa id_rsa.pub id_ecdsa id_ecdsa.pub id_ed25519-cert.pub \
   id_ed25519.rfc4716.pub authorized_keys "$S/"
cp user_ca.pub "$S/sample-ssh-ca.pub"

echo "Made in $TARGET:"
(cd "$TARGET" && find . -type f | sort)
