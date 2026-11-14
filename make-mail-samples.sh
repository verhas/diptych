#!/bin/bash
#
# Makes sample e-mail files for trying Diptych's mail preview by hand.
#
#   ./make-mail-samples.sh [folder]   (default: ../test_folder/23-mail)
#
# Every message is made up; every address is at example.com, example.org or
# example.net (reserved names). It writes only into the folder given, and
# only the files named below, replacing them when they are there already.
# Needs openssl for the signed message, sips for the picture.
#
#   plain.eml               text in quoted-printable UTF-8, an encoded subject
#   html-only.eml           HTML only, a remote picture and a link that shows
#                           one address and goes to another
#   attachments.eml         a picture, a PDF, and an attachment that runs code
#   suspicious.eml          failed SPF and DMARC, answers going elsewhere
#   signed.eml              S/MIME, signed with a made-up certificate
#   forwarded.eml           a message attached to a message
#   encoded-name.eml        an attachment named in RFC 2231 form
#   Sample.mbox             a mailbox of four messages, one with a quoted
#                           ">From " line
#   Exported.mbox/          a mailbox as Mail exports it: a folder
#   message.emlx            Apple Mail's own form of one message

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/23-mail}"

for tool in openssl sips base64; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

crlf() { sed 's/$/\r/'; }

echo "plain.eml"
crlf > "$TARGET/plain.eml" <<'EOF'
From: =?UTF-8?Q?Zs=C3=B3fia_Minta?= <zsofia@example.com>
To: Sample Reader <reader@example.org>
Subject: =?UTF-8?B?w4lrZXpldGVrIMOpcyBob3NzesO6IHNvcm9r?=
Date: Tue, 10 Nov 2026 09:15:00 +0100
Message-ID: <plain-1@example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: quoted-printable
X-Mailer: Diptych Sample Mailer 1.0

Szia!

Ez egy minta lev=C3=A9l: =C3=A9kezetek, hossz=C3=BA sorok, amelyek =
egy sorban folytat=C3=B3dnak.

=E2=80=94 Zs=C3=B3fia
EOF

echo "html-only.eml"
crlf > "$TARGET/html-only.eml" <<'EOF'
From: Sample Bank <service@example.com>
To: reader@example.org
Subject: Please confirm your account
Date: Wed, 11 Nov 2026 14:02:00 +0000
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

