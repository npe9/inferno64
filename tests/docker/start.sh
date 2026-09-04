#!/bin/sh
# Container entrypoint: configure and launch sshd + Postfix (SMTPS) + Dovecot
# (IMAPS) using the TLS cert, ssh host key, and authorized_keys the host put
# in /shared. All three services authenticate the single 'tester' account.
set -eu

SHARED=${SHARED:-/shared}
MAILPASS=${MAILPASS:-s3cret}
HOSTN=${MAILHOST:-mail.test.local}
DOMAIN=${MAILDOMAIN:-test.local}

for f in server.crt server.key ssh_host_rsa_key ssh_host_rsa_key.pub authorized_keys; do
	test -f "$SHARED/$f" || { echo "start: missing $SHARED/$f" >&2; exit 1; }
done

# --- TLS material shared by Postfix and Dovecot ---
# Postfix's smtpd loads the key as the unprivileged 'postfix' user, so the
# key must be group-readable by it (Dovecot loads it as root, so it is fine
# either way).
install -m 644 "$SHARED/server.crt" /etc/ssl/mail.crt
install -m 640 -g postfix "$SHARED/server.key" /etc/ssl/mail.key

# --- tester's Maildir ---
install -d -o tester -g tester /home/tester/Maildir

# --- Dovecot: IMAPS only, passwd-file auth, and a SASL socket for Postfix ---
cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap
listen = *
ssl = required
ssl_cert = </etc/ssl/mail.crt
ssl_key = </etc/ssl/mail.key
ssl_min_protocol = TLSv1.2
mail_location = maildir:/home/tester/Maildir
disable_plaintext_auth = no
auth_mechanisms = plain login
service imap-login {
  inet_listener imap {
    port = 0
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
passdb {
  driver = passwd-file
  args = scheme=PLAIN username_format=%u /etc/dovecot/users
}
userdb {
  driver = static
  args = uid=tester gid=tester home=/home/tester
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
log_path = /dev/stderr
info_log_path = /dev/stderr
EOF
printf 'tester@%s:{PLAIN}%s\n' "$HOSTN" "$MAILPASS" > /etc/dovecot/users
# the dovecot auth process runs as the dovecot user, so it must be able to read this
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# unlock the tester account (useradd left its password locked, which sshd
# rejects even for publickey auth); the password itself is unused since
# sshd runs with PasswordAuthentication=no
echo "tester:$MAILPASS" | chpasswd

# --- Postfix: local delivery to Maildir, SASL via Dovecot, SMTPS on 465 ---
postconf -e "myhostname = $HOSTN"
postconf -e "mydomain = $DOMAIN"
postconf -e "myorigin = $HOSTN"
postconf -e "mydestination = $HOSTN, localhost.localdomain, localhost"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_tls_cert_file = /etc/ssl/mail.crt"
postconf -e "smtpd_tls_key_file = /etc/ssl/mail.key"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_relay_restrictions = permit_sasl_authenticated permit_mynetworks reject_unauth_destination"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128"
postconf -e "maillog_file = /dev/stdout"
# implicit-TLS submission on 465 (unchrooted so it can reach the dovecot
# SASL socket). Append the service block directly - the canonical form.
cat >> /etc/postfix/master.cf <<'EOF'
smtps     inet  n       -       n       -       -       smtpd
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
EOF
newaliases 2>/dev/null || true

# --- sshd host key and tester's authorized_keys ---
mkdir -p /run/sshd
install -m 600 "$SHARED/ssh_host_rsa_key" /etc/ssh/ssh_host_rsa_key
install -m 644 "$SHARED/ssh_host_rsa_key.pub" /etc/ssh/ssh_host_rsa_key.pub
install -d -o tester -g tester -m 700 /home/tester/.ssh
install -o tester -g tester -m 600 "$SHARED/authorized_keys" /home/tester/.ssh/authorized_keys

echo "start: launching postfix, dovecot, sshd for $HOSTN"
postfix start
dovecot
# sshd in the foreground keeps the container alive
exec /usr/sbin/sshd -D -e \
	-o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o UsePAM=no \
	-o "PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-256" \
	-o "HostKeyAlgorithms=+ssh-rsa" \
	-o PidFile=none -o StrictModes=no
