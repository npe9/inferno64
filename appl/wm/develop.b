implement Develop;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Rect: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "dialog.m";
	dialog: Dialog;
include "string.m";
	str: String;
include "sh.m";
	sh: Sh;
include "debug.m";
	debug: Debug;
	Prog, Exp, Module, Sym: import debug;
include "dis.m";
	dism: Dis;

Develop: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Errico: con "error -fg red";

ctxt: ref Draw->Context;
top: ref Tk->Toplevel;
ctl: chan of string;
locc: chan of (string, int, string, array of string);

source, current, program: string;
argv: list of string;
files: array of string;
targetpid: int;
followlive: int;
snapshot: string;
lookword: string;
lookmodule: string;
dirty := 0;
savedtext, lasttext: string;
undos: list of string;
Nundo: con 100;

cfg := array[] of {
	"frame .bar -relief raised",
	"menubutton .bar.files -text Modules -menu .bar.files.m",
	"menu .bar.files.m",
	"button .bar.save -text Save -command {send cmd save}",
	"button .bar.undo -text Undo -command {send cmd undo} -state disabled",
	"button .bar.build -text Build -command {send cmd build}",
	"button .bar.run -text Run -command {send cmd run}",
	"button .bar.go -text Go -command {send cmd go}",
	"button .bar.state -text State -command {send cmd state}",
	"label .bar.args -anchor w",
	"pack .bar.files .bar.save .bar.undo .bar.build .bar.run .bar.go .bar.state -side left",
	"pack .bar.args -side left -padx 8 -fill x -expand 1",
	"frame .body",
	"scrollbar .body.s -command {.body.t yview}",
	"text .body.t -bg white -font /fonts/lucidasans/unicode.8.font -yscrollcommand {.body.s set}",
	"bind .body.t <Control-_> {send cmd undo}",
	"bind .body.t <Button-3> {send cmd lookpick %x %y}",
	"bind .body.t <ButtonRelease-3> {send cmd lookgo}",
	"bind .body.t <Motion-Button-3> {}",
	"bind .body.t <Double-Button-3> {}",
	"bind .body.t <Double-ButtonRelease-3> {}",
	"pack .body.s -side left -fill y",
	"pack .body.t -fill both -expand 1",
	"label .status -anchor w -relief sunken -text {Waiting for a program}",
	"pack .bar -fill x",
	"pack .body -fill both -expand 1",
	"pack .status -fill x",
	"pack propagate . 0",
	"focus .body.t",
	"update",
};

cmd(s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "develop: tk error %s on %s\n", e, s);
	return e;
}

setstatus(s: string)
{
	cmd(".status configure -text " + tk->quote(s) + "; update");
}

settitle()
{
	t := "Develop " + current;
	if(dirty)
		t += " *";
	tkclient->settitle(top, t);
}

exists(path: string): int
{
	(ok, d) := sys->stat(path);
	return ok >= 0 && (d.mode & Sys->DMDIR) == 0;
}

dir(path: string): string
{
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/')
			return path[0:i];
	return ".";
}

base(path: string): string
{
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '/')
			return path[i+1:];
	return path;
}

inlist(path: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == path)
			return 1;
	return 0;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return (nil, "not a regular file: " + path);
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n != len a)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (string a, nil);
}

writefile(path, text: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	a := array of byte text;
	if(sys->write(fd, a, len a) != len a)
		return sys->sprint("cannot write %s: %r", path);
	return nil;
}

included(line: string): string
{
	q := -1;
	for(i := 0; i < len line; i++)
		if(line[i] == '"'){
			q = i + 1;
			break;
		}
	if(q < 0)
		return nil;
	for(i = q; i < len line; i++)
		if(line[i] == '"')
			return line[q:i];
	return nil;
}

