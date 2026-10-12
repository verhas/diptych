#!/usr/bin/env bash
# Test file servers for Diptych's Connect to Server, on a Debian machine on
# the local network (a Raspberry Pi will do). SMB, NFS and FTP run on the
# host; WebDAV runs in a container, on a port that does not clash with
# Pi-hole's web page. All of them are announced by Bonjour (Avahi), so they
# show under "On This Network" in the sheet.
#
#   sudo ./setup.sh
#
# Safe to run again. Settings, all optional:
#   PASSWORD=...   the test user's password          (default diptych-test)
#   LAN=...        who may mount the NFS exports     (default: this machine's subnet)
#   DAV_PORT=...   the WebDAV port                   (default 8642)
set -euo pipefail

NAME=diptych
PASSWORD=${PASSWORD:-diptych-test}
DAV_PORT=${DAV_PORT:-8642}
ROOT=/srv/diptych
HERE=$(cd "$(dirname "$0")" && pwd)

[[ $EUID -eq 0 ]] || { echo "Run it with sudo." >&2; exit 1; }

if [[ -z ${LAN:-} ]]; then
  dev=$(ip route show default | awk '{print $5; exit}')
  LAN=$(ip -o -4 route show dev "$dev" scope link | awk '{print $1; exit}')
fi
[[ -n $LAN ]] || { echo "Could not tell the local subnet; set LAN=192.168.1.0/24 or so." >&2; exit 1; }

apt-get update
apt-get install -y samba nfs-kernel-server vsftpd avahi-daemon git

# ---------------------------------------------------------------- the user
# One test user owns the files and logs in to SMB and FTP. It has no shell,
# so its password opens nothing else. vsftpd only lets in users whose shell
# is in /etc/shells, hence the line there.
if ! id "$NAME" >/dev/null 2>&1; then
  useradd -m -s /usr/sbin/nologin "$NAME"
fi
echo "$NAME:$PASSWORD" | chpasswd
grep -qx /usr/sbin/nologin /etc/shells || echo /usr/sbin/nologin >> /etc/shells
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | smbpasswd -s -a "$NAME" >/dev/null
UID_=$(id -u "$NAME"); GID_=$(id -g "$NAME")

# ---------------------------------------------------------------- the files
PNG=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==

# Something to look at in each place, only where it is still empty.
fill() {
  local d=$1
  mkdir -p "$d"
  [[ -z $(ls -A "$d") ]] || return 0
  mkdir -p "$d/Pictures" "$d/Many" "$d/Project"
  printf 'Hello from %s\n' "$(hostname)" > "$d/notes.txt"
  printf 'x' > "$d/._notes.txt"     # macOS metadata beside its file: hidden
  printf 'x' > "$d/._orphan"        # one without a partner: shown
  for n in red green blue; do echo "$PNG" | base64 -d > "$d/Pictures/$n.png"; done
  for i in $(seq 1 2000); do echo "$i" > "$d/Many/file-$i.txt"; done
  echo "# A repository" > "$d/Project/README.md"
  git -C "$d/Project" init -q
  git -C "$d/Project" add README.md
  git -C "$d/Project" -c user.name=Diptych -c user.email=test@example.invalid commit -qm first
  echo changed >> "$d/Project/README.md"
  ln -s notes.txt "$d/link-to-notes"
  ln -s missing.txt "$d/broken-link"
}

