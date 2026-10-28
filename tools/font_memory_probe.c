// Test-only FreeType face destruction observer for the Linux emulator benchmark.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

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
    fprintf(stderr, "font_memory_probe: untracked finalizer object %p\n", object);
    abort();
}

static void record_face(FT_Face face, const char *path, FT_Long index) {
    for (int i = 0; i < 4096; ++i) {
        if (!entries[i].face) {
            entries[i] = (struct entry){face, strdup(path), index};
            if (face->generic.finalizer) {
                fprintf(stderr, "font_memory_probe: face %p already has a finalizer\n", (void *)face);
                abort();
            }
            face->generic.finalizer = finalized;
            ++made;
            if (++live > peak) peak = live;
            return;
        }
    }
    fprintf(stderr, "font_memory_probe: entries full (made=%d live=%d peak=%d)\n", made, live, peak);
    abort();
}

static void *resolve_next(const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);
    if (!symbol) {
        fprintf(stderr, "font_memory_probe: cannot resolve %s: %s\n", name, dlerror());
        abort();
    }
    const char *expected = getenv("FONT_PROBE_FREETYPE");
    Dl_info info;
    char actual_path[PATH_MAX], expected_path[PATH_MAX];
    if (!expected || !dladdr(symbol, &info) || !realpath(info.dli_fname, actual_path)
            || !realpath(expected, expected_path) || strcmp(actual_path, expected_path)) {
        fprintf(stderr, "font_memory_probe: %s is not bound to the expected runtime FreeType %s\n",
                name, expected ? expected : "(unset)");
        abort();
    }
    return symbol;
}

FT_Error FT_New_Face(FT_Library library, const char *path, FT_Long index, FT_Face *face) {
    static FT_Error (*original)(FT_Library, const char *, FT_Long, FT_Face *);
    if (!original) original = resolve_next("FT_New_Face");
    FT_Error result = original(library, path, index, face);
    if (!result) record_face(*face, path, index);
    return result;
}

FT_Error FT_New_Memory_Face(FT_Library library, const FT_Byte *data, FT_Long length,
                          FT_Long index, FT_Face *face) {
    static FT_Error (*original)(FT_Library, const FT_Byte *, FT_Long, FT_Long, FT_Face *);
    if (!original) original = resolve_next("FT_New_Memory_Face");
    FT_Error result = original(library, data, length, index, face);
    if (!result) record_face(*face, "embedded", index);
    return result;
}

FT_Error FT_Done_FreeType(FT_Library library) {
    static FT_Error (*original)(FT_Library);
    if (!original) original = resolve_next("FT_Done_FreeType");
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

const char *font_probe_snapshot(const char *stage) {
    static char *snapshot;
    size_t size;
    free(snapshot);
    snapshot = NULL;
    FILE *file = open_memstream(&snapshot, &size);
    if (!file) { perror("font_memory_probe: open_memstream"); abort(); }
    fprintf(file, "summary\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", stage, made, dropped, live, peak, explicit_drops, internal_drops);
    for (int i = 0; i < 4096; ++i) {
        if (entries[i].face) {
            FT_Face face = entries[i].face;
            fprintf(file, "face\t%s\t%s\t%ld\t%d\n", stage, entries[i].path,
                    entries[i].index, face->size ? face->size->metrics.y_ppem : 0);
        }
    }
    if (fclose(file) != 0 || !snapshot) {
        fprintf(stderr, "font_memory_probe: cannot build snapshot for %s\n", stage);
        abort();
    }
    return snapshot;
}
