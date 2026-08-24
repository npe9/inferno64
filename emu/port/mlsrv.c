/*
 * mlsrv - run a model, in a process of its own.
 *
 * ml(3)'s backend used to link onnxruntime into emu. That cannot be made to
 * work, and the reason is not a bug in either of them: emu aliases the libc
 * allocators into the Inferno pool - malloc, mallocz, free, realloc, calloc -
 * and onnxruntime uses several the aliasing does not cover, posix_memalign
 * and aligned_alloc and the malloc_zone calls among them. So it allocates on
 * one heap and frees on the other, and the corruption surfaces later, inside
 * Apple's neural library, as a jump to a small address. One utterance per
 * process worked; the second did not.
 *
 * Wrapping the rest of the allocator surface is not possible - malloc_zone_*
 * is not a wrappable interface - and removing the aliasing does not link,
 * because emu's own code needs the wrap symbols. So the library goes where
 * the aliasing is not: here, in a program emu starts and talks to over a
 * pipe, exactly as devcmd(3) starts any other host command.
 *
 * That the fix also isolates forty megabytes of third-party code from the
 * virtual machine is not a consolation prize. A device that virtualizes a
 * host capability has no business sharing an address space with the thing it
 * virtualizes, and this bug is what that principle looks like when ignored.
 *
 * The protocol is length-delimited and synchronous, because it is spoken by
 * one program to one other over a pipe and there is nothing to be gained by
 * making it clever:
 *
 *	request		op[1] len[4] payload[len]
 *	reply		st[1] len[4] payload[len]	st 0 ok, 1 error
 *
 * Lengths are big-endian, as everything on ml(3)'s wire is.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>

#include <onnxruntime_c_api.h>
#ifdef __APPLE__
#include <coreml_provider_factory.h>
#endif

enum {
	Oopen	= 'o',
	Oinfo	= 'i',
	Oshape	= 's',
	Owrite	= 'w',
	Orun	= 'r',
	Oget	= 'g',

	Maxdim	= 16,
};

static const OrtApi *ort;
static OrtEnv *env;
static OrtMemoryInfo *meminfo;

static OrtSession *session;
static OrtSessionOptions *opts;
static size_t nin, nout;
static char **innames, **outnames;
static OrtValue **invals, **outvals;
static int64_t (*pins)[Maxdim];
static size_t *npins;
static char provider[32] = "cpu";

static void
ign(OrtStatus *st)
{
	if(st != NULL)
		ort->ReleaseStatus(st);
}

/* a whole buffer, or end of file */
static int
readn(int fd, void *b, size_t n)
{
	size_t got;
	ssize_t r;

	for(got = 0; got < n; got += r){
		r = read(fd, (char*)b + got, n - got);
		if(r <= 0)
			return -1;
	}
	return 0;
}

static int
writen(int fd, const void *b, size_t n)
{
	size_t put;
	ssize_t r;

	for(put = 0; put < n; put += r){
		r = write(fd, (const char*)b + put, n - put);
		if(r <= 0)
			return -1;
	}
	return 0;
}

static void
put32(unsigned char *p, uint32_t v)
{
	p[0] = v>>24; p[1] = v>>16; p[2] = v>>8; p[3] = v;
}

static uint32_t
get32(const unsigned char *p)
{
	return ((uint32_t)p[0]<<24) | ((uint32_t)p[1]<<16) | ((uint32_t)p[2]<<8) | p[3];
}

static void
reply(int st, const void *b, size_t n)
{
	unsigned char h[5];

	h[0] = st;
	put32(h+1, (uint32_t)n);
	if(writen(1, h, 5) < 0 || (n > 0 && writen(1, b, n) < 0))
		exit(1);
}

static void
ok(const void *b, size_t n)
{
	reply(0, b, n);
}

static void
fail(const char *s)
{
	reply(1, s, strlen(s));
}

static int
failort(OrtStatus *st)
{
	if(st == NULL)
		return 0;
	fail(ort->GetErrorMessage(st));
	ort->ReleaseStatus(st);
	return 1;
}

/*
 * ml(3)'s wire is big-endian whatever the host is. The swap lives here rather
 * than in emu so that the pipe carries the device's own format unchanged.
 */
