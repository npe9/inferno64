/*
 * btpeer: a peer this tree did not write.
 *
 * BlueZ's btvirt emulates controllers, and every controller it makes
 * goes in one list, so two connections to its server socket are two
 * controllers that can hear each other.  This takes the second one
 * and puts BlueZ's own host stack on it -- emulator/bthost.c, which
 * is what BlueZ's test suite drives its stack with -- so that what
 * the Inferno side meets is a controller, a link layer and a host
 * that were all written by other people from the same specifications.
 *
 * It advertises, connectably, with a name in the advertising data, so
 * a scan from the other connection finds it.
 *
 * The transport is H4 over the Unix socket: a packet type byte and
 * then the packet, which is what btvirt's server speaks and what
 * btfs's tcp! transport speaks at the other end.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>

#include "emulator/bthost.h"
#include "src/shared/mainloop.h"
#include "lib/uuid.h"
#include "src/shared/att.h"
#include "src/shared/gatt-db.h"
#include "src/shared/gatt-server.h"
#include "src/shared/timeout.h"

static int sk = -1;
static struct bthost *host;

/* the name it advertises under, and the one its GATT database gives */
static const char advname[] = "bluez-peer";

/* H4 out: whatever bthost built, straight down the socket */
static void send_handler(const struct iovec *iov, int iovlen, void *user_data)
{
	if (writev(sk, iov, iovlen) < 0)
		perror("btpeer: writev");
}

/*
 * H4 in.  A stream socket does not preserve packet boundaries, so the
 * packets are cut out here rather than handed on as they arrive:
 * bthost_receive_h4 wants one whole packet.  An event is a two byte
 * header and a one byte length; ACL data is a four byte header with a
 * sixteen bit length.
 */
static uint8_t buf[8192];
static size_t have;

static void read_cb(int fd, uint32_t events, void *user_data)
{
	ssize_t n;
	size_t off;

	if (events & (EPOLLERR | EPOLLHUP)) {
		fprintf(stderr, "btpeer: the controller went away\n");
		mainloop_quit();
		return;
	}
	n = read(fd, buf + have, sizeof(buf) - have);
	if (n <= 0) {
		fprintf(stderr, "btpeer: the controller closed\n");
		mainloop_quit();
		return;
	}
	have += n;

	off = 0;
	for (;;) {
		size_t avail = have - off, want;

		if (avail < 1)
			break;
		switch (buf[off]) {
		case 0x04:				/* event */
			if (avail < 3)
				goto out;
			want = 3 + buf[off + 2];
			break;
		case 0x02:				/* ACL data */
			if (avail < 5)
				goto out;
			want = 5 + (buf[off + 3] | (buf[off + 4] << 8));
			break;
		case 0x03:				/* SCO data */
			if (avail < 4)
				goto out;
			want = 4 + buf[off + 3];
			break;
		default:
			fprintf(stderr, "btpeer: packet type %#04x\n", buf[off]);
			mainloop_quit();
			return;
		}
		if (avail < want)
			break;
		bthost_receive_h4(host, buf + off, want);
		off += want;
	}
out:
	if (off) {
		memmove(buf, buf + off, have - off);
		have -= off;
	}
}

/*
 * The GATT server, which is BlueZ's and not this tree's.
 *
 * bt_gatt_server wants a file descriptor, because on Linux an ATT
 * channel is a socket.  There is no such socket here -- the channel
 * is a CID on a link inside bthost -- so a socketpair stands in for
 * one: what arrives on CID 4 is written into it, and what the server
 * writes back is read out of it and sent on CID 4.  SOCK_SEQPACKET
 * rather than SOCK_STREAM, because ATT is a datagram protocol and a
 * PDU that arrived in two reads would be two malformed PDUs.
 */
static struct gatt_db *db;
static struct bt_att *att;
static struct bt_gatt_server *gatt;
static int attsk = -1;			/* our end of the pair */
static uint16_t conn_handle;
static struct gatt_db_attribute *notify_chrc;

/*
 * Something long enough that writing it does not fit in one PDU, so
 * the other side has to use Prepare Write and Execute Write and this
 * side's answers to those come from BlueZ's server rather than from
 * anything here.
 */
static uint8_t testval[512] = "bluez";
static size_t testlen = 5;
static uint8_t ccc[2];

/* the battery service, which notifies on a timer once it is asked to */
static struct gatt_db_attribute *batt_chrc;
static uint8_t battccc[2];
static uint8_t battlevel = 99;
static unsigned int batttimer;

