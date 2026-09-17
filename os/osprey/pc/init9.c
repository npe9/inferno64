extern void startboot(char*, char**);

/*
 * The kernel enters here with the argv array pointer in the first
 * argument register: a nil-terminated array of argument strings, argv[0]
 * the program name.  startboot takes the name and the whole vector.
 * One word past the nil is the address of the Tos, which this entry
 * ignores: it is the entry for a program loaded flat into one read-only
 * text segment (ospreyloadprog), which cannot store into libc's data at
 * all.  init9prog.c is the entry for a program that has a data segment
 * of its own, and that one takes the Tos and gives libc its privates.
 */
void
_main(char **argv)
{
	startboot(argv[0], argv);
}
