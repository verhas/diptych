#!/bin/sh
# The password file, written from the environment, and the WebDAV settings
# added to Apache's; then Apache.
set -e
cd /usr/local/apache2
# Whoever Apache runs as -- www-data in this image, daemon in older ones --
# must be able to write the files and its lock database.
user=$(awk '/^User /{print $2}' conf/httpd.conf)
group=$(awk '/^Group /{print $2}' conf/httpd.conf)
mkdir -p var
chown -R "$user:$group" var /data
realm="Diptych test"
hash=$(printf '%s:%s:%s' "$DAV_USER" "$realm" "$DAV_PASS" | md5sum | cut -d' ' -f1)
printf '%s:%s:%s\n' "$DAV_USER" "$realm" "$hash" > conf/dav.digest
grep -q 'conf/extra/dav.conf' conf/httpd.conf || echo 'Include conf/extra/dav.conf' >> conf/httpd.conf
exec httpd-foreground