static void att_from_peer(const void *data, uint16_t len, void *user_data)
{
	if (write(attsk, data, len) < 0)
		perror("btpeer: write to att");
}

static void att_to_peer(int fd, uint32_t events, void *user_data)
{
	uint8_t pdu[1024];
	ssize_t n;

	if (events & (EPOLLERR | EPOLLHUP))
		return;
	n = read(fd, pdu, sizeof(pdu));
	if (n <= 0)
		return;
	bthost_send_cid(host, conn_handle, 4, pdu, n);
}

static void name_read(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, uint8_t opcode, struct bt_att *a,
			void *user_data)
{
	gatt_db_attribute_read_result(attrib, id, 0,
					(const uint8_t *) advname,
					sizeof(advname) - 1);
}

static void appearance_read(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, uint8_t opcode, struct bt_att *a,
			void *user_data)
{
	static const uint8_t v[2] = { 0x00, 0x00 };

	gatt_db_attribute_read_result(attrib, id, 0, v, sizeof(v));
}

static void test_read(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, uint8_t opcode, struct bt_att *a,
			void *user_data)
{
	if (offset > testlen) {
		gatt_db_attribute_read_result(attrib, id,
					BT_ATT_ERROR_INVALID_OFFSET, NULL, 0);
		return;
	}
	gatt_db_attribute_read_result(attrib, id, 0,
					testval + offset, testlen - offset);
}

/*
 * A write is answered and then notified back, so that one write from
 * the other side exercises the write path and the notification path
 * and says which value arrived.
 */
static void test_write(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, const uint8_t *value, size_t len,
			uint8_t opcode, struct bt_att *a, void *user_data)
{
	if (offset + len > sizeof(testval)) {
		gatt_db_attribute_write_result(attrib, id,
					BT_ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LEN);
		return;
	}
	memcpy(testval + offset, value, len);
	testlen = offset + len;
	gatt_db_attribute_write_result(attrib, id, 0);
	printf("btpeer: written %zu bytes\n", testlen);
	fflush(stdout);

	if (notify_chrc && (ccc[0] & 0x01))
		bt_gatt_server_send_notification(gatt,
				gatt_db_attribute_get_handle(notify_chrc),
				testval, testlen, false);
}

static void batt_read(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, uint8_t opcode, struct bt_att *a,
			void *user_data)
{
	gatt_db_attribute_read_result(attrib, id, 0, &battlevel, 1);
}

static bool batt_tick(void *user_data)
{
	if (!(battccc[0] & 0x01))
		return true;
	if (battlevel > 1)
		battlevel--;
	bt_gatt_server_send_notification(gatt,
			gatt_db_attribute_get_handle(batt_chrc),
			&battlevel, 1, false);
	return true;
}

static void battccc_read(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, uint8_t opcode, struct bt_att *a,
			void *user_data)
{
	gatt_db_attribute_read_result(attrib, id, 0, battccc, sizeof(battccc));
}

static void battccc_write(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, const uint8_t *value, size_t len,
			uint8_t opcode, struct bt_att *a, void *user_data)
{
	if (offset || len != 2) {
		gatt_db_attribute_write_result(attrib, id,
					BT_ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LEN);
		return;
	}
	memcpy(battccc, value, 2);
	gatt_db_attribute_write_result(attrib, id, 0);
	printf("btpeer: battery notifications %s\n",
			(battccc[0] & 1) ? "on" : "off");
	fflush(stdout);
	if ((battccc[0] & 1) && !batttimer)
		batttimer = timeout_add(500, batt_tick, NULL, NULL);
}

static void ccc_read(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, uint8_t opcode, struct bt_att *a,
			void *user_data)
{
	gatt_db_attribute_read_result(attrib, id, 0, ccc, sizeof(ccc));
}

static void ccc_write(struct gatt_db_attribute *attrib, unsigned int id,
			uint16_t offset, const uint8_t *value, size_t len,
			uint8_t opcode, struct bt_att *a, void *user_data)
{
	if (offset || len != 2) {
		gatt_db_attribute_write_result(attrib, id,
					BT_ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LEN);
		return;
	}
	memcpy(ccc, value, 2);
	gatt_db_attribute_write_result(attrib, id, 0);
	printf("btpeer: notifications %s\n", (ccc[0] & 1) ? "on" : "off");
	fflush(stdout);
}

