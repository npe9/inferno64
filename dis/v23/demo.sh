#!/dis/sh
load std
echo 'Vanadium (v23) demo shell'
echo '  /dis/v23/selftest.dis'
echo '  /dis/v23/principal.dis -n alice'
echo '  /dis/v23/fortuned.dis -a tcp!*!3242 &'
echo '  /dis/v23/fortune.dis -a tcp!127.0.0.1!3242'
echo '  man 2 v23-intro'
bind -a '#I' /net >[2]/dev/null
if {ftest -d /net/tcp} {
	echo '/net ready'
} {
	echo 'WARNING: /net/tcp missing; fortune RPC will not work until #I is bound'
}
