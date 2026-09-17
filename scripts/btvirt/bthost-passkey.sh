#!/bin/sh
#
# Two edits to BlueZ's test host stack so that Secure Connections
# passkey entry can be tested against it at all.
#
# 1. bthost's passkey is always zero.  emulator/smp.c reads
#    passkey_notify for the twenty rounds and for the DHKey check, but
#    nothing sets it and bthost.h exposes no way to.  A fixture whose
#    secret is zero cannot tell a right implementation from one that
#    ignores the secret: every round whose bit is 0 agrees by
#    accident.
#
# 2. sc_dhkey_check always sends r = 0.  Its verifying half has the
#    right conditional -- passkey entry puts the passkey in r -- but
#    the half that builds the check it sends has a bare memset and no
#    conditional at all, so bthost's own DHKey check for a passkey
#    pairing is computed with the wrong r.  That is a fault in bthost
#    rather than a missing feature, and it is the reason a pairing
#    that got all twenty rounds right still failed at the last
#    message.
#
# sed rather than a context patch, and every edit is counted
# afterwards.  A context patch over these lines applied some hunks and
# silently dropped others, which made bthost send its confirms with
# the real passkey and check the other side's against zero -- and that
# looked exactly like a fault in the code under test.
#
set -e

# the value
sed -i '1i #define BTHOST_TEST_PASSKEY 0x0abcde' emulator/smp.c
sed -i 's/conn->passkey_notify >> conn->passkey_round/BTHOST_TEST_PASSKEY >> conn->passkey_round/g' emulator/smp.c
sed -i 's/put_le32(conn->passkey_notify, r)/put_le32(BTHOST_TEST_PASSKEY, r)/g' emulator/smp.c

# the missing conditional, before the f6 that builds the check we send
sed -i 's|^\tbt_crypto_f6(conn->smp->crypto, conn->mackey, conn->prnd, conn->rrnd,$|\tif (conn->method == REQ_PASSKEY \|\| conn->method == DSP_PASSKEY)\n\t\tput_le32(BTHOST_TEST_PASSKEY, r);\n&|' emulator/smp.c

n=`grep -c 'BTHOST_TEST_PASSKEY >> conn->passkey_round' emulator/smp.c`
test "$n" = 2 || { echo "expected 2 round sites, found $n" >&2; exit 1; }
n=`grep -c 'put_le32(BTHOST_TEST_PASSKEY, r)' emulator/smp.c`
test "$n" = 2 || { echo "expected 2 dhkey sites, found $n" >&2; exit 1; }
echo "bthost: passkey set to 0x0abcde, dhkey check r fixed"