static void make_db(void)
{
	struct gatt_db_attribute *svc;
	bt_uuid_t uuid;

	db = gatt_db_new();

	/* generic access: the name and the appearance */
	bt_uuid16_create(&uuid, 0x1800);
	svc = gatt_db_add_service(db, &uuid, true, 5);
	bt_uuid16_create(&uuid, 0x2a00);
	gatt_db_service_add_characteristic(svc, &uuid, BT_ATT_PERM_READ,
			BT_GATT_CHRC_PROP_READ, name_read, NULL, NULL);
	bt_uuid16_create(&uuid, 0x2a01);
	gatt_db_service_add_characteristic(svc, &uuid, BT_ATT_PERM_READ,
			BT_GATT_CHRC_PROP_READ, appearance_read, NULL, NULL);
	gatt_db_service_set_active(svc, true);

	/* generic attribute */
	bt_uuid16_create(&uuid, 0x1801);
	svc = gatt_db_add_service(db, &uuid, true, 1);
	gatt_db_service_set_active(svc, true);

	/* battery, which is what the bench subscribes to */
	bt_uuid16_create(&uuid, 0x180f);
	svc = gatt_db_add_service(db, &uuid, true, 4);
	bt_uuid16_create(&uuid, 0x2a19);
	batt_chrc = gatt_db_service_add_characteristic(svc, &uuid,
			BT_ATT_PERM_READ,
			BT_GATT_CHRC_PROP_READ | BT_GATT_CHRC_PROP_NOTIFY,
			batt_read, NULL, NULL);
	bt_uuid16_create(&uuid, 0x2902);
	gatt_db_service_add_descriptor(svc, &uuid,
			BT_ATT_PERM_READ | BT_ATT_PERM_WRITE,
			battccc_read, battccc_write, NULL);
	gatt_db_service_set_active(svc, true);

	/* and something to read, write and be notified from */
	bt_uuid16_create(&uuid, 0xfff0);
	svc = gatt_db_add_service(db, &uuid, true, 8);
	bt_uuid16_create(&uuid, 0xfff1);
	gatt_db_service_add_characteristic(svc, &uuid,
			BT_ATT_PERM_READ | BT_ATT_PERM_WRITE,
			BT_GATT_CHRC_PROP_READ | BT_GATT_CHRC_PROP_WRITE,
			test_read, test_write, NULL);
	bt_uuid16_create(&uuid, 0xfff2);
	notify_chrc = gatt_db_service_add_characteristic(svc, &uuid,
			BT_ATT_PERM_READ,
			BT_GATT_CHRC_PROP_READ | BT_GATT_CHRC_PROP_NOTIFY,
			test_read, NULL, NULL);
	bt_uuid16_create(&uuid, 0x2902);
	gatt_db_service_add_descriptor(svc, &uuid,
			BT_ATT_PERM_READ | BT_ATT_PERM_WRITE,
			ccc_read, ccc_write, NULL);
	gatt_db_service_set_active(svc, true);
}

/*
 * A BR/EDR L2CAP server and an RFCOMM server, both of which answer
 * with the same bytes in upper case rather than echoing them.
 *
 * An echo is a weak assertion: a loopback anywhere along the path
 * passes it, and this bench has already had one frame handed back to
 * it that never reached the far end.  Upper case has to be applied by
 * whoever received it.
 */
#define TESTPSM		0x1001		/* not assigned; a test PSM */
#define RFCHAN		1

static uint16_t l2cid;

static void upper(uint8_t *d, const void *src, uint16_t len)
{
	uint16_t i;
	const uint8_t *s = src;

	for (i = 0; i < len; i++)
		d[i] = (s[i] >= 'a' && s[i] <= 'z') ? s[i] - 32 : s[i];
}

static void l2cap_data(const void *data, uint16_t len, void *user_data)
{
	uint8_t buf[1024];

	if (len > sizeof(buf))
		len = sizeof(buf);
	upper(buf, data, len);
	printf("btpeer: l2cap %u bytes, answering in upper case\n", len);
	fflush(stdout);
	bthost_send_cid(host, conn_handle, l2cid, buf, len);
}

static void l2cap_conn(uint16_t handle, uint16_t cid, void *user_data)
{
	printf("btpeer: l2cap psm %#06x open, cid %u\n", TESTPSM, cid);
	fflush(stdout);
	conn_handle = handle;
	l2cid = cid;
	bthost_add_cid_hook(host, handle, cid, l2cap_data, NULL);
}

static void l2cap_disconn(void *user_data)
{
	printf("btpeer: l2cap closed\n");
	fflush(stdout);
}

static void rfcomm_data(const void *data, uint16_t len, void *user_data)
{
	uint8_t buf[1024];

	if (len > sizeof(buf))
		len = sizeof(buf);
	upper(buf, data, len);
	printf("btpeer: rfcomm %u bytes, answering in upper case\n", len);
	fflush(stdout);
	bthost_send_rfcomm_data(host, conn_handle, RFCHAN, buf, len);
}

