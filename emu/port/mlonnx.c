/*
 * ml(3)'s backend: run a portable model graph, on whatever the host has.
 *
 * The model format is ONNX, and that is the point of this file. What came
 * before took CoreML's own .mlmodel, which made the *model file* a host
 * artefact: the same trained network had to exist once per platform, and
 * ml(3)'s interface talked in CoreML's vocabulary - multi-array features,
 * opaque sequence features - which is host structure showing through a
 * device that is supposed to virtualize a capability. ONNX in, and the host
 * does whatever it must underneath.
 *
 * On Apple silicon that underneath is still CoreML and so still the Neural
 * Engine: onnxruntime's CoreML execution provider takes the parts of the
 * graph it can and runs them there. macOS has no way to do this in a system
 * framework - CoreML compiles .mlmodel and .mlpackage and nothing else, and
 * Apple's own Python converter dropped ONNX - so the conversion happens
 * inside onnxruntime rather than in the operating system.
 *
 * This file is portable C on purpose, even though only MacOSX links it
 * today. The onnxruntime C API is the same everywhere, so a platform that
 * wants ml(3) needs a conf line and the library, not a new backend. That is
 * the second reason for the change: ml(3) was macOS-only because its backend
 * was, not because the device was.
 *
 * The library is fetched, not vendored: 41MB of third-party dylib has no
 * business in a source tree. man/3/ml says where to get it.
 */

#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include	<onnxruntime_c_api.h>
#ifdef	MACOSX_ARM64
#include	<coreml_provider_factory.h>
#endif

typedef struct Mlmodel Mlmodel;
typedef struct Mlin Mlin;

struct Mlin {
	char*		name;
	OrtValue*	val;
};

struct Mlmodel {
	OrtSession*	session;
	OrtSessionOptions* opts;
	size_t		nin;
	size_t		nout;
	char**		innames;
	char**		outnames;
	Mlin*		in;		/* what has been written so far */
	OrtValue**	out;		/* results of the last run */
	char*		provider;	/* what was asked for */
};

static const OrtApi *ort;
static OrtEnv *ortenv;
static OrtMemoryInfo *ortmem;

void*	mlort_open(unsigned char*, int, char*, char*, int);
void	mlort_close(void*);
int	mlort_info(void*, char*, int);
int	mlort_setinput(void*, char*, unsigned char*, int, char*, int);
int	mlort_run(void*, char*, int);
int	mlort_getoutput(void*, char*, unsigned char*, int, char*, int);

/*
 * A status is an allocated object even when nothing went wrong is not the
 * case - it is nil then - but a call that fails and whose failure is not
 * worth reporting still hands one over, and dropping it leaks the message.
 * These are calls on type information ORT has just handed us, where a failure
 * would mean ORT disagreeing with itself.
 */
static void
ign(OrtStatus *st)
{
	if(st != nil)
		ort->ReleaseStatus(st);
}

/*
 * ml(3)'s wire is big-endian, whatever the host is, and that is the device's
 * contract rather than this backend's choice: a client marshals with
 * math(2)'s export_real and expects the same bytes to mean the same thing
 * whichever machine reads them. The CoreML backend swapped here and so does
 * this one. Getting it wrong would not fail loudly - it would return a
 * plausible-looking wrong number, which is exactly what the fixture's
 * asymmetric weights were chosen to catch.
 */
static int
bigendian(void)
{
	static const ushort one = 1;
	return *(const uchar*)&one == 0;
}

static void
swapbytes(void *dst, const void *src, long n, int esz)
{
	uchar *d;
	const uchar *s;
	long i;
	int j;

	d = dst;
	s = src;
	if(esz <= 1){
		memmove(dst, src, n);
		return;
	}
	for(i = 0; i + esz <= n; i += esz)
		for(j = 0; j < esz; j++)
			d[i+j] = s[i+esz-1-j];
}

static void
seterr(char *err, int nerr, char *s)
{
	if(err != nil && nerr > 0)
		snprint(err, nerr, "%s", s);
}

/*
 * An OrtStatus is an allocated object, not a code: leaking one per failed
 * call would leak the message with it.
 */
