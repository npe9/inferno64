/*
 * pi-p, the session protocol.
 *
 * What stays the same as 9P: authentication is someone else's, fids name
 * what a conversation is working on, and every T message is answered by
 * an R message with its tag.
 *
 * What changes.  A session outlives the connection that carried it: it
 * is named by a number, and a client that loses its connection opens
 * another and says which session it is resuming, with its fids still in
 * place.  Transactions are grouped -- several messages in one write,
 * their replies in one read -- so that opening a thing, reading it and
 * closing it is one round trip rather than three.  And what is read from
 * a thing is named: an attribute, by string, rather than an offset into
 * bytes, with * naming the list of attributes it has.
 *
 * Sizes are little endian.  A string is a two-byte length and that many
 * bytes, not terminated.
 *
 *	message	size[4] type[1] tag[2] ...
 *
 *	Tsession	sid[8]			resume, or 0 for a new one
 *	Rsession	sid[8]
 *	Topen		fid[4] nfid[4] how[1] name[s]
 *	Ropen		qid[8] version[8] lease[8]
 *	Tread		fid[4] count[4] attr[s]
 *	Rread		version[8] data[s]
 *	Twrite		fid[4] attr[s] data[s]
 *	Rwrite		version[8]
 *	Tclose		fid[4]
 *	Rclose		version[8]
 *	Tlease		fid[4]
 *	Rlease		lease[8]
 *	Rerror		ename[s]
 *
 * The names in this header carry a Pip prefix, since 9P has the same
 * ones and the kernel already knows those.
 *
 * Topen walks the name from the root, clones the fid into nfid and opens
 * it, which is the walk, the clone and the open of 9P in one message.
 *
 * A write does not change what it names.  It changes the version the fid
 * is making, which nobody else can see, and that version is committed
 * when the fid is closed -- as a whole, or not at all if what it was made
 * from has been committed over in the meantime.  A version once made is
 * not altered again.
 *
 * A fid and a session are leased: each is good for a time, said in
 * milliseconds when it is opened and again whenever it is renewed, and
 * what is not renewed goes away.  A client that comes back to a session
 * it has let lapse is told there is no such session, and must open
 * another.
 */
#ifndef OSPREY_PIP_H
#define OSPREY_PIP_H

enum {
	PipTsession	= 100,
	PipRsession,
	PipTopen,
	PipRopen,
	PipTread,
	PipRread,
	PipTwrite,
	PipRwrite,
	PipTclose,
	PipRclose,
	PipTlease,
	PipRlease,
	PipRerror,

	Pipheader	= 7,		/* size, type, tag */
	Pipmaxmsg	= 8192,
	Pipmaxname	= 64,
	Pipmaxgroup	= 16,		/* messages in one group */

	Pipfidlease	= 30*1000,	/* how long a fid is good for */
	Pipsesslease	= 300*1000,	/* and a session */
};

#endif
