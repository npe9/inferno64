#!/boot/rc -m /boot/rcmain
/boot/echo Morning
# boot script for file servers, including standalone ones
path=(/boot /$cputype/bin /rc/bin .)
bind '#c' /dev
bind -a '#p' /proc
bind -c '#s' /srv
bind -a '#i' /dev
bind -a '#m' /dev
bind -a '#v' /dev
bind /boot /bin
ramfs -m /mnt
mkdir /mnt/temp
exec /boot/rc -m/boot/rcmain -i
zzz
