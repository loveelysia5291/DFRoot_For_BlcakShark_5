/*
 * su-setuid.c — minimal setuid-root su for DFRoot 4.19 (blackshark 5)
 *
 * The LKM's usermode helper (root context) copies this binary to
 * /data/local/tmp/su and chmods it 4755 (setuid root). Any shell user
 * (adb shell, uid 2000) can then exec it and get a root shell directly —
 * no magiskd, no socket, nothing else required. SELinux is already
 * permissive (DFRoot), so the domain transition is not enforced.
 *
 * Build (static, no libc/loader dependency):
 *   aarch64-linux-gnu-gcc -static -Os -o su-setuid su.c
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    /* Drop nothing: become root (setuid bit already raised root:4755). */
    if (setgid(0) != 0 || setuid(0) != 0) {
        perror("setuid");
        return 1;
    }
    /* Reset supplementary groups so we are a clean root. */
    if (setgroups(0, NULL) != 0) {
        perror("setgroups");
        return 1;
    }
    /* Usage: su        -> interactive root shell
     *        su -c CMD -> run CMD as root */
    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        execl("/system/bin/sh", "sh", "-c", argv[2], (char *)NULL);
    } else {
        execl("/system/bin/sh", "sh", (char *)NULL);
    }
    perror("execl");
    return 1;
}
