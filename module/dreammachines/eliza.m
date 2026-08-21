Eliza: module
{
	PATH: con "/dis/dreammachines/plugin/eliza.dis";

	# One PRE or POST word-substitution entry: word -> a (possibly
	# multi-word) replacement.
	Repl: adt {
		word:	string;
		repl:	list of string;
	};

	# A single DECOMP pattern (tokens: literal words or "*" wildcards)
	# plus the REASSEMBLE templates that go with it, cycled round-robin
	# via next so the same input doesn't always get the same reply.
	Rule: adt {
		pattern:	list of string;
		reassemblies:	list of string;
		next:		int;
	};

	# One KEY: a single trigger word, its rank (higher wins when more
	# than one keyword's trigger word appears in the input), and the
	# DECOMP/REASSEMBLE rules tried in order for it.
	Keyword: adt {
		word:	string;
		rank:	int;
		rules:	list of ref Rule;
	};

	Script: adt {
		greeting:	string;
		defaults:	list of string;
		defnext:	int;
		pre:		list of ref Repl;
		post:		list of ref Repl;
		keys:		list of ref Keyword;
	};

	init:		fn();
	loadscript:	fn(path: string): (ref Script, string);
	respond:	fn(script: ref Script, input: string): string;
};
