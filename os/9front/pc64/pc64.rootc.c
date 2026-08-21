
#include "u.h"
#include <lib.h>
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include <error.h>

extern uchar bootcode[];
extern ulong bootlen;
extern uchar _________9front_amd64_bin_paqfscode[];
extern ulong _________9front_amd64_bin_paqfslen;
extern uchar _________9front_amd64_bin_auth_factotumcode[];
extern ulong _________9front_amd64_bin_auth_factotumlen;
extern uchar _CONF_bootfs_paqcode[];
extern ulong _CONF_bootfs_paqlen;

void bootlinks(void){

	addbootfile("boot", bootcode, bootlen);
	addbootfile("paqfs", _________9front_amd64_bin_paqfscode, _________9front_amd64_bin_paqfslen);
	addbootfile("factotum", _________9front_amd64_bin_auth_factotumcode, _________9front_amd64_bin_auth_factotumlen);
	addbootfile("bootfs.paq", _CONF_bootfs_paqcode, _CONF_bootfs_paqlen);

}