static int
bigendian(void)
{
	static const unsigned short one = 1;
	return *(const unsigned char*)&one == 0;
}

static void
swapbytes(void *dst, const void *src, size_t n, int esz)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	size_t i;
	int j;

	if(esz <= 1){
		memmove(dst, src, n);
		return;
	}
	for(i = 0; i + esz <= n; i += esz)
		for(j = 0; j < esz; j++)
			d[i+j] = s[i+esz-1-j];
}

static const char*
typename(ONNXTensorElementDataType t)
{
	switch(t){
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE:	return "f64";
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:	return "f32";
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16:	return "f16";
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:	return "i64";
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32:	return "i32";
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8:	return "i8";
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8:	return "u8";
	default:					return "opaque";
	}
}

static int
elemsize(ONNXTensorElementDataType t)
{
	switch(t){
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE:
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:	return 8;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32:	return 4;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16:	return 2;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8:
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8:	return 1;
	default:					return 0;
	}
}

static char**
getnames(int isin, size_t n)
{
	OrtAllocator *al;
	char **v, *p;
	size_t i;

	if(failort(ort->GetAllocatorWithDefaultOptions(&al)))
		return NULL;
	v = calloc(n, sizeof(char*));
	for(i = 0; i < n; i++){
		if(failort(isin? ort->SessionGetInputName(session, i, al, &p)
				: ort->SessionGetOutputName(session, i, al, &p)))
			return NULL;
		v[i] = strdup(p);
		al->Free(al, p);
	}
	return v;
}

static int
dimsof(int isin, size_t i, int64_t *d, size_t *nd, ONNXTensorElementDataType *t)
{
	OrtTypeInfo *ti;
	const OrtTensorTypeAndShapeInfo *si;
	OrtStatus *st;

	st = isin? ort->SessionGetInputTypeInfo(session, i, &ti)
		 : ort->SessionGetOutputTypeInfo(session, i, &ti);
	if(st != NULL){
		ort->ReleaseStatus(st);
		return -1;
	}
	si = NULL;
	ign(ort->CastTypeInfoToTensorInfo(ti, &si));
	if(si == NULL){
		ort->ReleaseTypeInfo(ti);
		return -1;
	}
	ign(ort->GetTensorElementType(si, t));
	ign(ort->GetDimensionsCount(si, nd));
	if(*nd > Maxdim)
		*nd = Maxdim;
	ign(ort->GetDimensions(si, d, *nd));
	ort->ReleaseTypeInfo(ti);
	return 0;
}

static int
findname(char **v, size_t n, const char *name)
{
	size_t i;

	if(name != NULL && name[0] != '\0'){
		for(i = 0; i < n; i++)
			if(strcmp(v[i], name) == 0)
				return (int)i;
		return -1;
	}
	return n == 1? 0: -1;
}

static void
doopen(unsigned char *p, uint32_t n)
{
	char *units = (char*)p;
	size_t ulen = strlen(units) + 1;

	if(ulen > n){
		fail("truncated open");
		return;
	}
	if(failort(ort->CreateSessionOptions(&opts)))
		return;
	ign(ort->SetIntraOpNumThreads(opts, 1));
#ifdef __APPLE__
	if(strcmp(units, "cpu") != 0){
		OrtStatus *st = OrtSessionOptionsAppendExecutionProvider_CoreML(opts, 0);
		if(st == NULL)
			strcpy(provider, "coreml");
		else
			ort->ReleaseStatus(st);
	}
#endif
	if(failort(ort->CreateSessionFromArray(env, p + ulen, n - ulen, opts, &session)))
		return;
	if(failort(ort->SessionGetInputCount(session, &nin)) ||
	   failort(ort->SessionGetOutputCount(session, &nout)))
		return;
	innames = getnames(1, nin);
	outnames = getnames(0, nout);
	invals = calloc(nin, sizeof(OrtValue*));
	outvals = calloc(nout, sizeof(OrtValue*));
	pins = calloc(nin, sizeof(*pins));
	npins = calloc(nin, sizeof(size_t));
	if(innames == NULL || outnames == NULL){
		fail("cannot read the model's feature names");
		return;
	}
	ok(NULL, 0);
}

