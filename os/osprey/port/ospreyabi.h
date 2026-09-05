/*
 * The shared span as a container sees it: the map at the head of its
 * slice, and one arm of a select.  This is the only declaration of
 * either.  os/osprey/port/osprey.h includes it for the kernel and
 * os/osprey/libosprey9/osprey9.h includes it for a program, so the two
 * cannot come to disagree about what is in the memory they share.  The
 * three structures a slice also holds -- Message, Queue and Sem -- are
 * declared once each in os/osprey/policy, and both sides include those
 * headers rather than copying them.
 */
#ifndef OSPREY_ABI_H
#define OSPREY_ABI_H

typedef struct Ospreymap Ospreymap;

#include "ospreydata.h"

enum {
	Ospreynarg	= 3,	/* request words available to the caller */
	Ospreymagic	= 0x4f53505259ULL,
};

/*
 * The shared arena.  One physical span is carved into a slice per
 * container and published as the "osprey" physical segment, so a process
 * can segattach it and work its rings directly instead of trapping.  A
 * slice starts with this map; every other field in it is a byte offset
 * from the start of the same slice.  status names each container's slice.
 */
struct Ospreymap {
	uvlong	magic;
	uvlong	id;
	uvlong	size;		/* messages in each ring */
	uvlong	msgsize;	/* bytes in one message */
	uvlong	requestqueue;	/* the ring heads: size, put, get */
	uvlong	replyqueue;
	uvlong	outputqueue;	/* what a driver task takes work from */
	uvlong	request;	/* the message arrays */
	uvlong	reply;
	uvlong	output;
	uvlong	data;		/* names and i/o buffers */
	uvlong	datalen;
	uvlong	sem;		/* the container's semaphores */
	uvlong	nsem;
	uvlong	selected;	/* the arm the last select performed */
	uvlong	pktbuf;		/* receive buffers, when an interface is given */
	uvlong	npktbuf;
	uvlong	pktbufsize;	/* stride of one, its data at its start */
	uvlong	page;		/* offsets of the pages held, in the arena */
	uvlong	npage;		/* how many are held */
	uvlong	maxpage;	/* how many may be */
	uvlong	pagesize;
	uvlong	txbuf;		/* transmit buffers, the other half of the
				 * lending: the container writes a frame in
				 * one of these and the card reads it from
				 * there.  Appended after pagesize so that a
				 * program with a shorter copy of this map
				 * still reads every field it knows. */
	uvlong	ntxbuf;
	uvlong	txbufsize;
	/*
	 * Which transmit buffers the container may write, one bit each.
	 * The kernel sets a bit while that buffer's block is on the free
	 * list, which is exactly when the card has no use for it: a
	 * container reads this out of its own map and needs to ask nobody
	 * which buffer is safe to fill.
	 */
	uvlong	txavail;
};

/*
 * One arm of a select, as it appears in the shared span.  The talk's own
 * arms hold pointers; here they hold offsets from the start of the
 * container's slice, since the span is at a different address in every
 * process that maps it.  An arm is turned off by setting op to MSnoop
 * rather than the array being built again.
 */
typedef struct Ospreyarm Ospreyarm;
struct Ospreyarm {
	uvlong	op;
	uvlong	obj;	/* ring: 0 requests, 1 replies, 2 output; down: semaphore */
	uvlong	buf;	/* offset of the message taken into or added from */
};

enum {
	OSlast,		/* these are the talk's MSlast, MSnoop, ... */
	OSnoop,
	OSget,
	OSput,
	OSdown,
};

#endif

/*
 * A block device exposed to a container: the exokernel way, as the
 * frame buffer and the input rings are.  The kernel finds a virtio 1.0
 * block device, publishes the BAR its registers live in as the physical
 * segment "virtioblk", and writes this descriptor at Ospreyblkoff in the
 * container's data area: where in that BAR the common configuration,
 * the notify region, the interrupt status and the device configuration
 * are (the four virtio-pci capabilities), the notify multiplier, the
 * physical address of the container's own slice (so a driver can give
 * the device the address of a ring or a buffer it keeps there), and the
 * semaphore the device's interrupt gives.  A driver above the kernel
 * does the rest: reset, features, a queue at Ospreyblkring in its data
 * area, requests, and a select on the semaphore for each completion.
 */
enum {
	Ospreyblkmagic	= 0x4f53424c4bULL,	/* "OSBLK" */
};
typedef struct Ospreyblk Ospreyblk;
struct Ospreyblk {
	uvlong	magic;
	uvlong	slicepa;	/* physical address of this container's slice */
	uvlong	barsize;	/* the "virtioblk" segment's size */
	uvlong	cfg;		/* offsets in it: common configuration */
	uvlong	notify;		/* the notify region */
	uvlong	notifymult;	/* its per-queue multiplier */
	uvlong	isr;		/* interrupt status */
	uvlong	devcfg;		/* device configuration: capacity first */
	uvlong	sem;		/* the semaphore the interrupt gives */
};
/*
 * A virtio 1.0 network device, the same way: the BAR as the segment
 * "virtionet", this descriptor (the same shape) at Ospreynetoff.  Its
 * device configuration begins with the MAC address.  A driver above the
 * kernel keeps its two queues and its frames in the slice's packet and
 * transmit buffers, which are physically contiguous with the slice.
 */
enum {
	Ospreynetmagic	= 0x4f534e4554ULL,	/* "OSNET" */
};
typedef Ospreyblk Ospreynet;
