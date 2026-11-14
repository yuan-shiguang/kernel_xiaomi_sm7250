#!/usr/bin/env bash
# =============================================================================
# susfs_inline_hook_patches.sh
#
# SuSFS v2.4.0 inline hook injection for the LineageOS sm7250 (picasso) tree,
# kernel 4.19.325. Rewritten from the v2.3.00 sed injector: the hooks are now
# carried as an exact, embedded unified diff generated from the validated
# v2.4.0 working tree, so the result is byte-identical to the tested kernel.
#
# Workflow on a clean LineageOS android_kernel_xiaomi_sm7250 tree:
#   1) git apply susfs_patch_to_4.19.patch   (SuSFS body, 20 files)
#   2) ./susfs_inline_hook_patches.sh       (this script, 8 hook files)
#   3) enable CONFIG_KSU_SUSFS=y and CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y
#      in your defconfig, then build.
#
# The body patch and this script are strictly complementary: no file is
# touched by both. Applying both reproduces the exact v2.4.0 source state.
#
# The BakaSU/KSU side (KernelSU/kernel/supercall/dispatch.c, Kconfig and
# selinux/sepolicy.c) is NOT covered by these two patches; supply it from
# your KSU tree separately.
#
# Required defconfig symbols (defined by KernelSU/kernel/Kconfig):
#   CONFIG_KSU_SUSFS=y
#   CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y   (v2.4.0 feature)
# All other CONFIG_KSU_SUSFS_* sub-options keep their Kconfig defaults.
# Without these, every #ifdef CONFIG_KSU_SUSFS block is compiled out and
# both patches become a no-op even though they apply cleanly.
#
# This script is idempotent and never modifies build.sh.
# =============================================================================

set -u

PATCH_LEVEL="2.4.0"
TARGET_TREE="LineageOS android_kernel_xiaomi_sm7250 / 4.19.325"
HOOK_FILES=(
    drivers/input/input.c
    fs/exec.c
    fs/open.c
    fs/read_write.c
    fs/stat.c
    kernel/reboot.c
    kernel/sys.c
    security/selinux/hooks.c
)

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS] [KERNEL_ROOT]

Inject / verify the SuSFS v${PATCH_LEVEL} inline hooks into a kernel source tree.

Options:
  --check     Only report whether the hooks are applied; change nothing.
  --reverse   Remove the inline hooks (requires a tree where they are applied).
  --root DIR  Kernel source root (default: current directory).
  -h, --help  Show this help.

Exit codes: 0 = ok / already applied, 1 = tree mismatch, 2 = usage error.
USAGE
}

ROOT="."
MODE="apply"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)   MODE="check"; shift ;;
        --reverse) MODE="reverse"; shift ;;
        --root)
            ROOT="${2:-}"
            [ -n "$ROOT" ] || { echo "Error: --root needs a directory" >&2; exit 2; }
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: unknown option '$1'" >&2; usage; exit 2 ;;
        *) ROOT="$1"; shift ;;
    esac
done

if [ ! -f "$ROOT/Makefile" ] || [ ! -d "$ROOT/fs" ] || [ ! -d "$ROOT/kernel" ]; then
    echo "Error: '$ROOT' does not look like a kernel source root." >&2
    exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

TMP="$(mktemp "${TMPDIR:-/tmp}/susfs_v240_hooks.XXXXXX")" || exit 2
trap 'rm -f "$TMP"' EXIT INT TERM

cat > "$TMP" <<'SUSFS_V240_HOOK_DIFF'
diff --git a/drivers/input/input.c b/drivers/input/input.c
index 70ffffea3..7be7decec 100644
--- a/drivers/input/input.c
+++ b/drivers/input/input.c
@@ -378,10 +378,20 @@ static int input_get_disposition(struct input_dev *dev,
 	return disposition;
 }
 
