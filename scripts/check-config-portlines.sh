#!/bin/sh
# mkdevc copies a kernel configuration's "port" section verbatim into the
# generated .c, but it strips each line's leading whitespace before its own
# section detector runs, so a port line whose first token contains one of the
# section names - dev, ip, link, misc, port - is misread as a new section and
# silently truncates the file.  mkdevc is fixed (a "next" in its port rule),
# but this guard keeps the invariant enforced for every configuration, so a
# regression in the tool or a stray line fails the build loudly here instead
# of producing a kernel that is quietly missing half its port section.
status=0
for conf in os/osprey/pc64/pc64 os/osprey/pc64/upc64; do
	[ -f "$conf" ] || continue
	bad=$(awk '
		f && /^bootdir/ { f=0 }
		/^port$/ { f=1; next }
		f {
			s=$0; sub(/^[ \t]*/,"",s)
			if(s=="") next
			n=split(s,a," ")
			if(a[1] ~ /(bootdir|dev|ip|link|misc|port)/)
				print NR": "a[1]
		}
	' "$conf")
	if [ -n "$bad" ]; then
		echo "FAIL $conf: port line(s) whose first token collides with a mkdevc section name:"
		echo "$bad"
		status=1
	fi
done
[ $status -eq 0 ] && echo "ok   no port-section line collides with a mkdevc section name"
exit $status
