module Emberls

// emberls: a language server for Ember, speaking the Language Server
// Protocol over standard input and output.
//
//	emberls [-I dir] [file ...]
//
// with files, the messages are read from them rather than from
// standard input, which is how the tests drive it: the emulator's
// console is a keyboard, not a pipe (see doc/ember-next-plan.md).
//
// it answers the four questions that need a compiler -- where a name
// is declared, what its type is, where else it is used, and what a
// file declares -- from "emberc -X", the cross-reference dump, and
// reports the compiler's own diagnostics as it goes.  every request
// analyses the file afresh: parse, check and dump, with new instances
// of the compiler's modules, since they keep a compilation's state in
// their globals (appl/ember/emberepl.e found that out).

import sys "sys"
import draw "draw"
import bufio "bufio"
import json "json"
import types "types"
import parse "parse"
import check "check"
import xref "xref"

const Tmpsrc = "/tmp/emberls.e"
const Tmpout = "/tmp/emberls.x"
const Tmperr = "/tmp/emberls.err"

// one line of the cross-reference dump
type Ent struct {
	isdecl int
	line int		// 1-based, as the dump has it
	col int
	name string
	what string		// a declaration's kind: type, func, method, local...
	dmod string		// the module a declaration came from, "" for this file
	dline int
	dcol int
	ty string
}

type Diag struct {
	line int
	msg string
}

// a file the client has open
type Doc struct {
	uri string
	path string
	text string
	ents []ref Ent
	diags []ref Diag
}

var docs = map[string]ref Doc{}
var incdirs list string
var lib Json
var stop = 0

func fail(msg string) {
	sys.fprint(sys.fildes(2), "emberls: %s\n", msg)
}

// json values, built by hand: the library only reads and writes them
func jstr(s string) ref json.Value {
	return ref json.Value.Str{s: s}
}

func jnum(n int) ref json.Value {
	return ref json.Value.Num{v: real(n)}
}

func jbool(b int) ref json.Value {
	return ref json.Value.Bool{b: b != 0}
}

func jarr(a []ref json.Value) ref json.Value {
	return ref json.Value.Arr{a: a}
}

func jobj(keys []string, vals []ref json.Value) ref json.Value {
	return ref json.Value.Obj{keys: keys, vals: vals}
}

func jnull() ref json.Value {
	return ref json.Value.Null{}
}

func jint(v ref json.Value) int {
	match v {
	case json.Value.Num(n):
		return int(n)
	}
	return -1
}

func jtext(v ref json.Value) string {
	match v {
	case json.Value.Str(s):
		return s
	}
	return ""
}

// a position, a range covering a name, and a location in a file
func position(line int, col int) ref json.Value {
	return jobj([]string{"line", "character"}, []ref json.Value{jnum(line), jnum(col)})
}

func namerange(line int, col int, name string) ref json.Value {
	return jobj([]string{"start", "end"}, []ref json.Value{position(line - 1, col - 1), position(line - 1, col - 1 + len(name))})
}

func location(uri string, line int, col int, name string) ref json.Value {
	return jobj([]string{"uri", "range"}, []ref json.Value{jstr(uri), namerange(line, col, name)})
}

func write(path string, text string) int {
	fd := sys.create(path, sys.OWRITE, 0666)
	if fd == nil {
		return 0
	}
	a := []byte(text)
	if sys.write(fd, a, len(a)) != len(a) {
		return 0
	}
	return 1
}

func readfile(path string) string {
	bio := bufio.open(path, bufio.OREAD)
	if bio == nil {
		return ""
	}
	b := ref Builder{}
	for {
		s := bio.gets('\n')
		if s == "" {
			break
		}
		b.puts(s)
	}
	bio.close()
	return b.string()
}

// the fields of a dump line, split on single spaces, with the last
// field holding whatever is left (a type has spaces in it)
func fields(s string, n int) []string {
	a := []string{}
	i := 0
	for len(a) < n - 1 {
		j := i
		for j < len(s) && s[j] != ' ' {
			j++
		}
		if j >= len(s) {
			break
		}
		a = append(a, s[i:j])
		i = j + 1
	}
	if i <= len(s) {
		a = append(a, s[i:len(s)])
	}
	return a
}

