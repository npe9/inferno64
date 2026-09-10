#include "freetype/freetype.h"
#include "kernel.h"
#include "freetype.h"

static char* fterrstr(int);
static char* facefrommem(void*, vlong, int, FTface*, FTfaceinfo*);

char*
ftnewface(char *path, int index, FTface *f, FTfaceinfo *finfo)
{
	Dir *d;
	uchar *data;
	int fd;
	vlong len, tot;
	s32 n;

	/*
	 * Read the file here rather than let FreeType keep a descriptor open
	 * on it for the life of the face.  A Face is a garbage-collected Dis
	 * value, so FT_Done_Face runs whenever the collector reaches it, in
	 * whichever process happens to be running then - and the close
	 * underneath it is kclose(), which acts on *that* process's file
	 * descriptor table.  When the process that opened the font has since
	 * exited that faults in kfgrpclose(); when it has not, it closes
	 * whatever unrelated file sits at the same number.  Neither is a
	 * thing to leave in place, and a font is small.
	 */
	fd = kopen(path, OREAD);
	if (fd < 0)
		return "cannot open font file";
	d = kdirfstat(fd);
	if (d == nil) {
		kclose(fd);
		return "cannot stat font file";
	}
	len = d->length;
	free(d);
	if (len <= 0) {
		kclose(fd);
		return "empty font file";
	}
	data = malloc(len);
	if (data == nil) {
		kclose(fd);
		return "out of memory reading font file";
	}
	for (tot = 0; tot < len; tot += n) {
		n = kread(fd, data+tot, len-tot);
		if (n <= 0)
			break;
	}
	kclose(fd);
	if (tot != len) {
		free(data);
		return "short read of font file";
	}

	return facefrommem(data, len, index, f, finfo);
}

/*
 * Build a face over data, which becomes the face's own: FT_New_Memory_Face
 * keeps the pointer rather than copying, so it must stay live until
 * ftdoneface(), which frees it.  On failure it is freed here.
 */
static char*
facefrommem(void *data, vlong len, int index, FTface *f, FTfaceinfo *finfo)
{
	FT_Library ft_lib;
	FT_Face ft_face;
	char *err;

	err = fterrstr(FT_Init_FreeType(&ft_lib));
	if (err != nil) {
		free(data);
		return err;
	}

	err = fterrstr(FT_New_Memory_Face(ft_lib, data, len, index, &ft_face));
	if (err != nil) {
		FT_Done_FreeType(ft_lib);
		free(data);
		return err;
	}

	f->ft_lib = ft_lib;
	f->ft_face = ft_face;
	f->ft_data = data;
	finfo->nfaces = ft_face->num_faces;
	finfo->index = ft_face->face_index;
	finfo->style = ft_face->style_flags;
	finfo->height = (FT_MulFix(ft_face->height, ft_face->size->metrics.y_scale)+32)/64;
	finfo->ascent = (FT_MulFix(ft_face->ascender, ft_face->size->metrics.y_scale)+32)/64;
	finfo->familyname = ft_face->family_name;
	finfo->stylename = ft_face->style_name;
	return nil;
}

/*
 * The caller keeps buf, so take a copy: the face outlives this call and
 * FT_New_Memory_Face does not copy for us.
 */
char*
ftloadmemface(void *buf, int nbytes, int index, FTface *f, FTfaceinfo *finfo)
{
	void *data;

	if (buf == nil || nbytes <= 0)
		return "empty font image";
	data = malloc(nbytes);
	if (data == nil)
		return "out of memory copying font image";
	memmove(data, buf, nbytes);
	return facefrommem(data, nbytes, index, f, finfo);
}

char*
ftsetcharsize(FTface f, int pt, int hdpi, int vdpi, FTfaceinfo *finfo)
{
	FT_Face ft_face = f.ft_face;
	char *err;

	err = fterrstr(FT_Set_Char_Size(ft_face, 0, pt, hdpi, vdpi));
	if (err != nil)
		return err;
	finfo->height = (FT_MulFix(ft_face->height, ft_face->size->metrics.y_scale)+32)/64;
	finfo->ascent = (FT_MulFix(ft_face->ascender, ft_face->size->metrics.y_scale)+32)/64;
	return nil;
}

void
ftsettransform(FTface f, FTmatrix *m, FTvector *v)
{
	/* FTMatrix and FTVector are compatible with FT_Matrix and FT_Vector */
	FT_Set_Transform(f.ft_face, (FT_Matrix*)m, (FT_Vector*)v);
}

int
fthaschar(FTface f, int c)
{
	return FT_Get_Char_Index(f.ft_face, c) != 0;
}

char*
ftloadglyph(FTface f, int ix, FTglyph *g)
{
	FT_Face ft_face = f.ft_face;
	FT_GlyphSlot ft_glyph;
	char *err;

	ix = FT_Get_Char_Index(ft_face, ix);
	err = fterrstr(FT_Load_Glyph(ft_face, ix, FT_LOAD_NO_BITMAP|FT_LOAD_RENDER|FT_LOAD_CROP_BITMAP));
	if (err != nil)
		return err;

	ft_glyph = ft_face->glyph;
	g->top = ft_glyph->bitmap_top;
	g->left = ft_glyph->bitmap_left;
	g->height = ft_glyph->bitmap.rows;
	g->width = ft_glyph->bitmap.width;
	g->advx = ft_glyph->advance.x;
	g->advy = ft_glyph->advance.y;
	g->bpr = ft_glyph->bitmap.pitch;
	g->bitmap = ft_glyph->bitmap.buffer;
	return nil;
}

void
ftdoneface(FTface f)
{
	if (f.ft_face != nil)
		FT_Done_Face(f.ft_face);
	if (f.ft_lib != nil)
		FT_Done_FreeType(f.ft_lib);
	if (f.ft_data != nil)
		free(f.ft_data);	/* FT_New_Memory_Face does not copy it */
}

/*
 * get the freetype error strings
 */

typedef struct FTerr FTerr;
struct FTerr {
	int		code;
	char*	text;
};

#define FT_NOERRORDEF_(l,c,t)
#define FT_ERRORDEF_(l,c,t)	c,t,

static FTerr fterrs[] = {
#include "freetype/fterrdef.h"
	-1, "",
};

static char*
fterrstr(int code)
{
	int i;
	if (code == 0)
		return nil;
	for (i = 0; fterrs[i].code > 0; i++) {
		if (fterrs[i].code == code)
			return fterrs[i].text;
	}
	return "unknown FreeType error";
}

