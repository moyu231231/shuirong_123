#import "fishhook.h"
#import <mach-o/dyld.h>
#import <string.h>
#import <stdatomic.h>

/*
 * ACE/tersafe 会扫 _dyld_image_count / _dyld_get_image_name。
 * constructor(101) 尽量早藏镜像。
 * fishhook 对符号表名去前缀 '_' 再比，故这里填 "_dyld_..."。
 */

static atomic_int g_hide = 1;

static const char *g_hide_needles[] = {
    "ApolloNetService",
    "ShuiyongMem",
    NULL
};

static int path_is_ours(const char *path) {
    if (!path) return 0;
    for (int i = 0; g_hide_needles[i]; i++) {
        if (strstr(path, g_hide_needles[i])) return 1;
    }
    return 0;
}

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

static uint32_t map_visible_index(uint32_t visible) {
    if (!orig_dyld_image_count || !orig_dyld_get_image_name) return visible;
    uint32_t seen = 0;
    uint32_t total = orig_dyld_image_count();
    for (uint32_t real = 0; real < total; real++) {
        const char *n = orig_dyld_get_image_name(real);
        if (path_is_ours(n)) continue;
        if (seen == visible) return real;
        seen++;
    }
    return total;
}

static uint32_t hooked_dyld_image_count(void) {
    if (!atomic_load(&g_hide) || !orig_dyld_image_count || !orig_dyld_get_image_name)
        return orig_dyld_image_count ? orig_dyld_image_count() : 0;
    uint32_t total = orig_dyld_image_count();
    uint32_t hide = 0;
    for (uint32_t i = 0; i < total; i++) {
        if (path_is_ours(orig_dyld_get_image_name(i))) hide++;
    }
    return total > hide ? total - hide : 0;
}

static const char *hooked_dyld_get_image_name(uint32_t image_index) {
    if (!atomic_load(&g_hide) || !orig_dyld_get_image_name)
        return orig_dyld_get_image_name ? orig_dyld_get_image_name(image_index) : NULL;
    return orig_dyld_get_image_name(map_visible_index(image_index));
}

static const struct mach_header *hooked_dyld_get_image_header(uint32_t image_index) {
    if (!atomic_load(&g_hide) || !orig_dyld_get_image_header)
        return orig_dyld_get_image_header ? orig_dyld_get_image_header(image_index) : NULL;
    return orig_dyld_get_image_header(map_visible_index(image_index));
}

static intptr_t hooked_dyld_get_image_vmaddr_slide(uint32_t image_index) {
    if (!atomic_load(&g_hide) || !orig_dyld_get_image_vmaddr_slide)
        return orig_dyld_get_image_vmaddr_slide ? orig_dyld_get_image_vmaddr_slide(image_index) : 0;
    return orig_dyld_get_image_vmaddr_slide(map_visible_index(image_index));
}

__attribute__((constructor(101)))
static void sy_hide_dyld_ctor(void) {
    rebind_symbols((struct rebinding[4]){
        { "_dyld_image_count", (void *)hooked_dyld_image_count, (void **)&orig_dyld_image_count },
        { "_dyld_get_image_name", (void *)hooked_dyld_get_image_name, (void **)&orig_dyld_get_image_name },
        { "_dyld_get_image_header", (void *)hooked_dyld_get_image_header, (void **)&orig_dyld_get_image_header },
        { "_dyld_get_image_vmaddr_slide", (void *)hooked_dyld_get_image_vmaddr_slide, (void **)&orig_dyld_get_image_vmaddr_slide },
    }, 4);
}
