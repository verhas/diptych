#!/usr/bin/env python3
"""Signs a Windows PE file with Authenticode, by a made-up certificate.

    sign-pe-sample.py input.exe output.exe

For Diptych's sample files only: a "Diptych Sample Code Signing CA" and a
signing certificate under it are made afresh each run, and nothing trusts
them. The signature has the shape Windows expects -- SpcIndirectDataContent
with the SHA-256 hash of the image, in PKCS#7 SignedData with a signing time
-- so Diptych's preview can show who signed it and check the hash. Needs the
`cryptography` package.
"""
import datetime
import hashlib
import struct
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def der(tag, body):
    length = len(body)
    if length < 0x80:
        head = bytes([length])
    else:
        octets = length.to_bytes((length.bit_length() + 7) // 8, "big")
        head = bytes([0x80 | len(octets)]) + octets
    return bytes([tag]) + head + body


def seq(*parts):
    return der(0x30, b"".join(parts))


def der_set(*parts):
    return der(0x31, b"".join(sorted(parts)))


def oid(text):
    numbers = [int(n) for n in text.split(".")]
    body = bytes([numbers[0] * 40 + numbers[1]])
    for n in numbers[2:]:
        chunk = [n & 0x7F]
        n >>= 7
        while n:
            chunk.insert(0, 0x80 | (n & 0x7F))
            n >>= 7
        body += bytes(chunk)
    return der(0x06, body)


def integer(value):
    return der(0x02, value.to_bytes((value.bit_length() + 8) // 8, "big"))


NULL = b"\x05\x00"
SHA256 = seq(oid("2.16.840.1.101.3.4.2.1"), NULL)
SPC_INDIRECT = "1.3.6.1.4.1.311.2.1.4"


def certificates():
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Diptych Sample Code Signing CA"),
                         x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Diptych Samples")])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=3650))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
          .sign(ca_key, hashes.SHA256()))
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Diptych Sample Code Signing"),
                      x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Diptych Samples")])
    leaf = (x509.CertificateBuilder().subject_name(name).issuer_name(ca_name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=825))
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    return key, leaf, ca


def image_hash(data, checksum, entry):
    return hashlib.sha256(data[:checksum] + data[checksum + 4:entry] + data[entry + 8:]).digest()


def main(source, target):
    data = bytearray(open(source, "rb").read())
    header = struct.unpack_from("<I", data, 0x3C)[0]
    optional = header + 24
    wide = struct.unpack_from("<H", data, optional)[0] == 0x20B
    checksum = optional + 64
    entry = optional + (112 if wide else 96) + 4 * 8
    if struct.unpack_from("<II", data, entry) != (0, 0):
        sys.exit("already signed")
    data += b"\0" * (-len(data) % 8)
    table = len(data)

    digest = image_hash(bytes(data), checksum, entry)
    obsolete = der(0x80, "<<<Obsolete>>>".encode("utf-16-be"))
    pe_image = seq(der(0x03, b"\x00"), der(0xA0, der(0xA2, obsolete)))
    indirect = seq(seq(oid("1.3.6.1.4.1.311.2.1.15"), pe_image), seq(SHA256, der(0x04, digest)))
    # The message digest is of the content's value, without its own header.
    body = indirect[2:] if indirect[1] < 0x80 else indirect[2 + (indirect[1] & 0x7F):]

    key, leaf, ca = certificates()
    when = datetime.datetime.now(datetime.timezone.utc).strftime("%y%m%d%H%M%SZ").encode()
    attributes = [seq(oid("1.2.840.113549.1.9.3"), der_set(oid(SPC_INDIRECT))),
                  seq(oid("1.2.840.113549.1.9.5"), der_set(der(0x17, when))),
                  seq(oid("1.2.840.113549.1.9.4"), der_set(der(0x04, hashlib.sha256(body).digest())))]
    signed_attributes = der_set(*attributes)
    signature = key.sign(signed_attributes, padding.PKCS1v15(), hashes.SHA256())
    issuer = leaf.issuer.public_bytes()
    signer = seq(integer(1), seq(issuer, integer(leaf.serial_number)), SHA256,
                 b"\xA0" + signed_attributes[1:], seq(oid("1.2.840.113549.1.1.1"), NULL),
                 der(0x04, signature))
    certs = leaf.public_bytes(serialization.Encoding.DER) + ca.public_bytes(serialization.Encoding.DER)
    signed_data = seq(integer(1), der_set(SHA256), seq(oid(SPC_INDIRECT), der(0xA0, indirect)),
                      der(0xA0, certs), der_set(signer))
    pkcs7 = seq(oid("1.2.840.113549.1.7.2"), der(0xA0, signed_data))

    length = 8 + len(pkcs7)
    blob = struct.pack("<IHH", length, 0x0200, 0x0002) + pkcs7
    blob += b"\0" * (-len(blob) % 8)
    struct.pack_into("<II", data, entry, table, len(blob))
    data += blob
    open(target, "wb").write(bytes(data))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
