#!/usr/bin/env python3
# A tiny IMAP4rev1 + SMTP-submission server over TLS, used as a hermetic
# oracle for the Inferno upas client (imap4/smtp2). It is NOT a real mail
# server: the IMAP side always offers one canned INBOX message, and the
# SMTP side captures a submitted message to a file. Both run TLS 1.2 from
# the start with a supplied cert/key. Credentials are checked so the
# client's auth negative controls have something to fail against.
#
# args: certfile keyfile imapport smtpport user password capturefile

import base64
import socket
import ssl
import sys
import threading
import time

CANNED = (
    b"From: Alice <alice@test.example>\r\n"
    b"To: Bob <bob@test.example>\r\n"
    b"Subject: Oracle test message\r\n"
    b"Date: Thu, 04 Sep 2026 10:00:00 +0000\r\n"
    b"\r\n"
    b"Hello from the IMAP oracle.\r\n"
)


def tls_context(cert, key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def serve(port, ctx, handler):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(5)
    while True:
        raw, _ = s.accept()
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
        except Exception as e:
            sys.stderr.write("tls accept error: %s\n" % e)
            raw.close()
            continue
        threading.Thread(target=handler, args=(conn,), daemon=True).start()


def parse_quoted(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == " ":
            i += 1
            continue
        if s[i] == '"':
            j, buf = i + 1, ""
            while j < len(s) and s[j] != '"':
                if s[j] == "\\" and j + 1 < len(s):
                    buf += s[j + 1]
                    j += 2
                else:
                    buf += s[j]
                    j += 1
            out.append(buf)
            i = j + 1
        else:
            j = i
            while j < len(s) and s[j] != " ":
                j += 1
            out.append(s[i:j])
            i = j
    return out


def imap_handler(user, passwd):
    def h(conn):
        f = conn.makefile("rwb")
        f.write(b"* OK oracle IMAP ready\r\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                break
            parts = line.decode(errors="replace").rstrip("\r\n").split(" ", 2)
            if len(parts) < 2:
                continue
            tag, cmd = parts[0], parts[1].upper()
            rest = parts[2] if len(parts) > 2 else ""
            if cmd == "CAPABILITY":
                f.write(b"* CAPABILITY IMAP4rev1\r\n")
                f.write(("%s OK done\r\n" % tag).encode())
            elif cmd == "LOGIN":
                toks = parse_quoted(rest)
                if len(toks) == 2 and toks[0] == user and toks[1] == passwd:
                    f.write(("%s OK logged in\r\n" % tag).encode())
                else:
                    f.write(("%s NO [AUTHENTICATIONFAILED] bad creds\r\n" % tag).encode())
            elif cmd in ("SELECT", "EXAMINE"):
                f.write(b"* 1 EXISTS\r\n")
                f.write(("%s OK [READ-WRITE] selected\r\n" % tag).encode())
            elif cmd == "FETCH":
                f.write(("* 1 FETCH (BODY[] {%d}\r\n" % len(CANNED)).encode())
                f.write(CANNED)
                f.write(b")\r\n")
                f.write(("%s OK fetched\r\n" % tag).encode())
            elif cmd == "SEARCH":
                f.write(b"* SEARCH 1\r\n")
                f.write(("%s OK\r\n" % tag).encode())
            elif cmd == "STORE":
                f.write(("%s OK stored\r\n" % tag).encode())
            elif cmd == "LOGOUT":
                f.write(b"* BYE\r\n")
                f.write(("%s OK bye\r\n" % tag).encode())
                f.flush()
                break
            else:
                f.write(("%s OK noop\r\n" % tag).encode())
            f.flush()
        conn.close()
    return h


def smtp_handler(user, passwd, capfile):
    def h(conn):
        f = conn.makefile("rwb")
        f.write(b"220 oracle ESMTP\r\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                break
            s = line.decode(errors="replace").rstrip("\r\n")
            up = s.upper()
            if up.startswith("EHLO") or up.startswith("HELO"):
                f.write(b"250-oracle\r\n250 AUTH PLAIN XOAUTH2\r\n")
            elif up.startswith("AUTH PLAIN"):
                fields = s.split(" ")
                b64 = fields[2] if len(fields) >= 3 else ""
                ok = False
                try:
                    dec = base64.b64decode(b64).split(b"\x00")
                    ok = len(dec) == 3 and dec[1].decode() == user and dec[2].decode() == passwd
                except Exception:
                    ok = False
                f.write(b"235 ok\r\n" if ok else b"535 auth failed\r\n")
            elif up.startswith("AUTH XOAUTH2"):
                f.write(b"235 ok\r\n")
            elif up.startswith("MAIL FROM"):
                f.write(b"250 ok\r\n")
            elif up.startswith("RCPT TO"):
                f.write(b"250 ok\r\n")
            elif up == "DATA":
                f.write(b"354 go\r\n")
                f.flush()
                data = b""
                while True:
                    dl = f.readline()
                    if not dl or dl == b".\r\n":
                        break
                    data += dl
                with open(capfile, "wb") as cf:
                    cf.write(data)
                f.write(b"250 queued\r\n")
            elif up == "QUIT":
                f.write(b"221 bye\r\n")
                f.flush()
                break
            else:
                f.write(b"250 ok\r\n")
            f.flush()
        conn.close()
    return h


def main():
    cert, key, imapport, smtpport, user, passwd, capfile = sys.argv[1:8]
    ctx = tls_context(cert, key)
    threading.Thread(target=serve, args=(int(imapport), ctx, imap_handler(user, passwd)), daemon=True).start()
    threading.Thread(target=serve, args=(int(smtpport), ctx, smtp_handler(user, passwd, capfile)), daemon=True).start()
    sys.stderr.write("oracle up: imap %s smtp %s\n" % (imapport, smtpport))
    sys.stderr.flush()
    while True:
        time.sleep(3600)


main()