static void
doinfo(void)
{
	char buf[16384];
	int o = 0;
	size_t i, j, nd;
	int64_t d[Maxdim];
	ONNXTensorElementDataType t;
	int isin;

	for(isin = 1; isin >= 0; isin--){
		size_t n = isin? nin: nout;
		char **nm = isin? innames: outnames;
		for(i = 0; i < n; i++){
			if(dimsof(isin, i, d, &nd, &t) < 0){
				o += snprintf(buf+o, sizeof buf - o, "%s %s opaque\n",
					isin? "in": "out", nm[i]);
				continue;
			}
			o += snprintf(buf+o, sizeof buf - o, "%s %s %s",
				isin? "in": "out", nm[i], typename(t));
			for(j = 0; j < nd; j++)
				o += snprintf(buf+o, sizeof buf - o, " %lld", (long long)d[j]);
			o += snprintf(buf+o, sizeof buf - o, "\n");
		}
	}
	/*
	 * With only the CPU provider registered, "cpu" is the only thing that
	 * can have run it and saying so is accurate. With CoreML registered,
	 * onnxruntime gives some nodes to it and keeps the rest, and does not
	 * report which - so that line says what was asked for and says that it
	 * is asking, rather than reporting a request as a result.
	 */
	if(strcmp(provider, "cpu") == 0)
		o += snprintf(buf+o, sizeof buf - o, "device cpu\n");
	else
		o += snprintf(buf+o, sizeof buf - o,
			"device %s requested (onnxruntime does not report which provider ran each node)\n",
			provider);
	ok(buf, o);
}

static void
doshape(unsigned char *p, uint32_t n)
{
	char *name = (char*)p;
	char *dims = name + strlen(name) + 1;
	int64_t d[Maxdim];
	size_t nd, j;
	ONNXTensorElementDataType t;
	char *s, *e;
	int i;

	(void)n;
	if((i = findname(innames, nin, name)) < 0){
		fail("no such input");
		return;
	}
	if(dimsof(1, i, d, &nd, &t) < 0){
		fail("input is not a tensor");
		return;
	}
	s = dims;
	for(j = 0; j < nd; j++){
		long v = strtol(s, &e, 10);
		if(e == s || v <= 0){
			fail("a dimension must be a positive number");
			return;
		}
		if(d[j] >= 0 && d[j] != v){
			fail("that contradicts a dimension the model fixed");
			return;
		}
		pins[i][j] = v;
		s = e;
	}
	if(strtol(s, &e, 10), e != s){
		fail("too many dimensions for this input");
		return;
	}
	npins[i] = nd;
	ok(NULL, 0);
}

static void
dowrite(unsigned char *p, uint32_t n)
{
	char *name = (char*)p;
	size_t nlen = strlen(name) + 1;
	unsigned char *b = p + nlen;
	size_t nb = n - nlen;
	int64_t d[Maxdim];
	size_t nd, j, nopen;
	ONNXTensorElementDataType t;
	long fixed, count;
	int i, esz;
	void *copy;

	if((i = findname(innames, nin, name)) < 0){
		fail("no such input");
		return;
	}
	if(dimsof(1, i, d, &nd, &t) < 0){
		fail("input is not a tensor");
		return;
	}
	if((esz = elemsize(t)) == 0){
		fail("input has an element type this does not handle");
		return;
	}
	if(nb % esz != 0){
		fail("not a whole number of values");
		return;
	}
	count = nb / esz;
	if(npins[i] == nd){
		fixed = 1;
		for(j = 0; j < nd; j++){
			d[j] = pins[i][j];
			fixed *= (long)d[j];
		}
		if(count != fixed){
			fail("that is not the amount the shape asks for");
			return;
		}
	}else{
		fixed = 1;
		nopen = 0;
		for(j = 0; j < nd; j++){
			if(d[j] < 0)
				nopen++;
			else
				fixed *= (long)d[j];
		}
		if(nopen > 1){
			fail("input leaves more than one dimension open: say which with \"shape\"");
			return;
		}
		if(nopen == 1){
			if(fixed <= 0 || count % fixed != 0){
				fail("not a multiple of the fixed dimensions");
				return;
			}
			for(j = 0; j < nd; j++)
				if(d[j] < 0)
					d[j] = count / fixed;
		}else if(count != fixed){
			fail("wrong number of values for this input");
			return;
		}
	}
	if(invals[i] != NULL){
		ort->ReleaseValue(invals[i]);
		invals[i] = NULL;
	}
	copy = malloc(nb == 0? 1: nb);
	if(copy == NULL){
		fail("out of memory");
		return;
	}
	if(bigendian())
		memmove(copy, b, nb);
	else
		swapbytes(copy, b, nb, esz);
	if(failort(ort->CreateTensorWithDataAsOrtValue(meminfo, copy, nb, d, nd, t, &invals[i])))
		return;
	ok(NULL, 0);
}