findfiles(path: string): array of string
{
	seen: list of string;
	todo := path :: nil;
	for(; todo != nil;){
		p0 := hd todo;
		todo = tl todo;
		if(inlist(p0, seen) || !exists(p0))
			continue;
		seen = p0 :: seen;
		# Implementation sources discovered for an included module are lookup
		# targets, not new dependency roots.  Recursing through their generic
		# sys/draw/tk includes walks nearly the whole source tree before the
		# editor can display its first file.
		if(p0 != path && len p0 > 2 && p0[len p0-2:] == ".b")
			continue;
		(text, nil) := readfile(p0);
		(nil, lines) := sys->tokenize(text, "\n");
		for(; lines != nil; lines = tl lines){
			name := included(hd lines);
			if(name == nil)
				continue;
			p := name;
			if(name[0] != '/'){
				p = dir(p0) + "/" + name;
				if(!exists(p))
					p = "/module/" + name;
			}
			if(exists(p) && !inlist(p, seen))
				todo = p :: todo;
			b := base(name);
			if(len b <= 2 || b[len b-2:] != ".m")
				continue;
			stem := b[0:len b-2];
			rel := name;
			if(len rel > 8 && rel[0:8] == "/module/")
				rel = rel[8:];
			if(len rel > 2 && rel[len rel-2:] == ".m")
				rel = rel[0:len rel-2];
			candidates := "/appl/"+rel+".b" ::
				"/appl/lib/"+stem+".b" ::
				"/appl/wm/"+stem+".b" ::
				"/appl/cmd/"+stem+".b" ::
				"/appl/cmd/"+stem+"/"+stem+".b" :: nil;
			for(; candidates != nil; candidates = tl candidates)
				if(exists(hd candidates) && !inlist(hd candidates, seen))
					todo = hd candidates :: todo;
		}
	}
	r := array[len seen] of string;
	r[0] = path;
	i := 1;
	for(; seen != nil; seen = tl seen)
		if(hd seen != path)
			r[i++] = hd seen;
	return r;
}

filemenu()
{
	cmd("destroy .bar.files.m; menu .bar.files.m");
	for(i := 0; i < len files; i++)
		cmd(".bar.files.m add command -label " + tk->quote(base(files[i])) +
			" -command {send cmd file " + string i + "}");
}

save(): int
{
	if(!dirty)
		return 1;
	err := writefile(current, cmd(".body.t get 1.0 end"));
	if(err != nil){
		dialog->prompt(ctxt, top.image, Errico, "Save failed", err, 0, "Continue" :: nil);
		return 0;
	}
	dirty = 0;
	savedtext = cmd(".body.t get 1.0 end");
	lasttext = savedtext;
	settitle();
	setstatus("Saved " + current);
	return 1;
}

openfile(path: string): int
{
	if(dirty){
		choice := dialog->prompt(ctxt, top.image, Errico, "Unsaved changes",
			"Save changes to " + current + "?", 0, "Save" :: "Discard" :: "Cancel" :: nil);
		if(choice == 0 && !save())
			return 0;
		if(choice > 1)
			return 0;
	}
	(text, err) := readfile(path);
	if(err != nil){
		dialog->prompt(ctxt, top.image, Errico, "Open failed", err, 0, "Continue" :: nil);
		return 0;
	}
	cmd(".body.t delete 1.0 end; .body.t insert 1.0 " + tk->quote(text) + "; .body.t mark set insert 1.0; focus .body.t; update");
	current = path;
	dirty = 0;
	savedtext = text;
	lasttext = text;
	undos = nil;
	cmd(".bar.undo configure -state disabled");
	settitle();
	setstatus("Editing " + path);
	return 1;
}

gotoline(line: int)
{
	if(line <= 0)
		return;
	addr := string line+".0";
	cmd(".body.t tag remove sel 1.0 end; .body.t tag add sel "+addr+
		" {"+addr+" lineend+1char}; .body.t mark set insert "+addr+
		"; .body.t see insert; focus .body.t; update");
	setstatus("Editing " + current + ":" + string line);
}

isident(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
		c >= '0' && c <= '9' || c == '_';
}