static int
oerr(OrtStatus *st, char *err, int nerr)
{
	if(st == nil)
		return 0;
	seterr(err, nerr, (char*)ort->GetErrorMessage(st));
	ort->ReleaseStatus(st);
	return -1;
}

static char*
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
	}
	return "opaque";
}

static int
elemsize(ONNXTensorElementDataType t)
{
	switch(t){
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE:	return 8;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:	return 8;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:	return 4;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32:	return 4;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16:	return 2;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8:	return 1;
	case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8:	return 1;
	}
	return 0;
}

static int
ortinit(char *err, int nerr)
{
	if(ort != nil)
		return 0;
	ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
	if(ort == nil){
		seterr(err, nerr, "onnxruntime is a different version from this build");
		return -1;
	}
	if(oerr(ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "inferno", &ortenv), err, nerr) < 0){
		ort = nil;
		return -1;
	}
	if(oerr(ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &ortmem), err, nerr) < 0){
		ort = nil;
		return -1;
	}
	return 0;
}

/* the names of a model's inputs or outputs, copied out of ORT's allocator */
static char**
names(OrtSession *s, int isin, size_t n, char *err, int nerr)
{
	OrtAllocator *al;
	char **v, *p;
	size_t i;

	if(oerr(ort->GetAllocatorWithDefaultOptions(&al), err, nerr) < 0)
		return nil;
	v = malloc(n * sizeof(char*));
	if(v == nil)
		return nil;
	memset(v, 0, n * sizeof(char*));
	for(i = 0; i < n; i++){
		OrtStatus *st;
		if(isin)
			st = ort->SessionGetInputName(s, i, al, &p);
		else
			st = ort->SessionGetOutputName(s, i, al, &p);
		if(oerr(st, err, nerr) < 0){
			free(v);
			return nil;
		}
		v[i] = strdup(p);
		al->Free(al, p);
	}
	return v;
}

void*
mlort_open(unsigned char *spec, int nspec, char *units, char *err, int nerr)
{
	Mlmodel *m;
	OrtStatus *st;

	if(spec == nil || nspec <= 0){
		seterr(err, nerr, "empty model");
		return nil;
	}
	if(ortinit(err, nerr) < 0)
		return nil;

	m = malloc(sizeof(Mlmodel));
	if(m == nil){
		seterr(err, nerr, "out of memory");
		return nil;
	}
	memset(m, 0, sizeof(Mlmodel));

	if(oerr(ort->CreateSessionOptions(&m->opts), err, nerr) < 0){
		free(m);
		return nil;
	}

	/*
	 * The compute units asked for. Where a provider will not attach, the
	 * failure is not fatal: the graph still runs, on the CPU provider, and
	 * info says what was asked for rather than pretending it happened.
	 */
	m->provider = strdup("cpu");
#ifdef MACOSX_ARM64
	if(units == nil || *units == '\0' || strcmp(units, "cpu") != 0){
		st = OrtSessionOptionsAppendExecutionProvider_CoreML(m->opts, 0);
		if(st == nil){
			free(m->provider);
			m->provider = strdup("coreml");
		}else
			ort->ReleaseStatus(st);
	}
#else
	USED(units);
#endif

	/*
	 * From memory: devml.c already holds the whole model, so writing it to
	 * a temporary file and handing over a path would be a copy for nothing.
	 */
	if(oerr(ort->CreateSessionFromArray(ortenv, spec, nspec, m->opts, &m->session), err, nerr) < 0){
		ort->ReleaseSessionOptions(m->opts);
		free(m->provider);
		free(m);
		return nil;
	}
	if(oerr(ort->SessionGetInputCount(m->session, &m->nin), err, nerr) < 0 ||
	   oerr(ort->SessionGetOutputCount(m->session, &m->nout), err, nerr) < 0){
		mlort_close(m);
		return nil;
	}
	m->innames = names(m->session, 1, m->nin, err, nerr);
	m->outnames = names(m->session, 0, m->nout, err, nerr);
	m->in = malloc(m->nin * sizeof(Mlin));
	m->out = malloc(m->nout * sizeof(OrtValue*));
	if(m->innames == nil || m->outnames == nil || m->in == nil || m->out == nil){
		seterr(err, nerr, "out of memory");
		mlort_close(m);
		return nil;
	}
	memset(m->in, 0, m->nin * sizeof(Mlin));
	memset(m->out, 0, m->nout * sizeof(OrtValue*));
	return m;
}