+#ifdef CONFIG_KSU
+extern struct static_key_true ksu_is_input_hook_enabled;
+extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
+#endif
+
 static void input_handle_event(struct input_dev *dev,
 			       unsigned int type, unsigned int code, int value)
 {
 	int disposition = input_get_disposition(dev, type, code, &value);
+#ifdef CONFIG_KSU_SUSFS
+	if (static_branch_unlikely(&ksu_is_input_hook_enabled))
+		ksu_handle_input_handle_event(&type, &code, &value);
+#endif
+
 
 	if (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)
 		add_input_randomness(type, code, value);
diff --git a/fs/exec.c b/fs/exec.c
index 9a70a2f94..4faef1435 100644
--- a/fs/exec.c
+++ b/fs/exec.c
@@ -62,6 +62,9 @@
 #include <linux/oom.h>
 #include <linux/compat.h>
 #include <linux/vmalloc.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#endif
 
 #include <linux/uaccess.h>
 #include <asm/mmu_context.h>
@@ -1728,6 +1731,17 @@ static int exec_binprm(struct linux_binprm *bprm)
 /*
  * sys_execve() executes a new program.
  */
+#ifdef CONFIG_KSU_SUSFS
+extern struct static_key_true ksu_su_compat_enabled;
+extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
+extern bool __ksu_is_allow_uid_for_current(uid_t uid);
+extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
+			void *envp, int *flags);
+extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
+				void *envp, int *flags);
+extern int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
+			void *envp, int *flags, int *retval);
+#endif
 static int __do_execve_file(int fd, struct filename *filename,
 			    struct user_arg_ptr argv,
 			    struct user_arg_ptr envp,
@@ -1738,8 +1752,23 @@ static int __do_execve_file(int fd, struct filename *filename,
 	struct files_struct *displaced;
 	int retval;
 
+#ifdef CONFIG_KSU_SUSFS
+	bool is_su_session = false;
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 	if (IS_ERR(filename))
 		return PTR_ERR(filename);
+#ifdef CONFIG_KSU_SUSFS
+	if (likely(susfs_is_current_proc_no_su()))
+		goto orig_flow;
+	if (static_branch_likely(&ksu_su_compat_enabled)) {
+		if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted))
+		is_su_session = !ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
+	else
+		is_su_session = !ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
+	}
+orig_flow:
+#endif
 
 	/*
 	 * We move the actual failure in case of RLIMIT_NPROC excess from
@@ -1882,6 +1911,11 @@ static int __do_execve_file(int fd, struct filename *filename,
 	current->fs->in_exec = 0;
 	current->in_execve = 0;
 
+#ifdef CONFIG_KSU_SUSFS
+	if (unlikely(is_su_session))
+		(void)ksu_handle_post_execveat_sucompat(&fd, &filename, &argv, &envp, &flags, &retval);
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 out_free:
 	free_bprm(bprm);
 	kfree(pathbuf);
diff --git a/fs/open.c b/fs/open.c
index accdc1b2c..b9f58fcaa 100644
--- a/fs/open.c
+++ b/fs/open.c
@@ -31,6 +31,9 @@
 #include <linux/ima.h>
 #include <linux/dnotify.h>
 #include <linux/compat.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#endif
 
 #include "internal.h"
 #include <trace/hooks/syscall_check.h>
@@ -354,6 +357,12 @@ SYSCALL_DEFINE4(fallocate, int, fd, int, mode, loff_t, offset, loff_t, len)
  * We do this by temporarily clearing all FS-related capabilities and
  * switching the fsuid/fsgid around to the real ones.
  */
+#ifdef CONFIG_KSU_SUSFS
+extern struct static_key_true ksu_su_compat_enabled;
+extern bool __ksu_is_allow_uid_for_current(uid_t uid);
+extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
+			int *flags);
+#endif
 long do_faccessat(int dfd, const char __user *filename, int mode)
 {
 	const struct cred *old_cred;
@@ -364,6 +373,10 @@ long do_faccessat(int dfd, const char __user *filename, int mode)
 	int res;
 	unsigned int lookup_flags = LOOKUP_FOLLOW;
 
+#ifdef CONFIG_KSU_SUSFS
+	struct filename *fname = NULL;
+#endif
+
 	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */
 		return -EINVAL;
 
@@ -405,7 +418,23 @@ long do_faccessat(int dfd, const char __user *filename, int mode)
 
 	old_cred = override_creds(override_cred);
 retry:
+#ifdef CONFIG_KSU_SUSFS
+	fname = getname_flags(filename, lookup_flags, NULL);
+
+	if (likely(susfs_is_current_proc_no_su()))
+		goto orig_flow;
+
+	if (static_branch_likely(&ksu_su_compat_enabled)) {
+		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
+			ksu_handle_faccessat(&dfd, &fname, &mode, NULL);
+	}
+
+orig_flow:
+	res = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
+	// no putname(fname) here as filename_lookup() has it done for us already;
+#else
 	res = user_path_at(dfd, filename, lookup_flags, &path);
+#endif
 	if (res)
 		goto out;
 
diff --git a/fs/read_write.c b/fs/read_write.c
index 650fc7e0f..07cc7c1a4 100644
--- a/fs/read_write.c
+++ b/fs/read_write.c
@@ -586,8 +586,16 @@ ssize_t ksys_read(unsigned int fd, char __user *buf, size_t count)
 	return ret;
 }
 
