/*
 * su-client-nolibc.c — DFRoot su client, NO LIBC, fully static (~2KB).
 *
 * This is NOT a setuid binary (works even if /data is mounted nosuid).
 * It opens the LKM-provided procfs node /proc/dfroot_su and writes to it;
 * the kernel write handler replaces THIS process's creds with root creds
 * (prepare_kernel_cred/commit_creds). Then it execs /system/bin/sh, which
 * inherits the now-root creds. This is the classic KernelSU-style
 * userspace->kernel escalation, minimal version.
 *
 * Build:
 *   aarch64-linux-gnu-gcc -nostdlib -static -fno-builtin \
 *       -fno-stack-protector -Os -Wl,-e,_start -o su-client su-client-nolibc.c
 *
 * arm64 syscalls: openat=56 write=64 close=57 execve=221 exit=93
 * AT_FDCWD = -100, O_WRONLY = 1
 */
typedef unsigned long ulong;

static ulong sys4(ulong n, ulong a0, ulong a1, ulong a2, ulong a3)
{
    register ulong x8 __asm__("x8") = n;
    register ulong x0 __asm__("x0") = a0;
    register ulong x1 __asm__("x1") = a1;
    register ulong x2 __asm__("x2") = a2;
    register ulong x3 __asm__("x3") = a3;
    __asm__ volatile("svc #0" : "+r"(x0)
                 : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

static char cmd_buf[1024];

/* Join argv[start..argc-1] with single spaces (rebuilds the command when
 * the Windows adb client stripped the quotes and split it into args). */
static char *join_args(char **argv, int start, long argc)
{
    int pos = 0;
    int i;
    for (i = start; i < argc; i++) {
        const char *a = argv[i];
        if (i > start && pos < (int)sizeof(cmd_buf) - 1)
            cmd_buf[pos++] = ' ';
        while (*a && pos < (int)sizeof(cmd_buf) - 1)
            cmd_buf[pos++] = *a++;
    }
    cmd_buf[pos] = 0;
    return cmd_buf;
}

/* Called from start.S with correct argc/argv (x0/x1). */
void su_main(long argc, char **argv)
{
    static const char proc_path[] = "/proc/dfroot_su";
    static const char sh_path[] = "/system/bin/sh";
    static const char dash_c[] = "-c";
    static const char env0[] = "PATH=/system/bin";
    char *sh_argv[4];
    char *envp[2];
    ulong fd;

    /* Trigger the kernel root grant for this process. */
    fd = sys4(56, (ulong)-100, (ulong)proc_path, 1, 0);  /* openat */
    if ((long)fd >= 0) {
        sys4(64, fd, (ulong)"1", 1, 0);                  /* write */
        sys4(57, fd, 0, 0, 0);                           /* close */
    }

    /* Build root shell args. */
    sh_argv[0] = (char *)sh_path;
    if (argc >= 3 && argv[1] && argv[1][0] == '-' && argv[1][1] == 'c' &&
        argv[1][2] == 0) {
        sh_argv[1] = (char *)dash_c;
        sh_argv[2] = (argc == 3) ? argv[2]
                                 : join_args(argv, 2, argc);
        sh_argv[3] = 0;
    } else {
        sh_argv[1] = 0;
    }
    envp[0] = (char *)env0;
    envp[1] = 0;

    sys4(221, (ulong)sh_path, (ulong)sh_argv, (ulong)envp, 0); /* execve */
    sys4(93, 1, 0, 0, 0);                                      /* exit(1) */
}