void
mlort_close(void *h)
{
	Mlmodel *m = h;
	size_t i;

	if(m == nil)
		return;
	if(m->in != nil){
		for(i = 0; i < m->nin; i++)
			if(m->in[i].val != nil)
				ort->ReleaseValue(m->in[i].val);
		free(m->in);
	}
	if(m->out != nil){
		for(i = 0; i < m->nout; i++)
			if(m->out[i] != nil)
				ort->ReleaseValue(m->out[i]);
		free(m->out);
	}
	if(m->innames != nil){
		for(i = 0; i < m->nin; i++)
			free(m->innames[i]);
		free(m->innames);
	}
	if(m->outnames != nil){
		for(i = 0; i < m->nout; i++)
			free(m->outnames[i]);
		free(m->outnames);
	}
	if(m->session != nil)
		ort->ReleaseSession(m->session);
	if(m->opts != nil)
		ort->ReleaseSessionOptions(m->opts);
	free(m->provider);
	free(m);
}

/*
 * A dimension of -1 is one the model leaves open - a sequence whose length is
 * decided by the caller. It is reported as -1 rather than guessed at, and a
 * write fills it in; see mlort_setinput.
 */
static int
describe(OrtSession *s, int isin, size_t n, char **nm, char *buf, int nbuf, int o)
{
	OrtTypeInfo *ti;
	const OrtTensorTypeAndShapeInfo *si;
	ONNXTensorElementDataType t;
	size_t nd, i, j;
	int64_t d[16];

	for(i = 0; i < n; i++){
		OrtStatus *st;
		if(isin)
			st = ort->SessionGetInputTypeInfo(s, i, &ti);
		else
			st = ort->SessionGetOutputTypeInfo(s, i, &ti);
		if(st != nil){
			ort->ReleaseStatus(st);
			o += snprint(buf+o, nbuf-o, "%s %s opaque\n", isin? "in": "out", nm[i]);
			continue;
		}
		si = nil;
		ign(ort->CastTypeInfoToTensorInfo(ti, &si));
		if(si == nil){
			o += snprint(buf+o, nbuf-o, "%s %s opaque\n", isin? "in": "out", nm[i]);
			ort->ReleaseTypeInfo(ti);
			continue;
		}
		ign(ort->GetTensorElementType(si, &t));
		ign(ort->GetDimensionsCount(si, &nd));
		if(nd > nelem(d))
			nd = nelem(d);
		ign(ort->GetDimensions(si, d, nd));
		o += snprint(buf+o, nbuf-o, "%s %s %s", isin? "in": "out", nm[i], typename(t));
		for(j = 0; j < nd; j++)
			o += snprint(buf+o, nbuf-o, " %lld", (long long)d[j]);
		o += snprint(buf+o, nbuf-o, "\n");
		ort->ReleaseTypeInfo(ti);
	}
	return o;
}

int
mlort_info(void *h, char *buf, int nbuf)
{
	Mlmodel *m = h;
	int o;

	if(m == nil || buf == nil || nbuf <= 0)
		return -1;
	o = 0;
	o = describe(m->session, 1, m->nin, m->innames, buf, nbuf, o);
	o = describe(m->session, 0, m->nout, m->outnames, buf, nbuf, o);
	/*
	 * With only the CPU provider registered, "cpu" is not a claim about
	 * what was asked for - it is the only thing that can have run it, and
	 * saying so is accurate.
	 *
	 * With CoreML registered it is a different matter: onnxruntime takes
	 * the parts of the graph CoreML will have and leaves the rest on the
	 * CPU, and it does not report which went where. So that line says the
	 * provider was asked for rather than that it ran, because reporting a
	 * request as though it were a result is the mistake gpu(3) shipped
	 * once and ml(3)'s rule is to say so instead.
	 */
	if(strcmp(m->provider, "cpu") == 0)
		o += snprint(buf+o, nbuf-o, "device cpu\n");
	else
		o += snprint(buf+o, nbuf-o,
			"device %s requested (onnxruntime does not report which provider ran each node)\n",
			m->provider);
	return o;
}