+#ifdef CONFIG_KSU
+extern struct static_key_true ksu_is_init_rc_hook_enabled;
+extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd);
+#endif
 SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
 {
+#ifdef CONFIG_KSU
+	if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
+		ksu_handle_sys_read(fd);
+#endif
 	return ksys_read(fd, buf, count);
 }
 
diff --git a/fs/stat.c b/fs/stat.c
index 376543199..9e2dde37f 100644
--- a/fs/stat.c
+++ b/fs/stat.c
@@ -17,9 +17,26 @@
 #include <linux/syscalls.h>
 #include <linux/pagemap.h>
 #include <linux/compat.h>
+#include "internal.h"
 
 #include <linux/uaccess.h>
 #include <asm/unistd.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#include "mount.h"
+#endif
+#ifdef CONFIG_KSU_SUSFS
+extern struct static_key_true ksu_is_init_rc_hook_enabled;
+extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);
+extern struct static_key_true ksu_su_compat_enabled;
+extern bool __ksu_is_allow_uid_for_current(uid_t uid);
+extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
+#endif // #ifdef CONFIG_KSU_SUSFS
+
+#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
+extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
+extern void susfs_sus_kstat_spoof_generic_fillattr(struct inode *inode, struct kstat *stat, u32 result_mask);
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
 
 /**
  * generic_fillattr - Fill in the basic attributes from the inode struct
@@ -75,9 +92,54 @@ int vfs_getattr_nosec(const struct path *path, struct kstat *stat,
 	stat->result_mask |= STATX_BASIC_STATS;
 	request_mask &= STATX_ALL;
 	query_flags &= KSTAT_QUERY_FLAGS;
+
+#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
+	if (susfs_is_current_app_uid()) {
+		bool is_fuse = false;
+		if (susfs_is_inode_sus_kstat(d_backing_inode(path->dentry), &is_fuse)) {
+			if (!is_fuse) {
+				// stat->mnt_id = real_mount(path->mnt)->mnt_id;
+				// only for 5.10 kernel
+				stat->result_mask |= STATX_SUS_KSTAT;
+			}
+			// stat->mnt_id = real_mount(path->mnt)->mnt_id;
+			// only for 5.10 kernel
+			stat->result_mask |= STATX_SUS_KSTAT_FUSE;
+		}
+	}
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
+
 	if (inode->i_op->getattr)
+#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
+	{
+		int err = inode->i_op->getattr(path, stat, request_mask,
+					    query_flags);
+		if (!err) {
+			if (stat->result_mask & STATX_SUS_KSTAT) {
+				susfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT);
+				return err;
+			}
+			if (stat->result_mask & STATX_SUS_KSTAT_FUSE) {
+				susfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT_FUSE);
+			return err;
+			}
+		}
+		return err;
+	}
+	if (stat->result_mask & STATX_SUS_KSTAT) {
+		generic_fillattr(inode, stat);
+		susfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT);
+		return 0;
+	}
+	if (stat->result_mask & STATX_SUS_KSTAT_FUSE) {
+		generic_fillattr(inode, stat);
+		susfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT_FUSE);
+		return 0;
+	}
+#else
 		return inode->i_op->getattr(path, stat, request_mask,
 					    query_flags);
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
 
 	generic_fillattr(inode, stat);
 	return 0;
@@ -142,6 +204,11 @@ int vfs_statx_fd(unsigned int fd, struct kstat *stat,
 	if (f.file) {
 		error = vfs_getattr(&f.file->f_path, stat,
 				    request_mask, query_flags);
+#ifdef CONFIG_KSU_SUSFS
+		if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
+			ksu_handle_vfs_fstat(fd, &stat->size);
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 		fdput(f);
 	}
 	return error;
@@ -169,6 +236,10 @@ int vfs_statx(int dfd, const char __user *filename, int flags,
 	struct path path;
 	int error = -EINVAL;
 	unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;
+#ifdef CONFIG_KSU_SUSFS
+	struct filename *fname = NULL;
+#endif
+
 
 	if ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |
 		       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)
@@ -182,7 +253,23 @@ int vfs_statx(int dfd, const char __user *filename, int flags,
 		lookup_flags |= LOOKUP_EMPTY;
 
 retry:
+#ifdef CONFIG_KSU_SUSFS
+	fname = getname_flags(filename, lookup_flags, NULL);
+
+	if (likely(susfs_is_current_proc_no_su()))
+		goto orig_flow;
+
+	if (static_branch_likely(&ksu_su_compat_enabled)) {
+		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
+			ksu_handle_stat(&dfd, &fname, &flags);
+	}
+
+orig_flow:
+	error = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
+	// no putname(fname) here as filename_lookup() has it done for us already;
+#else
 	error = user_path_at(dfd, filename, lookup_flags, &path);
+#endif
 	if (error)
 		goto out;
 
diff --git a/kernel/reboot.c b/kernel/reboot.c
index 3a87fee47..ddfdae655 100644
--- a/kernel/reboot.c
+++ b/kernel/reboot.c
@@ -305,12 +305,22 @@ DEFINE_MUTEX(system_transition_mutex);
  *
  * reboot doesn't sync: do that yourself before calling this.
  */
