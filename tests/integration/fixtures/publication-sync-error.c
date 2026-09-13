#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Only loaded inside the Java fixture namespace, with its explicit mode file. */
static int fail_sync(int fd) {
    char descriptor[64], path[4096], mode[32] = {0};
    snprintf(descriptor, sizeof(descriptor), "/proc/self/fd/%d", fd);
    ssize_t length = readlink(descriptor, path, sizeof(path) - 1);
    if (length < 0 || (size_t)length >= sizeof(path) - 1) return 0;
    path[length] = '\0';
    if (strncmp(path, "/work/publication/", 18) != 0 || !strstr(path, "/boot")) return 0;
    FILE *file = fopen("/work/publication-sync-fault", "re");
    if (!file) return 0;
    size_t count = fread(mode, 1, sizeof(mode) - 1, file);
    int failed = ferror(file);
    fclose(file);
    if (failed || count == 0) return 0;
    if (strcmp(mode, "crash-directory") == 0 && strcmp(path + strlen(path) - 5, "/boot") == 0) _exit(72);
    return (strcmp(mode, "stage") == 0 && strstr(path, ".stage") != NULL)
        || (strcmp(mode, "target") == 0 && strcmp(path + strlen(path) - 14, "/boot/resource") == 0)
        || (strcmp(mode, "directory") == 0 && (strcmp(path + strlen(path) - 5, "/boot") == 0
            || strcmp(path + strlen(path) - 13, "/boot/retired") == 0));
}

ssize_t read(int fd, void *buffer, size_t count) {
    static ssize_t (*real_call)(int, void *, size_t);
    static int retained_reads;
    static _Thread_local int observing;
    if (!real_call) real_call = dlsym(RTLD_NEXT, "read");
    ssize_t result = real_call(fd, buffer, count);
    if (result <= 0 || observing) return result;
    observing = 1;
    char descriptor[64], path[4096], mode[32] = {0};
    snprintf(descriptor, sizeof(descriptor), "/proc/self/fd/%d", fd);
    ssize_t length = readlink(descriptor, path, sizeof(path) - 1);
    if (length > 0 && (size_t)length < sizeof(path) - 1) {
        path[length] = '\0';
        if (strcmp(path, "/work/publication/retained-read-race/retained/resource") == 0) {
            FILE *file = fopen("/work/publication-sync-fault", "re");
            if (file) { (void)fread(mode, 1, sizeof(mode) - 1, file); fclose(file); }
            if (strcmp(mode, "target-read") == 0 && ++retained_reads == 2) {
                file = fopen("/work/publication/retained-read-race/boot/resource", "we");
                if (file) { fputs("third state", file); fclose(file); }
            }
        }
    }
    observing = 0;
    return result;
}

int fsync(int fd) {
    static int (*real_call)(int);
    if (!real_call) real_call = dlsym(RTLD_NEXT, "fsync");
    if (fail_sync(fd)) { errno = EIO; return -1; }
    return real_call(fd);
}

int fdatasync(int fd) {
    static int (*real_call)(int);
    if (!real_call) real_call = dlsym(RTLD_NEXT, "fdatasync");
    if (fail_sync(fd)) { errno = EIO; return -1; }
    return real_call(fd);
}
