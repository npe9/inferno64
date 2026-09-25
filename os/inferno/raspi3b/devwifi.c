#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * #H: the Wi-Fi radio's firmware channel.
 *
 * The BCM43430 on a Pi 3B needs 399344 bytes of firmware and a small
 * nvram file uploaded into its own RAM before it will do anything, and
 * the kernel cannot read either of them.  The SDIO bring-up runs early
 * in main(), long before any filesystem exists; the root filesystem is
 * compiled into the kernel image by a tool (/os/port/mkroot) that is not
 * in this tree, so it cannot be added there; and embedding 400KB in
 * every kernel to reach a file that is already sitting on the boot
 * partition would be the wrong trade.
 *
 * So the kernel does not read the firmware.  It exposes a place to put
 * it, and the boot script pushes it in at a point where /n/dos has been
 * mounted for some time:
 *
 *	echo bringup >/dev/wifictl
 *	echo fw >/dev/wifictl
 *	cp /n/dos/brcmfmac43430-sdio.bin /dev/wifidata
 *	echo end >/dev/wifictl
 *	echo nvram >/dev/wifictl
 *	cp /n/dos/brcmfmac43430-sdio.txt /dev/wifidata
 *	echo end >/dev/wifictl
 *	echo go >/dev/wifictl
 *
 * That keeps the bulk transfer in the kernel, where the backplane window
 * and the SDIO command layer live, and the file handling in Limbo, where
 * it belongs.  It also means the firmware can be replaced without
 * rebuilding a kernel.
 */

extern int	sdiobringup(void);
extern int	sdiofwbegin(int);
extern int	sdiofwdata(uchar*, int);
extern int	sdiofwend(void);
extern int	sdiofwgo(void);
extern char*	sdiostate(void);

enum {
	Qdir,
	Qctl,
	Qdata,
};

static Dirtab wifidir[] =
{
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"wifictl",	{Qctl, 0},		0,	0664,
	"wifidata",	{Qdata, 0},		0,	0222,
};

static Chan*
wifiattach(char *spec)
{
	return devattach(L'H', spec);
}

static Walkqid*
wifiwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, wifidir, nelem(wifidir), devgen);
}

static int
wifistat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, wifidir, nelem(wifidir), devgen);
}

static Chan*
wifiopen(Chan *c, uint omode)
{
	return devopen(c, omode, wifidir, nelem(wifidir), devgen);
}

static void
wificlose(Chan *c)
{
	USED(c);
}

static int
wifiread(Chan *c, void *a, int n, vlong offset)
{
	char *p;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, wifidir, nelem(wifidir), devgen);
	case Qctl:
		p = sdiostate();
		return readstr((ulong)offset, a, n, p);
	}
	error(Eperm);
	return 0;
}

static int
wifiwrite(Chan *c, void *a, int n, vlong offset)
{
	char cmd[32];

	USED(offset);
	switch((ulong)c->qid.path){
	case Qctl:
		if(n >= sizeof cmd)
			n = sizeof cmd - 1;
		memmove(cmd, a, n);
		cmd[n] = '\0';
		while(n > 0 && (cmd[n-1] == '\n' || cmd[n-1] == ' '))
			cmd[--n] = '\0';
		if(strcmp(cmd, "bringup") == 0){
			if(sdiobringup() < 0)
				error("sdio bring-up failed");
		}else if(strcmp(cmd, "fw") == 0){
			if(sdiofwbegin(0) < 0)
				error("cannot start a firmware upload");
		}else if(strcmp(cmd, "nvram") == 0){
			if(sdiofwbegin(1) < 0)
				error("cannot start an nvram upload");
		}else if(strcmp(cmd, "end") == 0){
			if(sdiofwend() < 0)
				error("upload did not complete");
		}else if(strcmp(cmd, "go") == 0){
			if(sdiofwgo() < 0)
				error("cannot start the radio's ARM");
		}else
			error(Ebadctl);
		return n;
	case Qdata:
		/*
		 * The data arrives in whatever sized pieces the writer
		 * chose, and each one goes straight into the chip at the
		 * running offset.  A short write here is a real error: a
		 * firmware image with a hole in it would start and then
		 * misbehave in ways that look like anything but a bad
		 * upload.
		 */
		if(sdiofwdata(a, n) != n)
			error("firmware write failed");
		return n;
	}
	error(Eperm);
	return 0;
}

Dev wifidevtab = {
	L'H',
	"wifi",

	devreset,
	devinit,
	devshutdown,
	wifiattach,
	wifiwalk,
	wifistat,
	wifiopen,
	devcreate,
	wificlose,
	wifiread,
	devbread,
	wifiwrite,
	devbwrite,
	devremove,
	devwstat
};
