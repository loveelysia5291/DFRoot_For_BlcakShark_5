#include <syscall.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

// argv[0] = program name
// argv[1] = file offset (decimal string)
// argv[2] = file path
// argv[3] = optional mode:
//           "r"  — read mode: write 16 bytes of file content to fd 0 (OUT_FD)
//           "b"  — batch mode: control records on fd 3, packet data on fd 1,
//                  completion byte on fd 4
//           none — splice mode: splice 16 bytes of the file page into fd 1
//
// Batch records (all integers little-endian u64):
//   'R' offset length            -> write `length` file bytes at `offset` to fd 1
//   'W' offset                   -> splice the 16-byte file page at `offset` to
//                                   fd 1 (after the parent's 24-byte header) and
//                                   write one ack byte to fd 4
//
// Batch mode keeps a single crash_dump64 process alive for a whole patch/restore
// operation, so a 13 KiB vendor-library write costs four execve() calls instead
// of ~1650. The one-shot modes are kept as fallbacks.

#define OUT_FD  0
#define PIPE_FD 1
#define CTRL_FD 3
#define ACK_FD  4

__attribute__((naked)) static long mysyscall1(unsigned long arg0, unsigned long nr) {
    asm volatile("mov x8, x1\nsvc 0\nret\n":::"x8");
}

__attribute__((naked)) static long mysyscall3(
    unsigned long a0, unsigned long a1, unsigned long a2, unsigned long nr) {
    asm volatile("mov x8, x3\nsvc 0\nret\n":::"x8");
}

__attribute__((naked)) static long mysyscall6(
    unsigned long a0, unsigned long a1, unsigned long a2,
    unsigned long a3, unsigned long a4, unsigned long a5, unsigned long nr) {
    asm volatile("mov x8, x6\nsvc 0\nret\n":::"x8");
}

static unsigned long parse_int(char *s) {
    unsigned long val = 0;
    while (*s) { val = val * 10 + (unsigned long)(*s - '0'); s++; }
    return val;
}

static int streq(const char *a, const char *b) {
    while (*a && *b && *a == *b) { a++; b++; }
    return *a == *b;
}

static int read_full(int fd, unsigned char *buf, unsigned long n) {
    unsigned long got = 0;
    while (got < n) {
        long r = mysyscall3((unsigned long)fd, (unsigned long)(buf + got),
                            n - got, __NR_read);
        if (r <= 0) return -1;
        got += (unsigned long)r;
    }
    return 0;
}

static int write_full(int fd, const unsigned char *buf, unsigned long n) {
    unsigned long done = 0;
    while (done < n) {
        long r = mysyscall3((unsigned long)fd, (unsigned long)(buf + done),
                            n - done, __NR_write);
        if (r <= 0) return -1;
        done += (unsigned long)r;
    }
    return 0;
}

static void batch_loop(int file_fd) {
    unsigned char rec[33];
    for (;;) {
        /* One byte first: a closed control pipe (parent gone) exits cleanly. */
        if (read_full(CTRL_FD, rec, 1) != 0)
            mysyscall1(0, __NR_exit_group);
        if (rec[0] == 'R') {
            if (read_full(CTRL_FD, rec + 1, 16) != 0)
                mysyscall1(1, __NR_exit_group);
            unsigned long off = *(unsigned long *)(rec + 1);
            unsigned long len = *(unsigned long *)(rec + 9);
            mysyscall3((unsigned long)file_fd, off, SEEK_SET, __NR_lseek);
            while (len) {
                unsigned char tmp[512];
                unsigned long chunk = len < sizeof(tmp) ? len : sizeof(tmp);
                long n = mysyscall3((unsigned long)file_fd, (unsigned long)tmp,
                                    chunk, __NR_read);
                if (n <= 0) mysyscall1(1, __NR_exit_group);
                if (write_full(PIPE_FD, tmp, (unsigned long)n) != 0)
                    mysyscall1(1, __NR_exit_group);
                len -= (unsigned long)n;
            }
        } else if (rec[0] == 'W') {
            /* The parent has already vmspliced the 24-byte ESP header into the
             * pipe; append the 16-byte file page at `off`, exactly like the
             * proven one-shot splice mode. */
            if (read_full(CTRL_FD, rec + 1, 8) != 0)
                mysyscall1(1, __NR_exit_group);
            unsigned long off = *(unsigned long *)(rec + 1);
            long ret = mysyscall6((unsigned long)file_fd, (unsigned long)&off,
                                  PIPE_FD, 0, 16, SPLICE_F_MOVE, __NR_splice);
            if (ret != 16) mysyscall1(1, __NR_exit_group);
            unsigned char ack = 1;
            if (mysyscall3(ACK_FD, (unsigned long)&ack, 1, __NR_write) != 1)
                mysyscall1(1, __NR_exit_group);
        } else {
            mysyscall1(1, __NR_exit_group);
        }
    }
}

void start_c(void *argblock) {
    int argc = (int)*(long *)argblock;
    char **argv = (char **)argblock + 1;

    if (argc < 3 || argc > 4)
        mysyscall1(1, __NR_exit_group);

    off64_t off = (off64_t)parse_int(argv[1]);
    char *target = argv[2];
    char *mode = (argc >= 4) ? argv[3] : (char *)0;

    int file_fd = (int)mysyscall3(
        (unsigned long)AT_FDCWD,
        (unsigned long)target,
        (unsigned long)O_RDONLY,
        __NR_openat);
    if (file_fd < 0)
        mysyscall1(1, __NR_exit_group);

    if (mode && streq(mode, "r")) {
        /* Read mode: lseek to offset, read 16 bytes, write to OUT_FD */
        /* Exit codes: 0=ok, 1=read<16, 2=write<16, 3=OUT_FD not a pipe (fd sanitized) */
        mysyscall3((unsigned long)file_fd, (unsigned long)off, SEEK_SET, __NR_lseek);
        unsigned char buf[16];
        long n = mysyscall3((unsigned long)file_fd, (unsigned long)buf, 16, __NR_read);
        if (n != 16)
            mysyscall1(1, __NR_exit_group);
        if (mysyscall3(OUT_FD, 0, SEEK_CUR, __NR_lseek) != (long)-29L) /* ESPIPE: fd is a pipe */
            mysyscall1(3, __NR_exit_group);
        long w = mysyscall3(OUT_FD, (unsigned long)buf, 16, __NR_write);
        mysyscall1((unsigned long)(w == 16 ? 0 : 2), __NR_exit_group);
    }

    if (mode && streq(mode, "b"))
        batch_loop(file_fd);

    /* Splice mode: splice 16-byte page into PIPE_FD */
    long ret = mysyscall6(
        (unsigned long)file_fd,
        (unsigned long)&off,
        PIPE_FD,
        (unsigned long)NULL,
        16,
        SPLICE_F_MOVE,
        __NR_splice);
    mysyscall1((unsigned long)(ret == 16 ? 0 : 1), __NR_exit_group);
}

__attribute__((naked)) void _start() {
    asm(".extern start_c\nmov x0, sp\nb start_c\n");
}
