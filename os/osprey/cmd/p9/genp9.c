/*
 * A generator, for the near end of a pipeline: it writes as many bytes
 * as it was told to and stops.
 *
 * It exists to make the pipeline carry more than a pipe holds.  With a
 * small file the writer never waits and "a pipeline ran" would only mean
 * the first program finished before the second started.  Past the pipe's
 * size the writer must block and the reader must run to drain it, so the
 * two stages are genuinely alive at once - two programs, two flows of
 * control, two descriptor tables, one address space - and the count the
 * far end reports says nothing was lost across the handoffs.
 */
#include <u.h>
#include <libc.h>

void
startboot(char *argv0, char **argv)
{
	char buf[4096];
	long want, sent, n, i;

	USED(argv0);
	want = 0;
	if(argv != nil && argv[1] != nil)
		want = atol(argv[1]);
	if(want <= 0)
		want = 200000;
	for(i = 0; i < sizeof buf; i++)
		buf[i] = (i % 64) == 63 ? '\n' : 'a' + (i % 26);
	for(sent = 0; sent < want; sent += n){
		n = want - sent;
		if(n > sizeof buf)
			n = sizeof buf;
		if(write(1, buf, n) != n){
			print("libgen: the write failed after %ld bytes\n", sent);
			exits("write");
		}
	}
	exits(nil);
}
