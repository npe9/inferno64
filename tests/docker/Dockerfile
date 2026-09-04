# A "separate Linux host" for interoperability testing: real OpenSSH sshd,
# real Postfix (SMTP submission over implicit TLS) and real Dovecot (IMAP over
# implicit TLS). The Inferno client runs on the host and speaks to this
# container over the network, so the point is to prove Inferno's ssh(2),
# smtp2(2) and imap4(2) interoperate with mainstream server software - not
# with a stub. It runs natively on the host arch (no emu inside), so no
# emulation is needed.
#
#   docker build -t inferno-interop-host tests/docker
#   (driven by tests/mailsshinterop.sh, which supplies keys/certs in /shared)
FROM debian:bookworm-slim

# postfix asks debconf questions on install; preseed a no-op config.
RUN echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections \
	&& echo "postfix postfix/mailname string mail.test.local" | debconf-set-selections \
	&& apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		postfix \
		dovecot-imapd \
		openssh-server \
		ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

# the mailbox owner, and the account ssh/imap/smtp all authenticate as
RUN useradd -m -s /bin/sh tester

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 22 465 993
ENTRYPOINT ["/usr/local/bin/start.sh"]
