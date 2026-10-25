#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kmod.h>
#include <linux/umh.h>
#include <linux/module.h>
#include <linux/namei.h>
#include <linux/ptrace.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/fs.h>
#include <linux/proc_fs.h>
#include <linux/cred.h>
#include <linux/uaccess.h>
#include <asm/cpufeature.h>
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("DFRoot LKM");

typedef unsigned long (*kallsyms_lookup_name_t)(const char *name);
typedef unsigned long (*module_kallsyms_lookup_name_t)(const char *name);
typedef int  (*kern_path_t)(const char *, unsigned int, struct path *);
typedef int  (*invalidate_t)(struct address_space *);
typedef void (*path_put_t)(const struct path *);
typedef int  (*insn_patch_t)(void *addrs[], u32 insns[], int cnt);

/* __nocfi was introduced after 4.19 (CFI support); define it away for 4.19 kernels. */
#ifndef __nocfi
#define __nocfi
#endif

/*
 * KASLR: the device kernel is built with CONFIG_RANDOMIZE_BASE and boots
 * with a randomized text base (kimage_voffset). Static addresses from the
 * device vmlinux are link-time values; the module loader relocates exported
 * symbols (printk here) to their runtime addresses, so we derive the slide
 * and apply it to every static address. If the kernel boots without a
 * kaslr seed the slide is 0 and behaviour is unchanged.
 */
extern int printk(const char *fmt, ...);
#define DEV_PRINTK_LINK 0xffffff8008154760UL  /* printk in device System.map */

static unsigned long kaslr_slide(void)
{
    return (unsigned long)printk - DEV_PRINTK_LINK;
}

static insn_patch_t insn_patch_text;

/*
 * Device: Black Shark 5 (SHARK PAR-H0), Android 12,
 * kernel 4.19.113-perf-g957c7e270183 (2022-06-20 build).
 * The stock kernel is built with CONFIG_KPROBES=n and does not export
 * kallsyms_lookup_name, so symbol addresses are resolved statically
 * from the device vmlinux (fixed for this firmware).
 */
static unsigned long __nocfi resolve_sym(const char *name)
{
    if (!strcmp(name, "aarch64_insn_patch_text"))
        return 0xffffff8008093b70UL + kaslr_slide();
    if (!strcmp(name, "module_kallsyms_lookup_name"))
        return 0xffffff800819c758UL + kaslr_slide();
    if (!strcmp(name, "kern_path"))
        return 0xffffff80082ca7f8UL + kaslr_slide();
    if (!strcmp(name, "invalidate_inode_pages2"))
        return 0xffffff8008251020UL + kaslr_slide();
    if (!strcmp(name, "path_put"))
        return 0xffffff80082c9f98UL + kaslr_slide();
    if (!strcmp(name, "selinux_state"))
        return 0xffffff800bb81000UL + kaslr_slide();
    if (!strcmp(name, "avc_has_perm"))
        return 0xffffff80084a5190UL + kaslr_slide();
    if (!strcmp(name, "avc_has_perm_noaudit"))
        return 0xffffff80084a5078UL + kaslr_slide();
    if (!strcmp(name, "call_usermodehelper_setup"))
        return 0xffffff80080dfa98UL + kaslr_slide();
    if (!strcmp(name, "call_usermodehelper_exec"))
        return 0xffffff80080dff40UL + kaslr_slide();
    return 0;
}


static __nocfi void patch_fn_ret_zero(void *fn)
{
    void *addrs[3];
    u32 insns[3];

    addrs[0] = fn;
    addrs[1] = (u8 *)fn + 4;
    addrs[2] = (u8 *)fn + 8;

    insns[0] = 0xD503245F;  // BTI C  (valid landing pad, NOP when BTI not enforced)
    insns[1] = 0xD2800000;  // MOV x0, #0
    insns[2] = 0xD65F03C0;  // RET

    if (insn_patch_text(addrs, insns, 3))
        pr_warn("dfroot: patch failed at %px\n", fn);
}

/* --- kernel-side root grant (KernelSU-style procfs node) ------------------ */
static struct proc_dir_entry *g_su_proc_entry;
static bool g_closed;

static ssize_t su_proc_write(struct file *f, const char __user *buf,
                             size_t cnt, loff_t *ppos)
{
    struct cred *newcred;

    /* Every write grants root to the writer. The write buffer is deliberately
     * NOT read: reading user memory would pull in __arch_copy_from_user /
     * get_user's cpu_hwcaps family — exported symbols whose CRCs are not
     * proven against the device kernel. The close is done via su_proc_read
     * (one read -> g_closed), which copies nothing and adds no symbols. */
    if (g_closed)
        return -EACCES;

    newcred = prepare_kernel_cred(NULL);   /* NULL -> init_cred template */
    if (!newcred)
        return -ENOMEM;
    commit_creds(newcred);
    pr_info("dfroot: root granted via /proc/dfroot_su\n");
    return cnt;
}

