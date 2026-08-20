implement Tutor;

include "sys.m";
	sys: Sys;

include "tutor.m";

init()
{
	sys = load Sys Sys->PATH;
}

# --- plain-text lesson format ---
#
#	LESSON <title>
#	START <framename>
#
#	FRAME <name>
#	TEXT
#	<one or more lines, verbatim>
#	END
#	JUDGE <keyword> <correct 0|1> <next> <response text...>
#	...
#	DEFAULT <correct 0|1> <next> <response text...>
#
# Blank lines between frames are ignored. JUDGE rules are tried in the
# order they appear; the first whose keyword is found (as a case-
# insensitive substring) in the student's answer wins. DEFAULT is what
# happens when no JUDGE rule matches.

loadlesson(path: string): (ref Lesson, string)
{
	(text, err) := readfile(path);
	if(err != nil)
		return (nil, err);
	(nil, lines) := sys->tokenize(text, "\n");
	lesson := ref Lesson("", "", nil);
	curframe: ref Frame;
	intext := 0;
	textbuf := "";
	for(l := lines; l != nil; l = tl l){
		line := hd l;
		if(intext){
			if(line == "END"){
				intext = 0;
				if(curframe != nil)
					curframe.text = textbuf;
				textbuf = "";
			} else {
				if(textbuf != "")
					textbuf += "\n";
				textbuf += line;
			}
			continue;
		}
		if(line == "")
			continue;
		(n, toks) := sys->tokenize(line, " ");
		if(n == 0)
			continue;
		kw := hd toks;
		rest := tl toks;
		case kw {
		"LESSON" =>
			lesson.title = jointoks(rest);
		"START" =>
			if(rest != nil)
				lesson.start = hd rest;
		"FRAME" =>
			if(rest != nil){
				curframe = ref Frame(hd rest, "", nil, 0, "", "");
				lesson.frames = appendframe(lesson.frames, curframe);
			}
		"TEXT" =>
			intext = 1;
			textbuf = "";
		"JUDGE" =>
			if(curframe != nil && rest != nil && tl rest != nil && tl tl rest != nil){
				keyword := hd rest;
				correct := int hd tl rest;
				next := hd tl tl rest;
				response := jointoks(tl tl tl rest);
				curframe.rules = appendrule(curframe.rules, ref Rule(keyword, correct, next, response));
			}
		"DEFAULT" =>
			if(curframe != nil && rest != nil && tl rest != nil){
				curframe.defcorrect = int hd rest;
				curframe.defnext = hd tl rest;
				curframe.defresponse = jointoks(tl tl rest);
			}
		* =>
			;
		}
	}
	if(lesson.start == "")
		return (nil, "no START frame declared");
	return (lesson, nil);
}

findframe(lesson: ref Lesson, name: string): ref Frame
{
	for(f := lesson.frames; f != nil; f = tl f)
		if((hd f).name == name)
			return hd f;
	return nil;
}

judge(frame: ref Frame, answer: string): (int, string, string)
{
	la := lower(answer);
	for(r := frame.rules; r != nil; r = tl r){
		rule := hd r;
		if(contains(la, lower(rule.keyword)))
			return (rule.correct, rule.next, rule.response);
	}
	return (frame.defcorrect, frame.defnext, frame.defresponse);
}

appendframe(l: list of ref Frame, n: ref Frame): list of ref Frame
{
	if(l == nil)
		return n :: nil;
	return hd l :: appendframe(tl l, n);
}

appendrule(l: list of ref Rule, n: ref Rule): list of ref Rule
{
	if(l == nil)
		return n :: nil;
	return hd l :: appendrule(tl l, n);
}

jointoks(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

contains(s, sub: string): int
{
	if(len sub == 0)
		return 1;
	for(i := 0; i+len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

lower(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] = r[i]-'A'+'a';
	return r;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return (nil, "not a regular file: "+path);
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (string a[0:n], nil);
}
