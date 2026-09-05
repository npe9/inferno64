extern void startboot(char*, char**);

/*
 * The kernel enters here with the argv array pointer in the first
 * argument register: a nil-terminated array of argument strings, argv[0]
 * the program name.  startboot takes the name and the whole vector.
 */
void
_main(char **argv)
{
	startboot(argv[0], argv);
}
