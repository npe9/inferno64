load std; echo S0; cat /net.alt/ether/stats; echo M0; dd -if /n/remote/os/inferno/raspi3b/kernel8.img -of /dev/null -bs 8192 -count 64; echo M1; cat /net.alt/ether/stats; echo STATS-END