for place in smb smb-readonly nfs ftp dav; do fill "$ROOT/$place"; done
mkdir -p "$ROOT/nfs-strict/open" "$ROOT/nfs-strict/private"
echo "Everyone may read this." > "$ROOT/nfs-strict/open/readme.txt"
echo "Only $NAME may read this." > "$ROOT/nfs-strict/private/secret.txt"
chown -R "$NAME:$NAME" "$ROOT"
chmod 755 "$ROOT" "$ROOT"/*
chmod 700 "$ROOT/nfs-strict/private"

# ---------------------------------------------------------------- SMB
cat > /etc/samba/diptych.conf <<EOF
[diptych]
   path = $ROOT/smb
   valid users = $NAME
   read only = no
   force user = $NAME

[diptych-readonly]
   path = $ROOT/smb-readonly
   valid users = $NAME
   read only = yes
EOF
grep -q '/etc/samba/diptych.conf' /etc/samba/smb.conf \
  || printf '\ninclude = /etc/samba/diptych.conf\n' >> /etc/samba/smb.conf
testparm -s >/dev/null 2>&1 || { echo "smb.conf has a problem: run testparm." >&2; exit 1; }

# ---------------------------------------------------------------- NFS
# insecure: macOS mounts from a port above 1024.
# nfs: every Mac user becomes $NAME, so it can be written to.
# nfs-strict: user numbers are kept, so a Mac user (501) cannot open private/.
mkdir -p /etc/exports.d
cat > /etc/exports.d/diptych.exports <<EOF
$ROOT/nfs        $LAN(rw,sync,no_subtree_check,insecure,all_squash,anonuid=$UID_,anongid=$GID_)
$ROOT/nfs-strict $LAN(rw,sync,no_subtree_check,insecure)
EOF

# ---------------------------------------------------------------- FTP
# Read-only either way (macOS mounts FTP read-only), as $NAME or anonymous.
# Only those listed may log in: no other account's password goes over FTP.
[[ -f /etc/vsftpd.conf.orig ]] || cp /etc/vsftpd.conf /etc/vsftpd.conf.orig
cat > /etc/vsftpd.conf <<EOF
listen=NO
listen_ipv6=YES
anonymous_enable=YES
no_anon_password=YES
anon_root=$ROOT/ftp
local_enable=YES
local_root=$ROOT/ftp
write_enable=NO
chroot_local_user=YES
allow_writeable_chroot=YES
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd.userlist
pam_service_name=vsftpd
secure_chroot_dir=/var/run/vsftpd/empty
EOF
printf '%s\nanonymous\nftp\n' "$NAME" > /etc/vsftpd.userlist

# ---------------------------------------------------------------- Bonjour
# Samba announces _smb._tcp itself; these announce the rest.
announce() {  # file, name, type, port, [path]
  {
    echo '<?xml version="1.0" standalone="no"?>'
    echo '<!DOCTYPE service-group SYSTEM "avahi-service.dtd">'
    echo '<service-group>'
    echo "  <name replace-wildcards=\"yes\">$2</name>"
    echo "  <service><type>$3</type><port>$4</port>"
    if [[ -n ${5:-} ]]; then echo "    <txt-record>path=$5</txt-record>"; fi
    echo '  </service>'
    echo '</service-group>'
  } > "/etc/avahi/services/$1.service"
}
announce diptych-nfs        '%h NFS'        _nfs._tcp    2049 "$ROOT/nfs"
announce diptych-nfs-strict '%h NFS strict' _nfs._tcp    2049 "$ROOT/nfs-strict"
announce diptych-ftp        '%h FTP'        _ftp._tcp    21
announce diptych-webdav     '%h WebDAV'     _webdav._tcp "$DAV_PORT" /dav

# ---------------------------------------------------------------- start
systemctl enable --now smbd nfs-server vsftpd avahi-daemon
systemctl restart smbd vsftpd avahi-daemon
exportfs -ra

if command -v docker >/dev/null; then
  (cd "$HERE/webdav" && PASSWORD=$PASSWORD DAV_PORT=$DAV_PORT ROOT=$ROOT docker compose up -d)
else
  echo "No docker here: WebDAV was not started." >&2
fi

host=$(hostname).local
cat <<EOF

Ready. In Diptych, Go > Connect to Server (Cmd-K), as $NAME / $PASSWORD:

  smb://$host/diptych            SMB, read and write
  smb://$host/diptych-readonly   SMB, read-only share
  nfs://$host$ROOT/nfs           NFS, read and write, no password
  nfs://$host$ROOT/nfs-strict    NFS, private/ refused to the Mac's user
  ftp://$host                    FTP, read-only (or as guest)
  http://$host:$DAV_PORT/dav     WebDAV, read and write
EOF