static void
dorun(void)
{
	const char **in, **on;
	const OrtValue **iv;
	size_t i;

	for(i = 0; i < nin; i++)
		if(invals[i] == NULL){
			fail("an input was not written");
			return;
		}
	for(i = 0; i < nout; i++)
		if(outvals[i] != NULL){
			ort->ReleaseValue(outvals[i]);
			outvals[i] = NULL;
		}
	in = calloc(nin, sizeof(char*));
	iv = calloc(nin, sizeof(OrtValue*));
	on = calloc(nout, sizeof(char*));
	for(i = 0; i < nin; i++){
		in[i] = innames[i];
		iv[i] = invals[i];
	}
	for(i = 0; i < nout; i++)
		on[i] = outnames[i];
	if(failort(ort->Run(session, NULL, in, iv, nin, on, nout, outvals))){
		free(in); free(iv); free(on);
		return;
	}
	free(in); free(iv); free(on);
	ok(NULL, 0);
}

static void
doget(unsigned char *p, uint32_t n)
{
	char *name = (char*)p;
	OrtTensorTypeAndShapeInfo *si;
	ONNXTensorElementDataType t;
	size_t count;
	void *d;
	unsigned char *b;
	int i, esz;
	size_t nb;

	(void)n;
	if((i = findname(outnames, nout, name)) < 0){
		fail("no such output");
		return;
	}
	if(outvals[i] == NULL){
		fail("nothing has been run yet");
		return;
	}
	if(failort(ort->GetTensorTypeAndShape(outvals[i], &si)))
		return;
	ign(ort->GetTensorElementType(si, &t));
	ign(ort->GetTensorShapeElementCount(si, &count));
	ort->ReleaseTensorTypeAndShapeInfo(si);
	if((esz = elemsize(t)) == 0){
		fail("output has an element type this does not handle");
		return;
	}
	nb = count * esz;
	if(failort(ort->GetTensorMutableData(outvals[i], &d)))
		return;
	b = malloc(nb == 0? 1: nb);
	if(b == NULL){
		fail("out of memory");
		return;
	}
	if(bigendian())
		memmove(b, d, nb);
	else
		swapbytes(b, d, nb, esz);
	ok(b, nb);
	free(b);
}

int
main(void)
{
	unsigned char hdr[5], *payload;
	uint32_t n;

	ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
	if(ort == NULL){
		fail("onnxruntime is a different version from this build");
		return 1;
	}
	if(failort(ort->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "inferno", &env)))
		return 1;
	if(failort(ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &meminfo)))
		return 1;

	for(;;){
		if(readn(0, hdr, 5) < 0)
			return 0;		/* emu closed the pipe: done */
		n = get32(hdr+1);
		payload = malloc(n + 1);
		if(payload == NULL)
			return 1;
		if(n > 0 && readn(0, payload, n) < 0)
			return 0;
		payload[n] = '\0';
		switch(hdr[0]){
		case Oopen:	doopen(payload, n); break;
		case Oinfo:	doinfo(); break;
		case Oshape:	doshape(payload, n); break;
		case Owrite:	dowrite(payload, n); break;
		case Orun:	dorun(); break;
		case Oget:	doget(payload, n); break;
		default:	fail("no such request"); break;
		}
		free(payload);
	}
}