static ssize_t su_proc_read(struct file *f, char __user *buf, size_t cnt,
                            loff_t *ppos)
{
    /* Close protocol: the app does `cat /proc/dfroot_su >/dev/null` once
     * Magisk is deployed. Reading this node latches g_closed and disables
     * further privilege grants. No data is copied (return EOF), so no new
     * module symbols are introduced. */
    if (!g_closed) {
        g_closed = true;
        pr_info("dfroot: escalation node closed, legacy root disabled\n");
    }
    return 0;
}

static const struct file_operations su_proc_fops = {
    .owner = THIS_MODULE,
    .read = su_proc_read,
    .write = su_proc_write,
};

/* --- kernel-side file copy (no exec, bypasses CONFIG_STATIC_USERMODEHELPER) */
static int kernel_copy_file(const char *src, const char *dst, umode_t mode)
{
    struct file *in, *out;
    loff_t off_in = 0, off_out = 0;
    char kbuf[2048];   /* stack; kernel stack on arm64 is 16K */
    ssize_t r;
    int ret = 0;

    in = filp_open(src, O_RDONLY, 0);
    if (IS_ERR(in))
        return PTR_ERR(in);
    out = filp_open(dst, O_CREAT | O_WRONLY | O_TRUNC, mode);
    if (IS_ERR(out)) {
        ret = PTR_ERR(out);
        goto close_in;
    }
    for (;;) {
        r = kernel_read(in, kbuf, sizeof(kbuf), &off_in);
        if (r < 0) { ret = r; break; }
        if (r == 0) break;
        r = kernel_write(out, kbuf, r, &off_out);
        if (r < 0) { ret = r; break; }
    }
    filp_close(out, NULL);
close_in:
    filp_close(in, NULL);
    return ret;
}

