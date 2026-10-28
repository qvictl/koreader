// Test-only FreeType face destruction observer for the Linux emulator benchmark.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct entry { FT_Face face; char *path; FT_Long index; };
static struct entry entries[4096];
static int made, dropped, live, peak;
static int explicit_drops, internal_drops, library_cleanup;

static void finalized(void *object) {
    for (int i = 0; i < 4096; ++i) {
        if (entries[i].face == object) {
            free(entries[i].path);
            entries[i].face = NULL;
            ++dropped;
            --live;
            if (library_cleanup) ++internal_drops; else ++explicit_drops;
            return;
        }
    }
    abort();
}

static void record_face(FT_Face face, const char *path, FT_Long index) {
    for (int i = 0; i < 4096; ++i) {
        if (!entries[i].face) {
            entries[i] = (struct entry){face, strdup(path), index};
            if (face->generic.finalizer) abort();
            face->generic.finalizer = finalized;
            ++made;
            if (++live > peak) peak = live;
            return;
        }
    }
    abort();
}

FT_Error FT_New_Face(FT_Library library, const char *path, FT_Long index, FT_Face *face) {
    static FT_Error (*original)(FT_Library, const char *, FT_Long, FT_Face *);
    if (!original) original = dlsym(RTLD_NEXT, "FT_New_Face");
    FT_Error result = original(library, path, index, face);
    if (!result) record_face(*face, path, index);
    return result;
}

FT_Error FT_New_Memory_Face(FT_Library library, const FT_Byte *data, FT_Long length,
                          FT_Long index, FT_Face *face) {
    static FT_Error (*original)(FT_Library, const FT_Byte *, FT_Long, FT_Long, FT_Face *);
    if (!original) original = dlsym(RTLD_NEXT, "FT_New_Memory_Face");
    FT_Error result = original(library, data, length, index, face);
    if (!result) record_face(*face, "embedded", index);
    return result;
}

FT_Error FT_Done_FreeType(FT_Library library) {
    static FT_Error (*original)(FT_Library);
    if (!original) original = dlsym(RTLD_NEXT, "FT_Done_FreeType");
    ++library_cleanup;
    FT_Error result = original(library);
    --library_cleanup;
    return result;
}

int font_probe_explicit(void) { return explicit_drops; }
int font_probe_internal(void) { return internal_drops; }

int font_probe_live(void) { return live; }
int font_probe_made(void) { return made; }
int font_probe_dropped(void) { return dropped; }
int font_probe_peak(void) { return peak; }

void font_probe_snapshot(const char *stage) {
    const char *path = getenv("FONT_PROBE_LOG");
    if (!path) return;
    FILE *file = fopen(path, "a");
    if (!file) abort();
    fprintf(file, "summary\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", stage, made, dropped, live, peak, explicit_drops, internal_drops);
    for (int i = 0; i < 4096; ++i) {
        if (entries[i].face) {
            FT_Face face = entries[i].face;
            fprintf(file, "face\t%s\t%s\t%ld\t%d\n", stage, entries[i].path,
                    entries[i].index, face->size ? face->size->metrics.y_ppem : 0);
        }
    }
    fclose(file);
}