+#ifdef CONFIG_KSU_SUSFS
+extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
+#endif
+
 SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
 		void __user *, arg)
 {
 	struct pid_namespace *pid_ns = task_active_pid_ns(current);
 	char buffer[256];
 	int ret = 0;
+#ifdef CONFIG_KSU_SUSFS
+    if (system_state == SYSTEM_RUNNING) {
+        ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
+    }
+#endif
+
 
 	/* We only trust the superuser with rebooting the system. */
 	if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))
diff --git a/kernel/sys.c b/kernel/sys.c
index a19ddda68..0057e7a70 100644
--- a/kernel/sys.c
+++ b/kernel/sys.c
@@ -198,6 +198,10 @@ static int set_one_prio(struct task_struct *p, int niceval, int error)
 	return error;
 }
 
+#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
+extern bool susfs_is_priority_uid_filtered(uid_t uid);
+#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
+
 SYSCALL_DEFINE3(setpriority, int, which, int, who, int, niceval)
 {
 	struct task_struct *g, *p;
@@ -243,6 +247,10 @@ SYSCALL_DEFINE3(setpriority, int, which, int, who, int, niceval)
 		if (!who)
 			uid = cred->uid;
 		else if (!uid_eq(uid, cred->uid)) {
+#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
+			if (cred->uid.val >= 10000 && susfs_is_priority_uid_filtered(uid.val))
+				goto out_unlock;
+#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
 			user = find_user(uid);
 			if (!user)
 				goto out_unlock;	/* No processes for this user */
@@ -311,6 +319,10 @@ SYSCALL_DEFINE2(getpriority, int, which, int, who)
 		if (!who)
 			uid = cred->uid;
 		else if (!uid_eq(uid, cred->uid)) {
+#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
+			if (cred->uid.val >= 10000 && susfs_is_priority_uid_filtered(uid.val))
+				goto out_unlock;
+#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
 			user = find_user(uid);
 			if (!user)
 				goto out_unlock;	/* No processes for this user */
@@ -688,8 +700,18 @@ long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)
 	return retval;
 }
 
+#ifdef CONFIG_KSU
+extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
+#endif
+
 SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
 {
+#ifdef CONFIG_KSU_SUSFS
+	if (ksu_handle_setresuid(ruid, euid, suid)) {
+		pr_info("Something wrong with ksu_handle_setresuid()\\n");
+	}
+#endif
+
 	return __sys_setresuid(ruid, euid, suid);
 }
 
@@ -1240,12 +1262,20 @@ static int override_release(char __user *release, size_t len)
 	return ret;
 }
 
