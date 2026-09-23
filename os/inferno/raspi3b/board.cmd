load std; echo LOAD-BEGIN; for i in 1 2 3 4 5 6 {dd -if /n/remote/os/inferno/raspi3b/kernel8.img -of /dev/null -bs 8192 -count 32}; echo POOL-END
