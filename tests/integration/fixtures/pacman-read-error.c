/* Fixture-only stdio read error for the real libalpm local file-list reader. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct input_cookie {
    FILE *input;
    size_t remaining;
    char *path;
    int drift;
    int rebind;
};

static ssize_t read_input(void *opaque, char *buffer, size_t size)
{
    struct input_cookie *cookie = opaque;
    if (cookie->remaining == 0) {
        errno = EIO;
        return -1; /* glibc sets the stream's error indicator. */
    }
    if (size > cookie->remaining) {
        size = cookie->remaining;
    }
    size_t count = fread(buffer, 1, size, cookie->input);
    cookie->remaining -= count;
    if (count == 0 && ferror(cookie->input)) {
        return -1;
    }
    return (ssize_t)count;
}

static int close_input(void *opaque)
{
    struct input_cookie *cookie = opaque;
    int result = fclose(cookie->input);
    if (cookie->drift) {
        FILE *output = fopen(cookie->path, "a");
        if (output == NULL) {
            result = EOF;
        } else {
            int written = fputc('\n', output);
            int closed = fclose(output);
            if (written == EOF || closed != 0) {
                result = EOF;
            }
        }
    }
    if (cookie->rebind) {
        if (unlink("/var/lib/pacman/local") != 0 ||
            symlink("/work/local-b", "/var/lib/pacman/local") != 0) {
            result = EOF;
        }
    }
    free(cookie->path);
    free(cookie);
    return result;
}

static FILE *open_input(const char *path, const char *mode, const char *symbol)
{
    FILE *(*original)(const char *, const char *) = dlsym(RTLD_NEXT, symbol);
    if (original == NULL) {
        errno = ENOSYS;
        return NULL;
    }
    FILE *input = original(path, mode);
    if (input == NULL || mode[0] != 'r' ||
        strcmp(program_invocation_short_name, "pacman") != 0 ||
        strcmp(path, "/var/lib/pacman/local/contract-kernel-1-1/files") != 0 ||
        access("/fixtures/identity", F_OK) != 0 ||
        (getenv("OMASECBOOT_TEST_READ_ERROR") == NULL &&
         getenv("OMASECBOOT_TEST_CATALOG_DRIFT") == NULL &&
         getenv("OMASECBOOT_TEST_LOCAL_REBIND") == NULL)) {
        return input;
    }
    struct input_cookie *cookie = calloc(1, sizeof(*cookie));
    if (cookie == NULL) {
        fclose(input);
        return NULL;
    }
    cookie->input = input;
    cookie->path = strdup(path);
    if (cookie->path == NULL) {
        fclose(input);
        free(cookie);
        return NULL;
    }
    cookie->drift = getenv("OMASECBOOT_TEST_CATALOG_DRIFT") != NULL;
    cookie->rebind = getenv("OMASECBOOT_TEST_LOCAL_REBIND") != NULL;
    cookie->remaining = (cookie->drift || cookie->rebind) ? (size_t)-1 : 48;
    cookie_io_functions_t operations = { .read = read_input, .close = close_input };
    FILE *result = fopencookie(cookie, "r", operations);
    if (result == NULL) {
        close_input(cookie);
    }
    return result;
}

FILE *fopen(const char *path, const char *mode)
{
    return open_input(path, mode, "fopen");
}

FILE *fopen64(const char *path, const char *mode)
{
    return open_input(path, mode, "fopen64");
}