wordat(x, y: int): string
{
	lookmodule = nil;
	index := cmd(".body.t index @"+string x+","+string y);
	ranges := cmd(".body.t tag ranges sel");
	if(ranges != "" && cmd(".body.t compare sel.first <= "+index) == "1" &&
		cmd(".body.t compare "+index+" < sel.last") == "1")
		return cmd(".body.t get sel.first sel.last");
	# Let the text widget do rune- and font-aware word expansion.  Work
	# around its boundary rule by preferring the preceding identifier when
	# @x,y lands immediately after the glyph under the pointer.
	here := cmd(".body.t get "+index);
	if(here == nil || !isident(here[0])){
		prev := cmd(".body.t get {"+index+" -1chars} "+index);
		if(prev == nil || !isident(prev[0]))
			return nil;
		index = cmd(".body.t index {"+index+" -1chars}");
	}
	start := cmd(".body.t index {"+index+" wordstart}");
	stop := cmd(".body.t index {"+start+" wordend}");
	if(start == nil || stop == nil || start == stop)
		return nil;
	# Retain the receiver in module->member so lookup can select the actual
	# loaded implementation instead of an unrelated interface declaration.
	(nil, si) := sys->tokenize(start, ".");
	if(len si >= 2){
		ls := cmd(".body.t get {"+start+" linestart} "+start);
		q := len ls;
		while(q > 0 && (ls[q-1] == ' ' || ls[q-1] == '\t')) q--;
		if(q >= 2 && ls[q-2:q] == "->"){
			q -= 2;
			while(q > 0 && (ls[q-1] == ' ' || ls[q-1] == '\t')) q--;
			p := q;
			while(p > 0 && isident(ls[p-1])) p--;
			if(p < q)
				lookmodule = ls[p:q];
		}
	}
	cmd(".body.t tag remove sel 1.0 end; .body.t tag add sel "+start+" "+stop+
		"; .body.t mark set insert "+start+"; .body.t see insert; update");
	return cmd(".body.t get "+start+" "+stop);
}

identifier(s: string): string
{
	for(i := 0; i < len s && !isident(s[i]); i++)
		;
	j := i;
	while(j < len s && isident(s[j]))
		j++;
	if(i == j)
		return nil;
	return s[i:j];
}

isdefinitionline(s: string, open: int): int
{
	depth := 0;
	for(i := open; i < len s; i++){
		case s[i] {
		'(' => depth++;
		')' =>
			depth--;
			if(depth == 0){
				i++;
				while(i < len s && (s[i] == ' ' || s[i] == '\t'))
					i++;
				return i == len s || s[i] == '{';
			}
		}
	}
	return 0;
}

definitionin(path, name: string, body: int): int
{
	if(path == nil || !exists(path))
		return 0;
	(text, err) := readfile(path);
	if(err != nil)
		return 0;
	# sys->tokenize discards empty fields, so using it here reports a
	# non-empty-line ordinal rather than the physical source line.  Preserve
	# every newline because the resulting address is passed back to Tk.
	ln := 1;
	bol := 0;
	for(eol := 0; eol <= len text; eol++){
		if(eol < len text && text[eol] != '\n')
			continue;
		s := text[bol:eol];
		for(i := 0; i + len name <= len s; i++){
			if(s[i:i+len name] != name ||
				i + len name < len s && isident(s[i+len name]))
				continue;
			j := i + len name;
			while(j < len s && (s[j] == ' ' || s[j] == '\t'))
				j++;
			# Built-in module member f is implemented as Module_f in C.
			if(body && len path > 2 && path[len path-2:] == ".c" &&
				i > 0 && s[i-1] == '_' && j < len s && s[j] == '(' &&
				isdefinitionline(s, j)){
				first := 0;
				while(first < i-1 && (s[first] == ' ' || s[first] == '\t'))
					first++;
				valid := first < i-1;
				for(q := first; q < i-1; q++)
					if(!isident(s[q])){ valid = 0; break; }
				if(valid)
					return ln;
			}
			if(i > 0 && isident(s[i-1]))
				continue;
			if(!body && j < len s && s[j] == ':')
				return ln;
			first := 0;
			while(first < len s && (s[first] == ' ' || s[first] == '\t'))
				first++;
			if(body && j < len s && s[j] == '(' && isdefinitionline(s, j) &&
				(i == first || i > first && s[i-1] == '.'))
				return ln;
		}
		bol = eol + 1;
		ln++;
	}
	return 0;
}