static int __nocfi __init dfroot_init(void)
{
    kallsyms_lookup_name_t get_addr;
    kern_path_t  kern_path_fn;
    invalidate_t invalidate_fn;
    path_put_t   path_put_fn;
    struct path  p;
    bool *selinux_state;
    module_kallsyms_lookup_name_t mkln;
    void *oplus_exe_fn, *oplus_root_fn, *defex_enforce_fn, *defex_umh_fn;

    // Black Shark 5 (4.19): no ksud/manager stack; SELinux permissive only.
    // Symbol finder: static resolution table (see resolve_sym above)
    get_addr = resolve_sym;

    insn_patch_text = (insn_patch_t)get_addr("aarch64_insn_patch_text");
    if (!insn_patch_text) {
        pr_err("dfroot: aarch64_insn_patch_text not found\n");
        return -EINVAL;
    }

    mkln = (module_kallsyms_lookup_name_t)get_addr("module_kallsyms_lookup_name");

    // Invalidate page_cache for crash_dump64
    // NOTE: this can cause issues if a process is currently executing
    //   crash_dump64. We may want to revert to manual restore patching
    kern_path_fn  = (kern_path_t) get_addr("kern_path");
    invalidate_fn = (invalidate_t)get_addr("invalidate_inode_pages2");
    path_put_fn   = (path_put_t)  get_addr("path_put");
    if (!kern_path_fn || !invalidate_fn || !path_put_fn) {
        pr_err("dfroot: cache drop symbols missing\n");
    } else if (kern_path_fn("/apex/com.android.runtime/bin/crash_dump64",
                            LOOKUP_FOLLOW, &p)) {
        pr_err("dfroot: kern_path failed for crash_dump64\n");
    } else {
        invalidate_fn(p.dentry->d_inode->i_mapping);
        path_put_fn(&p);
        pr_info("dfroot: cleared page cache for crash_dump64\n");
    }

    // Disable SELinux
    selinux_state = (bool *)get_addr("selinux_state");
    if (!selinux_state) {
        pr_err("dfroot: selinux_state not found\n");
        return -EINVAL;
    }
    /* DO NOT clear initialized: on DEVELOP trees it sits at [3] and clearing
     * it panics the kernel on the next mount (SELinux behaves as uninitialized
     * and dereferences NULL state). Write only [0..1] (disabled/enforcing on
     * DEVELOP trees) and log the live values so the real layout is visible. */
    WRITE_ONCE(((bool *)selinux_state)[0], false);
    WRITE_ONCE(((bool *)selinux_state)[1], false);
    pr_info("dfroot: selinux_state[0..3]=%d %d %d %d (after write)\n",
            ((bool *)selinux_state)[0], ((bool *)selinux_state)[1],
            ((bool *)selinux_state)[2], ((bool *)selinux_state)[3]);

    // Make kernel logs readable: dmesg_restrict is usually 1 and hides our
    // patch diagnostics. Write 0 via the proc sysctl (kernel-side filp_open).
    {
        struct file *drf = filp_open("/proc/sys/kernel/dmesg_restrict",
                                     O_WRONLY, 0);
        if (!IS_ERR(drf)) {
            loff_t off = 0;
            kernel_write(drf, "0", 1, &off);
            filp_close(drf, NULL);
            pr_info("dfroot: dmesg_restrict cleared\n");
        } else {
            pr_warn("dfroot: dmesg_restrict open failed\n");
        }
    }

    // IMPORTANT: do NOT patch avc_has_perm / avc_has_perm_noaudit here.
    // Returning 0 from the AVC made SELinux "show Enforcing but allow
    // everything", which is exactly the state users reported as fake
    // enforcement. The selinux_state write above is enough to deploy, and
    // deploy-magisk.sh calls `setenforce 1` again once Magisk is set up.
    pr_info("dfroot: leaving avc_has_perm untouched (real enforcement kept)\n");

    // Oppo/OnePlus
    oplus_exe_fn = (void *)(mkln ? mkln("oplus_exe_block_ret_handler") : 0);
    if (!oplus_exe_fn)
        pr_err("dfroot: oplus_exe_block_ret_handler not found, skipping\n");
    else {
        patch_fn_ret_zero(oplus_exe_fn);
        pr_info("dfroot: oplus_exe_block_ret_handler patched\n");
    }

    oplus_root_fn = (void *)(mkln ? mkln("oplus_root_check_post_handler") : 0);
    if (!oplus_root_fn)
        pr_err("dfroot: oplus_root_check_post_handler not found, skipping\n");
    else {
        patch_fn_ret_zero(oplus_root_fn);
        pr_info("dfroot: oplus_root_check_post_handler patched\n");
    }

    // Samsung
    defex_enforce_fn = (void *)get_addr("task_defex_enforce");
    if (!defex_enforce_fn)
        pr_err("dfroot: task_defex_enforce not found, skipping\n");
    else {
        patch_fn_ret_zero(defex_enforce_fn);
        pr_info("dfroot: task_defex_enforce patched\n");
    }

    defex_umh_fn = (void *)get_addr("task_defex_user_exec");
    if (!defex_umh_fn)
        pr_err("dfroot: task_defex_user_exec not found, skipping\n");
    else {
        patch_fn_ret_zero(defex_umh_fn);
        pr_info("dfroot: task_defex_user_exec patched\n");
    }

    /* Create the procfs escalation node. The device kernel has
     * CONFIG_STATIC_USERMODEHELPER=y, which makes call_usermodehelper()
     * ignore our path (replaced by a fixed empty path) -> any exec-based
     * deployment is impossible. We therefore (a) expose /proc/dfroot_su
     * which grants root to the writing process, and (b) deploy the static
     * su client entirely with kernel file ops (no exec at all). Works even
     * if /data is mounted nosuid (the client is not setuid). */
    g_su_proc_entry = proc_create("dfroot_su", 0666, NULL, &su_proc_fops);
    pr_info("dfroot: /proc/dfroot_su created\n");

    {
        int dep_ret;
        static const char *markers[] = {
            "/dev/dfm0", "/dev/dfm1", "/dev/dfm2",
            "/dev/dfm3", "/dev/dfm5", "/dev/dfm6"
        };
        int i;

        dep_ret = kernel_copy_file("/data/local/tmp/su-client",
                                   "/data/local/tmp/su", 0755);
        pr_info("dfroot: su client deployed (ret=%d)\n", dep_ret);

        for (i = 0; i < 6; i++) {
            struct file *mf = filp_open(markers[i],
                                        O_CREAT | O_WRONLY, 0644);
            if (!IS_ERR(mf))
                filp_close(mf, NULL);
        }
    }

    /* Done: SELinux permissive, /proc/dfroot_su live, su client deployed.
     * Return 0 so the module stays loaded: the proc node and fops must remain
     * valid for the client to trigger root. */
    pr_info("dfroot: setup complete, module stays loaded\n");

    return 0;
}

/* no module_exit: we never unload; saves .exit sections */
module_init(dfroot_init);