+#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
+extern struct static_key_false susfs_is_uname_spoof_buffer_set;
+extern void susfs_spoof_uname(struct new_utsname* tmp);
+#endif
 SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)
 {
 	struct new_utsname tmp;
 
 	down_read(&uts_sem);
 	memcpy(&tmp, utsname(), sizeof(tmp));
+#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
+	if (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
+		susfs_spoof_uname(&tmp);
+#endif
 	up_read(&uts_sem);
 	if (copy_to_user(name, &tmp, sizeof(tmp)))
 		return -EFAULT;
diff --git a/security/selinux/hooks.c b/security/selinux/hooks.c
index 353fa0ec8..6457d02f0 100644
--- a/security/selinux/hooks.c
+++ b/security/selinux/hooks.c
@@ -2217,17 +2217,38 @@ static int check_nnp_nosuid(const struct linux_binprm *bprm,
 			    const struct task_security_struct *old_tsec,
 			    const struct task_security_struct *new_tsec)
 {
+#ifdef CONFIG_KSU
+    static u32 ksu_sid;
+    char *secdata;
+#endif
 	int nnp = (bprm->unsafe & LSM_UNSAFE_NO_NEW_PRIVS);
 	int nosuid = !mnt_may_suid(bprm->file->f_path.mnt);
 	int rc;
 	u32 av;
 
+#ifdef CONFIG_KSU
+    int error;
+    u32 seclen;
+#endif
 	if (!nnp && !nosuid)
 		return 0; /* neither NNP nor nosuid */
 
 	if (new_tsec->sid == old_tsec->sid)
 		return 0; /* No change in credentials */
 
+#ifdef CONFIG_KSU
+    if (!ksu_sid)
+        security_secctx_to_secid("u:r:su:s0", strlen("u:r:su:s0"), &ksu_sid);
+
+    error = security_secid_to_secctx(old_tsec->sid, &secdata, &seclen);
+    if (!error) {
+        rc = strcmp("u:r:init:s0", secdata);
+        security_release_secctx(secdata, seclen);
+        if (rc == 0 && new_tsec->sid == ksu_sid)
+            return 0;
+    }
+#endif
+
 	/*
 	 * If the policy enables the nnp_nosuid_transition policy capability,
 	 * then we permit transitions under NNP or nosuid if the
SUSFS_V240_HOOK_DIFF

echo "Current susfs hook patch version: ${PATCH_LEVEL}"
echo "  target : ${TARGET_TREE}"
echo "  root   : ${ROOT}"
echo "  mode   : ${MODE}"

if [ -f "$ROOT/include/linux/susfs.h" ]; then
    VER="$(grep -m1 '^#define SUSFS_VERSION' "$ROOT/include/linux/susfs.h" | cut -d'"' -f2)"
    echo "  susfs  : ${VER:-unknown}"
    [ -n "${VER:-}" ] && [ "${VER#v}" != "$PATCH_LEVEL" ] && \
        echo "  [!] version differs from v${PATCH_LEVEL}; double-check your tree"
fi
if [ ! -f "$ROOT/fs/susfs.c" ]; then
    echo "  [!] fs/susfs.c missing - apply susfs_patch_to_4.19.patch first"
fi

cd "$ROOT" || exit 2
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ENGINE="git"
else
    ENGINE="patch"
fi
echo "  engine : ${ENGINE}"

state() {
    if [ "$ENGINE" = "git" ]; then
        if git apply --check --whitespace=nowarn "$TMP" 2>/dev/null; then
            echo "clean"
        elif git apply --reverse --check --whitespace=nowarn "$TMP" 2>/dev/null; then
            echo "applied"
        else
            echo "conflict"
        fi
    else
        if patch -p1 --forward --batch --dry-run < "$TMP" >/dev/null 2>&1; then
            echo "clean"
        elif patch -p1 -R --forward --batch --dry-run < "$TMP" >/dev/null 2>&1; then
            echo "applied"
        else
            echo "conflict"
        fi
    fi
}

apply_forward() {
    if [ "$ENGINE" = "git" ]; then
        git apply --whitespace=nowarn "$TMP"
    else
        patch -p1 --forward --batch < "$TMP"
    fi
}

apply_reverse() {
    if [ "$ENGINE" = "git" ]; then
        git apply --reverse --whitespace=nowarn "$TMP"
    else
        patch -p1 -R --forward --batch < "$TMP"
    fi
}

STATE="$(state)"
echo "  state  : ${STATE}"
echo "======================================"

case "$MODE" in
    check)
        case "$STATE" in
            clean)    echo "[+] inline hooks NOT applied yet (patch applies cleanly)"; exit 0 ;;
            applied)  echo "[+] inline hooks already applied (v${PATCH_LEVEL})"; exit 0 ;;
            conflict) echo "[-] tree does not match the expected 4.19.325 baseline"; exit 1 ;;
        esac ;;
    apply)
        case "$STATE" in
            clean)
                apply_forward || { echo "[-] failed to apply inline hooks" >&2; exit 1; }
                for f in "${HOOK_FILES[@]}"; do
                    echo "[+] $f Patched!"
                done
                echo "[+] SuSFS v${PATCH_LEVEL} inline hooks injected."
                ;;
            applied)
                echo "[+] inline hooks already present, nothing to do (idempotent)."
                exit 0 ;;
            conflict)
                echo "[-] tree does not match the expected 4.19.325 baseline." >&2
                echo "    Use --check for details, or start from a clean tree." >&2
                exit 1 ;;
        esac ;;
    reverse)
        case "$STATE" in
            applied)
                apply_reverse || { echo "[-] failed to revert inline hooks" >&2; exit 1; }
                echo "[+] SuSFS v${PATCH_LEVEL} inline hooks reverted."
                ;;
            clean)
                echo "[+] inline hooks are not applied, nothing to revert."
                exit 0 ;;
            conflict)
                echo "[-] cannot determine hook state; refusing to reverse." >&2
                exit 1 ;;
        esac ;;
esac

echo "======================================"
exit 0