<html><head><style>p { color: #333; }</style></head><body>
<p>Dear customer,</p>
<p>Please confirm your account at <a href="https://login.example.net/confirm?id=1">https://www.example.com/account</a>.</p>
<p><img src="https://tracker.example.net/pixel.gif" width="1" height="1">Thank you &amp; regards,<br>The Sample Bank</p>
</body></html>
EOF

sips -s format png -z 48 48 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
    --out "$WORK/picture.png" >/dev/null
cat > "$WORK/document.pdf" <<'EOF'
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >> endobj
trailer << /Root 1 0 R >>
%%EOF
EOF
printf 'MZ (not really a program)' > "$WORK/invoice.pdf.exe"

echo "attachments.eml"
{
cat <<'EOF'
From: Sample Sender <sender@example.com>
To: reader@example.org
Cc: other@example.org
Subject: Three attachments
Date: Thu, 12 Nov 2026 08:30:00 +0000
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="outer-boundary"

This is a multi-part message in MIME format.

--outer-boundary
Content-Type: multipart/alternative; boundary="inner-boundary"

--inner-boundary
Content-Type: text/plain; charset=us-ascii

Here are the files: a picture, a PDF, and something that is not an invoice.

--inner-boundary
Content-Type: text/html; charset=us-ascii

<p>Here are the files: a picture, a PDF, and something that is not an invoice.</p>
--inner-boundary--

--outer-boundary
Content-Type: image/png; name="picture.png"
Content-Disposition: attachment; filename="picture.png"
Content-Transfer-Encoding: base64

EOF
base64 -b 76 -i "$WORK/picture.png"
cat <<'EOF'

--outer-boundary
Content-Type: application/pdf; name="document.pdf"
Content-Disposition: attachment; filename="document.pdf"
Content-Transfer-Encoding: base64

EOF
base64 -b 76 -i "$WORK/document.pdf"
cat <<'EOF'

--outer-boundary
Content-Type: application/octet-stream; name="invoice.pdf.exe"
Content-Disposition: attachment; filename="invoice.pdf.exe"
Content-Transfer-Encoding: base64

EOF
base64 -b 76 -i "$WORK/invoice.pdf.exe"
cat <<'EOF'

--outer-boundary--
EOF
} | crlf > "$TARGET/attachments.eml"

echo "suspicious.eml"
crlf > "$TARGET/suspicious.eml" <<'EOF'
Received: from mail.example.net (mail.example.net [192.0.2.10])
	by mx.example.org with ESMTPS id 1A2B3C; Fri, 13 Nov 2026 07:00:02 +0000
Received: from unknown (HELO workstation) ([198.51.100.7])
	by mail.example.net with SMTP; Fri, 13 Nov 2026 07:00:00 +0000
Authentication-Results: mx.example.org; spf=fail smtp.mailfrom=example.com;
	dkim=none; dmarc=fail header.from=example.com
From: Sample Director <director@example.com>
Reply-To: director.private@example.net
To: reader@example.org
Subject: Urgent payment today
Date: Fri, 13 Nov 2026 07:00:00 +0000
MIME-Version: 1.0
Content-Type: text/plain; charset=us-ascii

Please pay the attached invoice today and do not tell anybody.
EOF

echo "signed.eml"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Sample Signer/emailAddress=signer@example.com" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
printf 'Content-Type: text/plain; charset=us-ascii\r\n\r\nThis message is signed with a made-up certificate.\r\n' > "$WORK/body.txt"
{
printf 'From: Sample Signer <signer@example.com>\r\nTo: reader@example.org\r\nSubject: A signed message\r\n'
printf 'Date: Sat, 14 Nov 2026 10:00:00 +0000\r\n'
openssl smime -sign -in "$WORK/body.txt" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" 2>/dev/null
} > "$TARGET/signed.eml"

echo "forwarded.eml"
{
cat <<'EOF'
From: Sample Reader <reader@example.org>
To: friend@example.org
Subject: Fwd: Three attachments
Date: Sat, 14 Nov 2026 11:00:00 +0000
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="forward-boundary"

--forward-boundary
Content-Type: text/plain; charset=us-ascii

Look at this one.

--forward-boundary
Content-Type: message/rfc822
Content-Disposition: attachment

EOF
cat "$TARGET/plain.eml" | tr -d '\r'
cat <<'EOF'

--forward-boundary--
EOF
} | crlf > "$TARGET/forwarded.eml"

echo "encoded-name.eml"
{
cat <<'EOF'
From: sender@example.com
To: reader@example.org
Subject: An attachment with an accented name
Date: Sat, 14 Nov 2026 12:00:00 +0000
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="b"

--b
Content-Type: text/plain; charset=utf-8; format=flowed

A line that is long enough to be wrapped by the sender and flowed back
together by the reader.

--b
Content-Type: application/pdf
Content-Disposition: attachment;
 filename*0*=UTF-8''%C3%A1rv%C3%ADzt%C5%B1r%C5%91%20;
 filename*1*=t%C3%BCk%C3%B6rf%C3%BAr%C3%B3g%C3%A9p.pdf
Content-Transfer-Encoding: base64

EOF
base64 -b 76 -i "$WORK/document.pdf"
printf '\n--b--\n'
} | crlf > "$TARGET/encoded-name.eml"

echo "Sample.mbox"
mbox() {
    for file in plain html-only suspicious; do
        echo "From sender@example.com Tue Nov 10 09:15:00 2026"
        tr -d '\r' < "$TARGET/$file.eml"
        echo
    done
    cat <<'EOF'
From reader@example.org Sat Nov 14 13:00:00 2026
From: reader@example.org
To: friend@example.org
Subject: A line that starts with From
Date: Sat, 14 Nov 2026 13:00:00 +0000

The next line started with "From " and was quoted when it was stored:
>From now on, every sample is made up.

EOF
}
mbox > "$TARGET/Sample.mbox"

echo "Exported.mbox"
rm -rf "$TARGET/Exported.mbox"
mkdir -p "$TARGET/Exported.mbox"
mbox > "$TARGET/Exported.mbox/mbox"

echo "message.emlx"
{
size=$(wc -c < "$TARGET/plain.eml" | tr -d ' ')
echo "$size"
cat "$TARGET/plain.eml"
cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>flags</key><integer>8590195713</integer>
</dict>
</plist>
EOF
} > "$TARGET/message.emlx"

echo "Written to $TARGET"
