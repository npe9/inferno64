implement Tknotebook;

#
# A notebook - tabs above a page - out of the widgets libtk already has.
#
# This Tk is 8.0-era: no notebook, treeview, combobox, progressbar or
# spinbox, and no themed-widget layer.  The expensive half of that gap
# wants C; the cheap half is compositions like this one, which is a frame
# of tab buttons, a frame per page, and `pack forget` for the pages that
# are not showing.
#
# The tabs are radiobuttons sharing one variable rather than buttons,
# which is not a detail of appearance.  A radiobutton is a control with a
# state, so libtk already announces it to voice(3) on arrival and again
# when it changes - "General radio button selected" - and choosing a tab
# with the keyboard says so out loud without this module knowing that
# speech exists.  Buttons would have been silent.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "tk.m";
	tk: Tk;
include "tknotebook.m";

init()
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
}

new(top: ref Tk->Toplevel, path: string, tabs: array of string): ref Notebook
{
	if(tk == nil || top == nil || len tabs == 0)
		return nil;

	nb := ref Notebook(top, path, tabs, -1);

	tk->cmd(top, "frame " + path);
	tk->cmd(top, "frame " + path + ".tabs");
	tk->cmd(top, "frame " + path + ".body");

	for(i := 0; i < len tabs; i++){
		t := sys->sprint("%s.tabs.t%d", path, i);
		# -value is the index, so the shared variable names the page.
		#
		# tk->quote() and not a leading ' - in this Tk a ' quotes to
		# the END of the line, so "-text 'General -variable ..." makes
		# the label the whole rest of the command. Every tab was named
		# after its own source until the announcement said so out loud.
		tk->cmd(top, sys->sprint(
			"radiobutton %s -text %s -variable %s -value %d" +
			" -command {send %s %d}",
			t, tk->quote(tabs[i]), var(nb), i, chan_(nb), i));
		tk->cmd(top, "pack " + t + " -side left");
		tk->cmd(top, sys->sprint("frame %s.body.p%d", path, i));
	}
	tk->cmd(top, "pack " + path + ".tabs -fill x");
	tk->cmd(top, "pack " + path + ".body -fill both -expand 1");

	nb.select(0);
	return nb;
}

var(nb: ref Notebook): string
{
	return "nbv" + sanitise(nb.path);
}

chan_(nb: ref Notebook): string
{
	return "nbc" + sanitise(nb.path);
}

# a widget path is not a variable name
sanitise(s: string): string
{
	o := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '.')
			o[len o] = '_';
		else
			o[len o] = s[i];
	return o;
}

Notebook.page(nb: self ref Notebook, i: int): string
{
	if(i < 0 || i >= len nb.tabs)
		return "";
	return sys->sprint("%s.body.p%d", nb.path, i);
}

Notebook.select(nb: self ref Notebook, i: int)
{
	if(i < 0 || i >= len nb.tabs || nb.top == nil)
		return;
	if(nb.sel == i)
		return;
	if(nb.sel >= 0)
		tk->cmd(nb.top, "pack forget " + nb.page(nb.sel));
	tk->cmd(nb.top, "pack " + nb.page(i) + " -fill both -expand 1");
	# keep the tabs in step whether the change came from a click or not
	tk->cmd(nb.top, sys->sprint("%s.tabs.t%d select", nb.path, i));
	nb.sel = i;
	tk->cmd(nb.top, "update");
}

Notebook.chosen(nb: self ref Notebook): int
{
	return nb.sel;
}