moduletype(var: string): string
{
	if(var == nil)
		return nil;
	for(fi := -2; fi < len files; fi++){
		path := source;
		if(fi == -1) path = current;
		if(fi >= 0) path = files[fi];
		(text, nil) := readfile(path);
		if(text == nil)
			continue;
		for(i := 0; i + len var < len text; i++){
			if(text[i:i+len var] != var || i > 0 && isident(text[i-1]) ||
				isident(text[i+len var]))
				continue;
			j := i + len var;
			while(j < len text && (text[j] == ' ' || text[j] == '\t')) j++;
			if(j >= len text || text[j++] != ':')
				continue;
			while(j < len text && (text[j] == ' ' || text[j] == '\t')) j++;
			k := j;
			while(k < len text && isident(text[k])) k++;
			if(k > j)
				return text[j:k];
		}
	}
	return nil;
}

definition(name, qualifier: string): (string, int)
{
	name = identifier(name);
	if(name == nil)
		return (nil, 0);
	if((tn := moduletype(qualifier)) != nil && (impl := moduleimpl(tn)) != nil)
		if((tline := definitionin(impl, name, 1)) > 0)
			return (impl, tline);
	# These two never depend on module discovery and cover the common case of
	# looking from a call to a function in the program being edited.
	for(pass := 0; pass < 2; pass++){
		if((ln := definitionin(source, name, pass == 0)) > 0)
			return (source, ln);
		if(current != source && (ln = definitionin(current, name, pass == 0)) > 0)
			return (current, ln);
		# Search every implementation before beginning the declaration pass.
		for(fi := 0; fi < len files; fi++)
			if((ln = definitionin(files[fi], name, pass == 0)) > 0)
				return (files[fi], ln);
	}
	return (nil, 0);
}

plumbword(word: string)
{
	if(word != nil)
		sh->run(ctxt, "plumb" :: "-s" :: "develop" :: "-w" :: dir(current) :: word :: nil);
}

lookpick(x, y: int)
{
	# An explicit user navigation wins over the asynchronous initial
	# live-frame lookup, which can otherwise arrive and move us away again.
	followlive = 0;
	lookword = identifier(wordat(x, y));
	selected := lookword;
	if(lookmodule != nil)
		selected = lookmodule + "->" + lookword;
	setstatus("Selected '" + selected + "' for definition lookup");
}

lookgo()
{
	word := lookword;
	qualifier := lookmodule;
	lookword = nil;
	lookmodule = nil;
	if(word == nil)
		return;
	setstatus("Looking up '" + word + "' in " + string len files + " source files");
	(path, line) := definition(word, qualifier);
	if(path != nil){
		setstatus("Found '" + word + "' at " + path + ":" + string line);
		if(openfile(path))
			gotoline(line);
		return;
	}
	setstatus("No local definition for " + word + "; plumbing selection");
	spawn plumbword(word);
}

showstate()
{
	text := snapshot;
	if(text == nil)
		text = "No running-process snapshot was captured for this session.";
	dialog->prompt(ctxt, top.image, nil, "State at Develop entry", text,
		0, "Continue" :: nil);
}

fileline(s: string): (string, int)
{
	for(i := len s - 1; i > 0; i--){
		if(s[i] != ':')
			continue;
		if(i == len s - 1)
			break;
		for(j := i + 1; j < len s; j++)
			if(s[j] < '0' || s[j] > '9')
				return (s, 0);
		return (s[0:i], int s[i+1:]);
	}
	return (s, 0);
}