// "12:3" or "Sys:119:1"
func parsepos(s string, e ref Ent, isdecl int) {
	a := []string{}
	i := 0
	for j := 0; j <= len(s); j++ {
		if j == len(s) || s[j] == ':' {
			a = append(a, s[i:j])
			i = j + 1
		}
	}
	mod := ""
	if len(a) == 3 {
		mod = a[0]
		a = a[1:3]
	}
	if len(a) != 2 {
		return
	}
	if isdecl != 0 {
		e.dmod = mod
		e.dline = int(a[0])
		e.dcol = int(a[1])
	} else {
		e.line = int(a[0])
		e.col = int(a[1])
	}
}

func parsedump(text string) []ref Ent {
	ents := []ref Ent{}
	bio := bufio.sopen(text)
	for {
		s := bio.gets('\n')
		if s == "" {
			break
		}
		if s[len(s) - 1] == '\n' {
			s = s[0:len(s) - 1]
		}
		if len(s) > 5 && s[0:5] == "decl " {
			f := fields(s[5:len(s)], 4)
			if len(f) != 4 {
				continue
			}
			e := ref Ent{isdecl: 1, name: f[1], what: f[2], ty: f[3]}
			parsepos(f[0], e, 0)
			parsepos(f[0], e, 1)
			ents = append(ents, e)
		} else if len(s) > 4 && s[0:4] == "use " {
			f := fields(s[4:len(s)], 4)
			if len(f) != 4 {
				continue
			}
			e := ref Ent{isdecl: 0, name: f[1], ty: f[3]}
			parsepos(f[0], e, 0)
			if f[2] != "-" {
				parsepos(f[2], e, 1)
			}
			ents = append(ents, e)
		}
	}
	return ents
}

// the compiler's diagnostics: "path:line: message"
func parsediags(text string, path string) []ref Diag {
	ds := []ref Diag{}
	bio := bufio.sopen(text)
	for {
		s := bio.gets('\n')
		if s == "" {
			break
		}
		if s[len(s) - 1] == '\n' {
			s = s[0:len(s) - 1]
		}
		if len(s) <= len(path) + 1 || s[0:len(path)] != path || s[len(path)] != ':' {
			continue
		}
		r := s[len(path) + 1:len(s)]
		i := 0
		for i < len(r) && r[i] != ':' {
			i++
		}
		if i >= len(r) {
			continue
		}
		ds = append(ds, ref Diag{line: int(r[0:i]), msg: r[i + 2:len(r)]})
	}
	return ds
}

// parse, check and dump the document, with the compiler's errors
// caught in a file of their own
func analyse(d ref Doc) {
	old := d.ents
	d.ents = []ref Ent{}
	d.diags = []ref Diag{}
	src := d.path
	if d.text != "" {
		if write(Tmpsrc, d.text) == 0 {
			fail("cannot write " + Tmpsrc)
			return
		}
		src = Tmpsrc
	}
	xfd := sys.create(Tmpout, sys.OWRITE, 0666)
	efd := sys.create(Tmperr, sys.OWRITE, 0666)
	if xfd == nil || efd == nil {
		fail("cannot write the analysis files")
		return
	}
	ty := load Types types.PATH;
	ps := load Parse parse.PATH;
	ck := load Check check.PATH;
	xr := load Xref xref.PATH;
	if ty == nil || ps == nil || ck == nil || xr == nil {
		fail("cannot load the compiler")
		return
	}
	ck.usetypes(ty)
	xr.usetypes(ty)
	xr.usecheck(ck)
	xr.setout(xfd)
	for l := incdirs; l != nil; l = tl(l) {
		ck.addincpath(hd(l))
	}
	e2 := sys.fildes(2)
	sys.dup(efd.fd, 2)
	try {
		tree := ps.parse(src)
		if tree != nil && ps.errors() == 0 && ck.check(tree, src) == 0 {
			xr.xref(tree, ck.moduledecl(), ck.fnlist(), ck.nfnlist())
		}
	} catch e {
		sys.dup(e2.fd, 2)
		fail("the compiler raised " + e + " on " + d.uri)
	}
	sys.dup(e2.fd, 2)
	d.ents = parsedump(readfile(Tmpout))
	d.diags = parsediags(readfile(Tmperr), src)
	// a file that no longer compiles still has the names it had:
	// an editor's outline should not empty out on a typo
	if len(d.ents) == 0 && len(d.diags) != 0 {
		d.ents = old
	}
}

// the entry at a position (0-based, as the protocol has it): a use
// covering it, else a declaration covering it
func entat(d ref Doc, line int, col int) ref Ent {
	var decl ref Ent
	for _, e := range d.ents {
		if e.line != line + 1 {
			continue
		}
		if col + 1 < e.col || col + 1 >= e.col + len(e.name) {
			continue
		}
		if e.isdecl == 0 {
			return e
		}
		decl = e
	}
	return decl
}