static int
findname(char **v, size_t n, char *name, char *err, int nerr, char *what)
{
	size_t i;
	char buf[128];

	if(name != nil && name[0] != '\0'){
		for(i = 0; i < n; i++)
			if(strcmp(v[i], name) == 0)
				return (int)i;
		snprint(buf, sizeof buf, "no %s named %s", what, name);
		seterr(err, nerr, buf);
		return -1;
	}
	if(n != 1){
		snprint(buf, sizeof buf, "model has %lud %ss: name one", (ulong)n, what);
		seterr(err, nerr, buf);
		return -1;
	}
	return 0;
}

int
mlort_setinput(void *h, char *name, unsigned char *b, int n, char *err, int nerr)
{
	Mlmodel *m = h;
	OrtTypeInfo *ti;
	const OrtTensorTypeAndShapeInfo *si;
	ONNXTensorElementDataType t;
	size_t nd, j, nopen;
	int64_t d[16];
	long fixed, count;
	int i, esz;
	char buf[160];

	if(m == nil)
		return -1;
	if((i = findname(m->innames, m->nin, name, err, nerr, "input")) < 0)
		return -1;
	if(oerr(ort->SessionGetInputTypeInfo(m->session, i, &ti), err, nerr) < 0)
		return -1;
	si = nil;
	ign(ort->CastTypeInfoToTensorInfo(ti, &si));
	if(si == nil){
		ort->ReleaseTypeInfo(ti);
		seterr(err, nerr, "input is not a tensor");
		return -1;
	}
	ign(ort->GetTensorElementType(si, &t));
	ign(ort->GetDimensionsCount(si, &nd));
	if(nd > nelem(d))
		nd = nelem(d);
	ign(ort->GetDimensions(si, d, nd));
	ort->ReleaseTypeInfo(ti);

	esz = elemsize(t);
	if(esz == 0){
		seterr(err, nerr, "input has an element type this does not handle");
		return -1;
	}
	if(n % esz != 0){
		snprint(buf, sizeof buf, "input %s is %s: %d bytes is not a whole number of values",
			m->innames[i], typename(t), n);
		seterr(err, nerr, buf);
		return -1;
	}
	count = n / esz;

	/*
	 * Fill in whatever the model left open. One open dimension can be
	 * worked out from the amount written; two cannot, and guessing which
	 * to grow would be inventing an answer.
	 */
	fixed = 1;
	nopen = 0;
	for(j = 0; j < nd; j++){
		if(d[j] < 0)
			nopen++;
		else
			fixed *= (long)d[j];
	}
	if(nopen > 1){
		seterr(err, nerr, "input leaves more than one dimension open");
		return -1;
	}
	if(fixed <= 0){
		seterr(err, nerr, "input has a zero dimension");
		return -1;
	}
	if(nopen == 1){
		if(count % fixed != 0){
			snprint(buf, sizeof buf,
				"input %s takes a multiple of %ld %s values, got %ld",
				m->innames[i], fixed, typename(t), count);
			seterr(err, nerr, buf);
			return -1;
		}
		for(j = 0; j < nd; j++)
			if(d[j] < 0)
				d[j] = count / fixed;
	}else if(count != fixed){
		snprint(buf, sizeof buf, "input %s wants %ld %s values, got %ld",
			m->innames[i], fixed, typename(t), count);
		seterr(err, nerr, buf);
		return -1;
	}

	if(m->in[i].val != nil){
		ort->ReleaseValue(m->in[i].val);
		m->in[i].val = nil;
	}
	free(m->in[i].name);
	m->in[i].name = strdup(m->innames[i]);
	/*
	 * ORT does not copy: the tensor points at this buffer, so it has to
	 * outlive the run. devml.c's own copy is freed when the next input is
	 * written, which is after the run, so a copy is made here rather than
	 * relying on that.
	 */
	{
		void *copy = malloc(n);
		if(copy == nil){
			seterr(err, nerr, "out of memory");
			return -1;
		}
		if(bigendian())
			memmove(copy, b, n);
		else
			swapbytes(copy, b, n, esz);
		if(oerr(ort->CreateTensorWithDataAsOrtValue(ortmem, copy, n, d, nd, t,
				&m->in[i].val), err, nerr) < 0){
			free(copy);
			return -1;
		}
	}
	return 0;
}