trimundo()
{
	n := 0;
	l: list of string;
	for(u := undos; u != nil && n < Nundo; u = tl u){
		l = hd u :: l;
		n++;
	}
	undos = nil;
	for(; l != nil; l = tl l)
		undos = hd l :: undos;
}

keyinput(k: int)
{
	before := cmd(".body.t get 1.0 end");
	tk->keyboard(top, k);
	after := cmd(".body.t get 1.0 end");
	if(after == before)
		return;
	if(lasttext != before)
		lasttext = before;
	undos = before :: undos;
	trimundo();
	lasttext = after;
	dirty = after != savedtext;
	cmd(".bar.undo configure -state normal");
	settitle();
}

undo()
{
	if(undos == nil)
		return;
	text := hd undos;
	undos = tl undos;
	cmd(".body.t delete 1.0 end; .body.t insert 1.0 " + tk->quote(text) + "; update");
	lasttext = text;
	dirty = text != savedtext;
	if(undos == nil)
		cmd(".bar.undo configure -state disabled");
	settitle();
	setstatus("Undo " + current);
}

distarget(path: string): string
{
	if(len path < 8 || path[0:6] != "/appl/" || len path < 2 || path[len path-2:] != ".b")
		return nil;
	rel := path[6:len path-2] + ".dis";
	if(len rel > 4 && rel[0:4] == "cmd/")
		rel = rel[4:];
	return "/dis/" + rel;
}

compile(src, dst: string): string
{
	return sh->run(ctxt, "limbo" :: "-I/module" :: "-gw" :: "-o" :: dst :: src :: nil);
}

build(): int
{
	if(!save())
		return 0;
	setstatus("Building " + source);
	cmd("cursor -bitmap cursor.wait; update");
	err: string;
	# If a module implementation is being edited, rebuild that module too.
	# Declaration files are consumed when the primary source is compiled.
	if(current != source && (dst := distarget(current)) != nil)
		err = compile(current, dst);
	if(err == nil)
		err = compile(source, program);
	cmd("cursor -default; update");
	if(err != nil){
		setstatus("Build failed: " + err);
		dialog->prompt(ctxt, top.image, Errico, "Build failed", err, 0, "Continue" :: nil);
		return 0;
	}
	setstatus("Built " + program);
	return 1;
}

launch()
{
	a := argv;
	if(a == nil)
		a = program :: nil;
	else
		a = program :: tl a;
	sh->run(ctxt, "{$*&}" :: a);
}

replace()
{
	if(targetpid > 0 && debug != nil){
		(p, nil) := debug->prog(targetpid);
		if(p != nil)
			p.kill();
	}
	targetpid = 0;
	launch();
}

infrastructure(path: string): int
{
	return path == "/appl/lib/titlebar.b" || path == "/appl/lib/wmclient.b" ||
		path == "/appl/lib/tkclient.b" || path == "/appl/lib/wmlib.b";
}

shortval(s: string): string
{
	if(len s > 120)
		return s[0:117] + "...";
	return s;
}

sourceofdis(dis: string): string
{
	if(dism == nil || dis == nil)
		return nil;
	s := dism->src(dis);
	if(exists(s))
		return s;
	return nil;
}