func uri(d ref Doc) string {
	return d.uri
}

func pathof(u string) string {
	if len(u) > 7 && u[0:7] == "file://" {
		return u[7:len(u)]
	}
	return u
}

func getdoc(v ref json.Value) ref Doc {
	td := lib.get(v, "textDocument")
	if td == nil {
		return nil
	}
	u := jtext(lib.get(td, "uri"))
	if u == "" {
		return nil
	}
	d := docs[u]
	if d == nil {
		d = ref Doc{uri: u, path: pathof(u), text: "", ents: nil, diags: nil}
		docs[u] = d
		analyse(d)
	}
	return d
}

func getpos(v ref json.Value) (int, int) {
	p := lib.get(v, "position")
	if p == nil {
		return -1, -1
	}
	return jint(lib.get(p, "line")), jint(lib.get(p, "character"))
}

func send(v ref json.Value) {
	body := lib.text(v)
	a := []byte(body)
	sys.print("Content-Length: %d\r\n\r\n%s", len(a), body)
}

func reply(id ref json.Value, result ref json.Value) {
	if id == nil {
		return
	}
	send(jobj([]string{"jsonrpc", "id", "result"}, []ref json.Value{jstr("2.0"), id, result}))
}

func notify(method string, params ref json.Value) {
	send(jobj([]string{"jsonrpc", "method", "params"}, []ref json.Value{jstr("2.0"), jstr(method), params}))
}

// the diagnostics of the document as it now stands
func publish(d ref Doc) {
	a := []ref json.Value{}
	for _, g := range d.diags {
		r := jobj([]string{"start", "end"}, []ref json.Value{position(g.line - 1, 0), position(g.line - 1, 0)})
		a = append(a, jobj([]string{"range", "severity", "source", "message"}, []ref json.Value{r, jnum(1), jstr("ember"), jstr(g.msg)}))
	}
	notify("textDocument/publishDiagnostics", jobj([]string{"uri", "diagnostics"}, []ref json.Value{jstr(d.uri), jarr(a)}))
}

func capabilities() ref json.Value {
	caps := jobj([]string{"textDocumentSync", "definitionProvider", "hoverProvider", "referencesProvider", "documentSymbolProvider"},
		[]ref json.Value{jnum(1), jbool(1), jbool(1), jbool(1), jbool(1)})
	info := jobj([]string{"name", "version"}, []ref json.Value{jstr("emberls"), jstr("1")})
	return jobj([]string{"capabilities", "serverInfo"}, []ref json.Value{caps, info})
}

// the LSP symbol kinds this dump can name
func symkind(what string) int {
	if what == "type" {
		return 5		// Class
	}
	if what == "method" {
		return 6		// Method
	}
	if what == "func" {
		return 12		// Function
	}
	if what == "const" {
		return 14		// Constant
	}
	if what == "field" || what == "tag" {
		return 8		// Field
	}
	if what == "import" {
		return 2		// Module
	}
	return 13			// Variable
}

func definition(d ref Doc, line int, col int) ref json.Value {
	e := entat(d, line, col)
	if e == nil || e.dline <= 0 || e.dmod != "" {
		return jnull()
	}
	return location(d.uri, e.dline, e.dcol, e.name)
}

func hover(d ref Doc, line int, col int) ref json.Value {
	e := entat(d, line, col)
	if e == nil {
		return jnull()
	}
	s := e.name + ": " + e.ty
	if e.isdecl != 0 {
		s = e.what + " " + s
	} else if e.dmod != "" {
		s = s + " (from " + e.dmod + ")"
	}
	c := jobj([]string{"kind", "value"}, []ref json.Value{jstr("plaintext"), jstr(s)})
	return jobj([]string{"contents", "range"}, []ref json.Value{c, namerange(e.line, e.col, e.name)})
}

func references(d ref Doc, line int, col int) ref json.Value {
	e := entat(d, line, col)
	if e == nil {
		return jarr([]ref json.Value{})
	}
	dl := e.dline
	dc := e.dcol
	dm := e.dmod
	a := []ref json.Value{}
	for _, u := range d.ents {
		if u.isdecl == 0 && u.dline == dl && u.dcol == dc && u.dmod == dm && u.name == e.name {
			a = append(a, location(d.uri, u.line, u.col, u.name))
		}
	}
	return jarr(a)
}