/*
 * status is true when the channel came up, not when it failed:
 * bthost sends the UA and then calls this with true.  Reading it the
 * other way round -- which is the way round the name suggests --
 * makes a channel that opened perfectly well look refused, and the
 * data hook never gets installed, so the far end writes into silence
 * and times out reading.  BlueZ's own tools/rfcomm-tester.c ignores
 * the argument entirely.
 */
static void rfcomm_conn(uint16_t handle, uint16_t cid, void *user_data,
								bool status)
{
	printf("btpeer: rfcomm channel %u %s\n", RFCHAN,
			status ? "open" : "refused");
	fflush(stdout);
	if (!status)
		return;
	conn_handle = handle;
	bthost_add_rfcomm_chan_hook(host, handle, RFCHAN, rfcomm_data, NULL);
}

static void connect_cb(uint16_t handle, void *user_data)
{
	int sv[2];

	printf("btpeer: connected, handle %u\n", handle);
	fflush(stdout);
	conn_handle = handle;

	if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK, 0, sv) < 0) {
		perror("btpeer: socketpair");
		return;
	}
	attsk = sv[1];

	make_db();
	att = bt_att_new(sv[0], false);
	bt_att_set_close_on_unref(att, true);
	gatt = bt_gatt_server_new(db, att, 517, 0);
	if (!gatt) {
		fprintf(stderr, "btpeer: no gatt server\n");
		return;
	}

	bthost_add_cid_hook(host, handle, 4, att_from_peer, NULL);
	mainloop_add_fd(attsk, EPOLLIN, att_to_peer, NULL, NULL);
	printf("btpeer: serving BlueZ's own GATT database\n");
	fflush(stdout);
}

/*
 * Advertising data: the flags every connectable device sets, and a
 * complete local name, which is what the other side's scan will show
 * and what a bench phase can then assert on.
 */

static void ready_cb(void)
{
	uint8_t ad[3 + 2 + sizeof(advname) - 1];
	size_t n = 0;

	ad[n++] = 2;
	ad[n++] = 0x01;			/* flags */
	ad[n++] = 0x06;			/* general discoverable, no BR/EDR */
	ad[n++] = 1 + sizeof(advname) - 1;
	ad[n++] = 0x09;			/* complete local name */
	memcpy(ad + n, advname, sizeof(advname) - 1);
	n += sizeof(advname) - 1;

	bthost_set_adv_data(host, ad, n);
	bthost_set_adv_enable(host, 0x01);
	bthost_write_scan_enable(host, 0x03);	/* discoverable for BR/EDR too */
	bthost_add_l2cap_server(host, TESTPSM, l2cap_conn, l2cap_disconn, NULL);
	/*
	 * RFCOMM needs both: an L2CAP server on PSM 3 to accept the
	 * channel the multiplexer runs over, and the RFCOMM server
	 * proper for the DLC on it.  bthost_add_rfcomm_server only
	 * records the channel callback and registers no PSM, so
	 * without the first line an incoming connection is refused
	 * with "PSM not supported" and nothing says why.  BlueZ's own
	 * tools/rfcomm-tester.c does the same two calls.
	 */
	bthost_add_l2cap_server(host, 0x0003, NULL, NULL, NULL);
	bthost_add_rfcomm_server(host, RFCHAN, rfcomm_conn, NULL);
	printf("btpeer: advertising as %s\n", advname);
	fflush(stdout);
}

int main(int argc, char *argv[])
{
	const char *path = argc > 1 ? argv[1] : "/tmp/bt-server-bredrle";
	struct sockaddr_un addr;

	sk = socket(PF_UNIX, SOCK_STREAM, 0);
	if (sk < 0) {
		perror("btpeer: socket");
		return 1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
	if (connect(sk, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
		perror("btpeer: connect");
		return 1;
	}

	mainloop_init();

	host = bthost_create();
	if (!host) {
		fprintf(stderr, "btpeer: cannot make a host\n");
		return 1;
	}
	bthost_set_send_handler(host, send_handler, NULL);
	bthost_set_connect_cb(host, connect_cb, NULL);
	bthost_notify_ready(host, ready_cb);

	mainloop_add_fd(sk, EPOLLIN, read_cb, NULL, NULL);

	printf("btpeer: on %s\n", path);
	fflush(stdout);
	bthost_start(host);

	return mainloop_run();
}
