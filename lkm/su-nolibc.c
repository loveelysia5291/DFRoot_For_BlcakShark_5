/*
 * su-nolibc.c — minimal setuid-root su for DFRoot 4.19, NO LIBC.
 *
 * Pure aarch64 syscalls, fully static (no interpreter, no dynamic libs),
 * ~1KB. The LKM's usermode helper (root context) copies it to
 * /data/local/tmp/su and chmods 4755 (setuid root). Any shell user can
 * then exec it and directly become root — no magiskd, nothing else.
 * SELinux is already permissive (DFRoot), so domain checks don't block.
 *
 * Build:
 *   aarch64-linux-gnu-gcc -nostdlib -static -fno-builtin \
 *       -fno-stack-protector -Os -Wl,-e,_start -o su-setuid su-nolibc.c
 *
 * arm64 syscall numbers (Linux 4.19 arm64):
 *   setgid=144 setuid=146 execve=221 exit=93
 */
typedef unsigned long ulong;

static ulong sys3(ulong n, ulong a0, ulong a1, ulong a2)
{
    register ulong x8 __asm__("x8") = n;
    register ulong x0 __asm__("x0") = a0;
    register ulong x1 __asm__("x1") = a1;
    register ulong x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

void _start(long argc, char **argv)
{
    static const char sh_path[] = "/system/bin/sh";
    static const char dash_c[] = "-c";
    static const char env0[] = "PATH=/system/bin";
    char *sh_argv[4];
    char *envp[2];

    sys3(144, 0, 0, 0);          /* setgid(0) */
    sys3(146, 0, 0, 0);          /* setuid(0) -> euid 0 */

    sh_argv[0] = (char *)sh_path;
    if (argc >= 3 && argv[1] && argv[1][0] == '-' && argv[1][1] == 'c' &&
        argv[1][2] == 0) {
        sh_argv[1] = (char *)dash_c;
        sh_argv[2] = argv[2];
        sh_argv[3] = 0;
    } else {
        sh_argv[1] = 0;
    }
    envp[0] = (char *)env0;
    envp[1] = 0;

    sys3(221, (ulong)sh_path, (ulong)sh_argv, (ulong)envp); /* execve */
    sys3(93, 1, 0, 0);          /* exit(1) if exec failed */
    /* unreachable */
}
