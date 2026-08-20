Tutor: module
{
	PATH: con "/dis/lib/tutor.dis";

	# Nelson's Dream Machines chapter on CAI (computer-assisted
	# instruction) and PLATO: a lesson is a graph of frames, not a
	# linear document - each frame poses something, judges the
	# student's typed answer against an ordered list of keyword rules
	# (PLATO's actual TUTOR language judged answers this way - simple
	# substring/keyword matching, not real language understanding, and
	# that's authentic to the system being modeled, not a shortcut),
	# and branches to a different next frame depending on which rule
	# matched (or the default, if none did). This is deliberately
	# distinct from this tree's existing static !Lessons reading
	# material - those are documents; a Tutor lesson is a program the
	# student's answers actually steer.

	Rule: adt {
		keyword: string;
		correct: int;		# counts toward the student's score if matched
		next: string;		# frame name to branch to
		response: string;	# feedback shown before branching
	};

	Frame: adt {
		name: string;
		text: string;
		rules: list of ref Rule;
		defcorrect: int;
		defnext: string;
		defresponse: string;
	};

	Lesson: adt {
		title: string;
		start: string;
		frames: list of ref Frame;
	};

	init: fn();
	loadlesson: fn(path: string): (ref Lesson, string);
	findframe: fn(lesson: ref Lesson, name: string): ref Frame;
	# Judges answer against frame's rules, in order; first keyword found
	# as a substring (case-insensitive) wins. Falls back to the frame's
	# default if none match. Returns (correct, next frame name, response).
	judge: fn(frame: ref Frame, answer: string): (int, string, string);
};