func symbols(d ref Doc) ref json.Value {
	a := []ref json.Value{}
	for _, e := range d.ents {
		if e.isdecl == 0 || e.dmod != "" {
			continue
		}
		l := location(d.uri, e.line, e.col, e.name)
		a = append(a, jobj([]string{"name", "kind", "location"}, []ref json.Value{jstr(e.name), jnum(symkind(e.what)), l}))
	}
	return jarr(a)
}

func request(method string, id ref json.Value, params ref json.Value) {
	if method == "initialize" {
		reply(id, capabilities())
		return
	}
	if method == "shutdown" {
		reply(id, jnull())
		return
	}
	if method == "exit" {
		stop = 1
		return
	}
	if method == "textDocument/didOpen" {
		td := lib.get(params, "textDocument")
		u := jtext(lib.get(td, "uri"))
		d := ref Doc{uri: u, path: pathof(u), text: jtext(lib.get(td, "text")), ents: nil, diags: nil}
		docs[u] = d
		analyse(d)
		publish(d)
		return
	}
	if method == "textDocument/didChange" {
		d := getdoc(params)
		if d == nil {
			return
		}
		ch := lib.get(params, "contentChanges")
		c := lib.at(ch, 0)
		if c != nil {
			d.text = jtext(lib.get(c, "text"))
		}
		analyse(d)
		publish(d)
		return
	}
	if method == "textDocument/didSave" {
		d := getdoc(params)
		if d == nil {
			return
		}
		analyse(d)
		publish(d)
		return
	}
	if method == "textDocument/didClose" {
		td := lib.get(params, "textDocument")
		u := jtext(lib.get(td, "uri"))
		delete(docs, u)
		return
	}
	d := getdoc(params)
	if d == nil {
		reply(id, jnull())
		return
	}
	if method == "textDocument/documentSymbol" {
		reply(id, symbols(d))
		return
	}
	line, col := getpos(params)
	if method == "textDocument/definition" {
		reply(id, definition(d, line, col))
		return
	}
	if method == "textDocument/hover" {
		reply(id, hover(d, line, col))
		return
	}
	if method == "textDocument/references" {
		reply(id, references(d, line, col))
		return
	}
	if id != nil {
		send(jobj([]string{"jsonrpc", "id", "error"}, []ref json.Value{jstr("2.0"), id,
			jobj([]string{"code", "message"}, []ref json.Value{jnum(-32601), jstr("no such method: " + method)})}))
	}
}

// one message: the headers, then Content-Length bytes of JSON
func message(bio ref bufio.Iobuf) string {
	n := -1
	for {
		s := bio.gets('\n')
		if s == "" {
			return ""
		}
		for len(s) > 0 && (s[len(s) - 1] == '\n' || s[len(s) - 1] == '\r') {
			s = s[0:len(s) - 1]
		}
		if s == "" {
			break
		}
		if len(s) > 16 && s[0:16] == "Content-Length: " {
			n = int(s[16:len(s)])
		}
	}
	if n <= 0 {
		return ""
	}
	a := [n]byte
	got := 0
	for got < n {
		m := bio.read(a[got:n], n - got)
		if m <= 0 {
			return ""
		}
		got += m
	}
	return string(a)
}

func serve(bio ref bufio.Iobuf) {
	for stop == 0 {
		body := message(bio)
		if body == "" {
			return
		}
		match r := lib.parse(body) {
		case Result[ref json.Value].Err(e):
			fail("bad message: " + e)
		case Result[ref json.Value].Ok(v):
			method := jtext(lib.get(v, "method"))
			if method == "" {
				continue
			}
			request(method, lib.get(v, "id"), lib.get(v, "params"))
		}
	}
}

func init(ctxt ref draw.Context, args list string) {
	var files list string
	l := args
	if l != nil {
		l = tl(l)
	}
	for ; l != nil; l = tl(l) {
		if hd(l) == "-I" && tl(l) != nil {
			l = tl(l)
			incdirs = hd(l) :: incdirs
			continue
		}
		files = hd(l) :: files
	}
	incdirs = "/ember/module" :: incdirs
	lib = load Json json.PATH
	if lib == nil {
		fail("cannot load the JSON library")
		return
	}
	if files == nil {
		serve(bufio.fopen(sys.fildes(0), bufio.OREAD))
		return
	}
	var r list string
	for ; files != nil; files = tl(files) {
		r = hd(files) :: r
	}
	for ; r != nil && stop == 0; r = tl(r) {
		bio := bufio.open(hd(r), bufio.OREAD)
		if bio == nil {
			fail("cannot open " + hd(r))
			continue
		}
		serve(bio)
		bio.close()
	}
}
