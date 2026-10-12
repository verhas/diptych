# Test servers

File servers to try Connect to Server against, on a Debian machine on the
local network: a Raspberry Pi will do, next to Pi-hole. SMB, NFS and FTP
run on the host, WebDAV in a container on port 8642, so nothing takes
Pi-hole's ports 53 and 80. All of them are announced on the network.

```sh
scp -r test-servers pi@raspberrypi.local:
ssh pi@raspberrypi.local
cd test-servers && sudo ./setup.sh
```

It makes a user `diptych` (password `diptych-test`, or `PASSWORD=...`)
with no shell, owner of everything under `/srv/diptych`, and fills each
place with a little of everything: pictures, 2000 small files, a git
repository with a change, a link and a broken one, and a `._` file beside
its partner and one without.

| Address                                    | What it tries                                        |
|--------------------------------------------|------------------------------------------------------|
| `smb://raspberrypi.local/diptych`          | password window, Keychain, writing, sidebar, eject   |
| `smb://raspberrypi.local/diptych-readonly` | write commands greyed, drops refused                 |
| `nfs://raspberrypi.local/srv/diptych/nfs`  | NFS with no password; every Mac user is `diptych`    |
| `nfs://raspberrypi.local/srv/diptych/nfs-strict` | `private/` refused: the message with the user number |
| `ftp://raspberrypi.local`                  | read-only, as `diptych` or as guest                  |
| `http://raspberrypi.local:8642/dav`        | WebDAV, read and write                               |

Changes made on the Pi (`sudo -u diptych touch /srv/diptych/smb/x`) should
show in a pane within five seconds.

To take it all away:

```sh
docker compose -f webdav/compose.yml down
sudo rm /etc/samba/diptych.conf /etc/exports.d/diptych.exports /etc/avahi/services/diptych-*.service
sudo sed -i '/diptych.conf/d' /etc/samba/smb.conf
sudo mv /etc/vsftpd.conf.orig /etc/vsftpd.conf
sudo exportfs -ra && sudo systemctl restart smbd vsftpd avahi-daemon
sudo smbpasswd -x diptych && sudo userdel -r diptych && sudo rm -rf /srv/diptych
```
