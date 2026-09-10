implement Keyhold;

# See module/keyhold.m.  The whole of it is the release encoding.

include "sys.m";
	sys: Sys;

include "keyboard.m";

include "keyhold.m";

mk(binds: array of (int, int)): ref Binding
{
	h := ref Binding;
	n := len binds;
	h.code = array[n] of int;
	h.bit = array[n] of int;
	for(i := 0; i < n; i++)
		(h.code[i], h.bit[i]) = binds[i];
	return h;
}

Binding.key(h: self ref Binding, held, k: int): int
{
	up := 0;
	# NOT `k & Keyup`: Keyup is Spec|0x800, and every arrow and function
	# key already carries Spec, so a bare mask says a plain Left arrow
	# is a release.  The whole of Spec has to match, which is what
	# wm(1)'s own iskeyup() does.
	if((k & (Keyboard->Spec | 16r800)) == Keyboard->Keyup){
		up = 1;
		k &= 16r7ff;
	}
	for(i := 0; i < len h.code; i++){
		want := h.code[i];
		if(up)
			want &= 16r7ff;
		if(k != want)
			continue;
		if(up)
			return held & ~h.bit[i];
		return held | h.bit[i];
	}
	return held;
}

edge(held, prev: int): int
{
	return held & ~prev;
}