moduleimpl(tname: string): string
{
	# A loaded module global's debug type names its interface.  Resolve the
	# interface PATH constant through Dis, retaining only modules actually
	# represented by a non-nil value in this process instance.
	low := "";
	for(i := 0; i < len tname; i++){
		c := tname[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		low[len low] = c;
	}
	native := "/libinterp/" + low + ".c";
	case tname {
	# runt.c registers $Sys; hosted system-call bodies such as Sys_bind
	# live in the emulator's shared port implementation.
	"Sys" => native = "/emu/port/inferno.c";
	"IPints" => native = "/libinterp/ipint.c";
	}
	if(exists(native))
		return native;
	for(i = 0; i < len files; i++){
		if(len files[i] <= 2 || files[i][len files[i]-2:] != ".m")
			continue;
		(text, nil) := readfile(files[i]);
		if(text == nil)
			continue;
		if(tname != nil){
			needle := tname + ": module";
			found := 0;
			for(j := 0; j + len needle <= len text; j++)
				if(text[j:j+len needle] == needle){ found = 1; break; }
			if(!found)
				continue;
		}
		(nil, lines) := sys->tokenize(text, "\n");
		for(; lines != nil; lines = tl lines){
			s := hd lines;
			if((q := included(s)) == nil || len q < 5 || q[0:5] != "/dis/")
				continue;
			if((src := sourceofdis(q)) != nil)
				return src;
		}
	}
	return nil;
}

liveplace(pid: int): (string, int, string, array of string)
{
	if(pid <= 0 || debug == nil)
		return (nil, 0, nil, nil);
	(p, nil) := debug->prog(pid);
	if(p == nil)
		return (nil, 0, nil, nil);
	stopped := p.stop() == nil;
	(stack, nil) := p.stack();
	# Never leave the application stopped while resolving symbols or walking
	# heap-backed values.  Those operations can block on a module/device and
	# previously prevented the target from even processing its close event.
	# The stack and PCs are the entry snapshot; subsequent value reads are
	# best-effort annotations of that captured frame set.
	if(stopped)
		p.unstop();
	stopped = 0;
	where: string;
	where_line := 0;
	snap := "Process " + string pid + " at Develop entry\n";
	loaded: list of string;
	for(i := 0; i < len stack; i++){
		stack[i].m.stdsym();
		stack[i].findsym();
		s: ref Debug->Src;
		if(stack[i].m.sym != nil)
			s = stack[i].m.sym.pctosrc(stack[i].pc);
		srcname := stack[i].srcstr();
		snap += "\n" + stack[i].name + "  " + srcname + "\n";
		if((msrc := sourceofdis(stack[i].m.dis())) != nil && !inlist(msrc, loaded))
			loaded = msrc :: loaded;
		parts := stack[i].expand();
		for(j := 0; j < len parts; j++){
			if(parts[j].name != "args" && parts[j].name != "locals" && parts[j].name != "module")
				continue;
			vals := parts[j].expand();
			for(k := 0; k < len vals && k < 32; k++){
				(v, nil) := vals[k].val();
				snap += "  " + parts[j].name + "." + vals[k].name + " = " + shortval(v) + "\n";
				if(parts[j].name == "module" && vals[k].kind() == Debug->Tmodule && v != "nil"){
					tn := vals[k].typename();
					if((isrc := moduleimpl(tn)) != nil && !inlist(isrc, loaded))
						loaded = isrc :: loaded;
				}
			}
		}
		if(where != nil || s == nil || s.start.file == nil || infrastructure(s.start.file))
			continue;
		path := s.start.file;
		if(!exists(path)){
			p1 := dir(source) + "/" + path;
			if(exists(p1))
				path = p1;
		}
		if(exists(path)){
			where = path;
			where_line = s.start.line;
		}
	}
	mods := array[len loaded] of string;
	for(i = 0; loaded != nil; loaded = tl loaded)
		mods[i++] = hd loaded;
	return (where, where_line, snap, mods);
}

addfile(path: string)
{
	for(i := 0; i < len files; i++)
		if(files[i] == path)
			return;
	n := array[len files + 1] of string;
	n[0:] = files;
	n[len files] = path;
	files = n;
}

findlive(pid: int)
{
	locc <-= liveplace(pid);
}

session(path, p, av: string, pid, line: int)
{
	program = p;
	source = path;
	argv = str->unquoted(av);
	targetpid = pid;
	followlive = targetpid > 0;
	snapshot = nil;
	files = findfiles(source);
	filemenu();
	cmd(".bar.args configure -text " + tk->quote("argv: " + str->quoted(argv)));
	# Never make opening the source depend on a debugger attach.  Symbol and
	# stack lookup can take time when the target is blocked in a device call.
	if(openfile(source))
		gotoline(line);
	if(followlive)
		spawn findlive(targetpid);
}

init(c: ref Draw->Context, args: list of string)
{
	# Plumber starts a destination as "develop file" before the port message
	# is delivered.  Treat that initial file as sufficient to open a session.
	direct := len args >= 2;
	ctxt = c;
	sys = load Sys Sys->PATH;
	if(!direct){
		sys->fprint(sys->fildes(2), "usage: wm/develop source [dis [argv ...]]\n");
		raise "fail:usage";
	}
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	dialog = load Dialog Dialog->PATH;
	str = load String String->PATH;
	sh = load Sh Sh->PATH;
	debug = load Debug Debug->PATH;
	if(debug != nil)
		debug->init();
	dism = load Dis Dis->PATH;
	if(dism != nil)
		dism->init();
	if(c == nil || tkclient == nil || str == nil || sh == nil)
		raise "fail:develop: missing window or string service";
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	dialog->init();
	(top, ctl) = tkclient->toplevel(ctxt, "", "Develop", Tkclient->Appl);
	cmdc := chan of string;
	tk->namechan(top, cmdc, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(cfg[i]);
	# Use nearly all available workspace instead of a fixed geometry.  Leave
	# a small margin so the WM titlebar and surrounding windows remain
	# reachable even when Develop is the main working surface.
	winw := top.screenr.dx() - 24;
	winh := top.screenr.dy() - 48;
	if(winw < 480) winw = top.screenr.dx();
	if(winh < 360) winh = top.screenr.dy();
	cmd(". configure -width "+string winw+" -height "+string winh+"; update");
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	locc = chan of (string, int, string, array of string);
	# A direct form is useful from a shell and for diagnosing plumbing:
	# wm/develop source [dis [argv ...]]
	args = tl args;
	if(args != nil){
		src := hd args;
		line := 0;
		(nlines, lines) := sys->tokenize(src, "\n");
		if(nlines >= 4){
			src = hd lines;
			dis := hd tl lines;
			av := hd tl tl lines;
			if(av == "-")
				av = nil;
			pid := int hd tl tl tl lines;
			(src, line) = fileline(src);
			session(src, dis, av, pid, line);
		}else{
			(src, line) = fileline(src);
			dis := distarget(src);
			a := tl args;
			if(a != nil){
				dis = hd a;
				a = tl a;
			}
			if(a == nil)
				a = dis :: nil;
			session(src, dis, str->quoted(a), 0, line);
		}
	}
	for(;;) alt {
	k := <-top.ctxt.kbd => keyinput(k);
	p := <-top.ctxt.ptr => tk->pointer(top, *p);
	w := <-top.ctxt.ctl or w = <-top.wreq or w = <-ctl =>
		if(w == "exit"){
			if(dirty && !save())
				continue;
			return;
		}
		tkclient->wmctl(top, w);
	s := <-cmdc =>
		(nil, a) := sys->tokenize(s, " ");
		case hd a {
		"undo" => undo();
		"save" => save();
		"build" => build();
		"run" => spawn launch();
		"go" => if(build()) spawn replace();
		"state" => showstate();
		"file" => followlive = 0; n := int hd tl a; if(n >= 0 && n < len files) openfile(files[n]);
		"lookpick" => if(len a >= 3) lookpick(int hd tl a, int hd tl tl a);
		"lookgo" => lookgo();
		}
	(frame, line, state, loaded) := <-locc =>
		snapshot = state;
		for(mi := 0; mi < len loaded; mi++)
			addfile(loaded[mi]);
		filemenu();
		if(followlive && frame != nil){
			followlive = 0;
			addfile(frame);
			filemenu();
			if(!dirty && openfile(frame))
				gotoline(line);
		}
	}
}