int
mlort_run(void *h, char *err, int nerr)
{
	Mlmodel *m = h;
	const char **innames, **outnames;
	const OrtValue **invals;
	size_t i;
	int r;
	char buf[128];

	if(m == nil)
		return -1;
	for(i = 0; i < m->nin; i++)
		if(m->in[i].val == nil){
			snprint(buf, sizeof buf, "input %s was not written", m->innames[i]);
			seterr(err, nerr, buf);
			return -1;
		}
	for(i = 0; i < m->nout; i++)
		if(m->out[i] != nil){
			ort->ReleaseValue(m->out[i]);
			m->out[i] = nil;
		}
	innames = malloc(m->nin * sizeof(char*));
	invals = malloc(m->nin * sizeof(OrtValue*));
	outnames = malloc(m->nout * sizeof(char*));
	if(innames == nil || invals == nil || outnames == nil){
		free(innames); free(invals); free(outnames);
		seterr(err, nerr, "out of memory");
		return -1;
	}
	for(i = 0; i < m->nin; i++){
		innames[i] = m->innames[i];
		invals[i] = m->in[i].val;
	}
	for(i = 0; i < m->nout; i++)
		outnames[i] = m->outnames[i];

	r = oerr(ort->Run(m->session, nil, innames, invals, m->nin,
			outnames, m->nout, m->out), err, nerr);
	free(innames); free(invals); free(outnames);
	return r;
}

int
mlort_getoutput(void *h, char *name, unsigned char *b, int nbuf, char *err, int nerr)
{
	Mlmodel *m = h;
	OrtTensorTypeAndShapeInfo *si;
	ONNXTensorElementDataType t;
	size_t count;
	void *p;
	int i, esz, n;
	char buf[128];

	if(m == nil)
		return -1;
	if((i = findname(m->outnames, m->nout, name, err, nerr, "output")) < 0)
		return -1;
	if(m->out[i] == nil){
		seterr(err, nerr, "nothing has been run yet");
		return -1;
	}
	if(oerr(ort->GetTensorTypeAndShape(m->out[i], &si), err, nerr) < 0)
		return -1;
	ign(ort->GetTensorElementType(si, &t));
	ign(ort->GetTensorShapeElementCount(si, &count));
	ort->ReleaseTensorTypeAndShapeInfo(si);
	esz = elemsize(t);
	if(esz == 0){
		seterr(err, nerr, "output has an element type this does not handle");
		return -1;
	}
	n = (int)(count * esz);
	/*
	 * devml.c asks how big the result is before it has anywhere to put it,
	 * so a nil buffer is a question rather than a too-small read.
	 */
	if(b == nil)
		return n;
	if(n > nbuf){
		snprint(buf, sizeof buf, "output %s is %d bytes, the read asked for %d",
			m->outnames[i], n, nbuf);
		seterr(err, nerr, buf);
		return -1;
	}
	if(oerr(ort->GetTensorMutableData(m->out[i], &p), err, nerr) < 0)
		return -1;
	if(bigendian())
		memmove(b, p, n);
	else
		swapbytes(b, p, n, esz);
	return n;
}

/*
 * Installed into devml.c's nullable hooks at load time, exactly as the CoreML
 * backend did. Where this file is not linked they stay nil and ml(3) reports
 * that it has no backend, rather than the device being compiled away.
 */
extern void*	(*mlopenmodel)(unsigned char*, int, char*, char*, int);
extern void	(*mlclosemodel)(void*);
extern int	(*mlmodelinfo)(void*, char*, int);
extern int	(*mlsetinput)(void*, char*, unsigned char*, int, char*, int);
extern int	(*mlrunmodel)(void*, char*, int);
extern int	(*mlgetoutput)(void*, char*, unsigned char*, int, char*, int);

__attribute__((constructor))
static void
mlhwinit(void)
{
	mlopenmodel = mlort_open;
	mlclosemodel = mlort_close;
	mlmodelinfo = mlort_info;
	mlsetinput = mlort_setinput;
	mlrunmodel = mlort_run;
	mlgetoutput = mlort_getoutput;
}
