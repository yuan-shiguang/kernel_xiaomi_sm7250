#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# patch_bakasu_susfs_v240.sh
#
# 给 ./setup.sh 从 GitHub 拉取的 BakaSU 本体补上 SuSFS v2.4.0 需要的改动：
#   1. kernel/supercall/dispatch.c : CMD_SUSFS_SET_PRIORITY_UID_FILTER 分发分支
#   2. kernel/Kconfig              : CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER 开关
#   3. kernel/selinux/sepolicy.c   : add_type() / add_rule_raw() 注册
#                                   sus_type / avd_allowed（SELinux 策略隐藏）
#
# 为什么必须单独成脚本：
#   ./setup.sh 是 curl 下来的，运行时会 git stash + git checkout main + git pull，
#   KernelSU/ 里任何本地改动都会被抹掉；而 KernelSU/ 本体按约定不入库。
#   所以每次跑完 setup.sh（或重新 clone BakaSU）之后都要再跑一次本脚本。
#
# 标准顺序：
#   ./setup.sh
#   ./patch_bakasu_susfs_v240.sh
#   ./build.sh all
#
# 用法：
#   ./patch_bakasu_susfs_v240.sh                 # 应用补丁（幂等，重复运行只会 SKIP）
#   ./patch_bakasu_susfs_v240.sh --check        # 只检查，不修改
#   ./patch_bakasu_susfs_v240.sh /path/to/kernel  # 指定 BakaSU 的 kernel/ 目录
#   ./patch_bakasu_susfs_v240.sh --help
#
# 说明：不打这个补丁不会导致编译失败，只是 v2.4.0 新增的
#       getpriority/setpriority/ioprio UID 过滤会被 defconfig 静默忽略，
#       且 fs/susfs.c 里的 SUS_TYPE_HLIST / SUS_AVD_ALLOWED_HLIST 不会被填充。
# -----------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR=""
CHECK_ONLY=0

usage() {
    echo "Usage: $0 [--check] [--help] [BakaSU kernel/ directory]"
    echo "  --check  : only report what is missing, do not modify anything"
    echo "  default  : $SCRIPT_DIR/KernelSU/kernel"
}

for arg in "$@"; do
    case "$arg" in
        --check)        CHECK_ONLY=1 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "[ERROR] unknown option: $arg" >&2; usage; exit 1 ;;
        *)              KSU_DIR="$arg" ;;
    esac
done

[ -n "$KSU_DIR" ] || KSU_DIR="$SCRIPT_DIR/KernelSU/kernel"

if [ ! -f "$KSU_DIR/supercall/dispatch.c" ] || [ ! -f "$KSU_DIR/Kconfig" ]; then
    echo "[ERROR] BakaSU kernel directory not found: $KSU_DIR" >&2
    echo "        Run ./setup.sh first, or pass the kernel/ path explicitly." >&2
    exit 1
fi

echo "[*] BakaSU kernel dir : $KSU_DIR"
echo "[*] Mode              : $([ "$CHECK_ONLY" -eq 1 ] && echo check-only || echo apply)"

python3 - "$KSU_DIR" "$CHECK_ONLY" <<'PY'
import pathlib, sys

ksu = pathlib.Path(sys.argv[1])
check_only = sys.argv[2] == "1"

# ---------------------------------------------------------------------------
# 1) supercall/dispatch.c : new v2.4.0 supercall
# ---------------------------------------------------------------------------
CASE_ANCHOR = "    case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING: {"
CASE_BLOCK = (
    "    #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
    "    case CMD_SUSFS_SET_PRIORITY_UID_FILTER: {\n"
    "        susfs_set_priority_uid_filter(arg);\n"
    "        return 0;\n"
    "    }\n"
    "    #endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
)

# ---------------------------------------------------------------------------
# 2) Kconfig : feature switch (otherwise defconfig entry is silently ignored)
# ---------------------------------------------------------------------------
KCFG_ANCHOR = "config KSU_SUSFS_SUS_MAP\n"
KCFG_BLOCK = (
    "config KSU_SUSFS_PRIORITY_UID_FILTER\n"
    '    bool "Enable getpriority/setpriority/ioprio uid filter"\n'
    "    depends on KSU_SUSFS\n"
    "    default y\n"
    "    help\n"
    "        - Hide selected app uids from getpriority/setpriority/ioprio probing.\n\n"
)

# ---------------------------------------------------------------------------
# 3) selinux/sepolicy.c : register types / original av masks
#
# Official v2.4.0 KernelSU calls susfs_add_sus_type() in add_type() and
# susfs_add_sus_avd_allowed_by_type() in add_rule_raw(). BakaSU does not,
# so without this the kernel-side SUS_TYPE_HLIST / SUS_AVD_ALLOWED_HLIST
# added by the v2.4.0 port stay empty.
# ---------------------------------------------------------------------------
SEP_DEF_ANCHOR = "#define KSU_SUPPORT_ADD_TYPE\n"
SEP_DEF_BLOCK = (
    "\n"
    "#ifdef CONFIG_KSU_SUSFS\n"
    "extern int susfs_add_sus_type(const char *secctx, u32 type_value);\n"
    "extern int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type,\n"
    "                                             u32 c_type, u32 orig_avd_allowed);\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS\n"
)

SEP_RULE_ANCHOR = (
    "        if (invert) {\n"
    "            if (perm)\n"
    "                node->datum.u.data &= ~(1U << (perm->value - 1));"
)
SEP_RULE_BLOCK = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "        /* Record the original allowed mask before KSU mutates it. */\n"
    "        susfs_add_sus_avd_allowed_by_type(src->value, tgt->value, cls->value,\n"
    "                                          node->datum.u.data);\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS\n\n"
)

SEP_TYPE_ANCHOR = (
    "    if (symtab_insert(&db->p_types, key, type)) {\n"
    "        pr_err(\"add_type: insert symtab failed.\\n\");\n"
    "        return false;\n"
    "    }\n"
)
SEP_TYPE_BLOCK = (
    "\n"
    "#ifdef CONFIG_KSU_SUSFS\n"
    "    susfs_add_sus_type(type_name, type->value);\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS\n"
)

# (relative path, idempotency marker, [(anchor, block, 'before'|'after'), ...])
PATCHES = [
    ("supercall/dispatch.c", "CMD_SUSFS_SET_PRIORITY_UID_FILTER",
     [(CASE_ANCHOR, CASE_BLOCK, "before")]),
    ("Kconfig", "config KSU_SUSFS_PRIORITY_UID_FILTER",
     [(KCFG_ANCHOR, KCFG_BLOCK, "before")]),
    ("selinux/sepolicy.c", "susfs_add_sus_type(type_name, type->value);",
     [(SEP_DEF_ANCHOR, SEP_DEF_BLOCK, "after"),
      (SEP_RULE_ANCHOR, SEP_RULE_BLOCK, "before"),
      (SEP_TYPE_ANCHOR, SEP_TYPE_BLOCK, "after")]),
]

rc = 0
for rel, marker, edits in PATCHES:
    p = ksu / rel
    if not p.is_file():
        print("  FAIL  %-26s file not found" % rel)
        rc = 1
        continue
    t = p.read_text(encoding="utf-8", errors="surrogateescape")
    if marker in t:
        print("  SKIP  %-26s already patched" % rel)
        continue
    problems = []
    for anchor, _block, _where in edits:
        cnt = t.count(anchor)
        if cnt != 1:
            problems.append("anchor count=%d: %r" % (cnt, anchor.strip()[:70]))
    if problems:
        print("  FAIL  %-26s anchors not unique (BakaSU layout changed?)" % rel)
        for msg in problems:
            print("        %s" % msg)
        rc = 1
        continue
    if check_only:
        print("  NEED  %-26s patch required" % rel)
        rc = 2 if rc == 0 else rc
        continue
    for anchor, block, where in edits:
        repl = (block + anchor) if where == "before" else (anchor + block)
        t = t.replace(anchor, repl, 1)
    p.write_text(t, encoding="utf-8", errors="surrogateescape")
    print("  OK    %-26s patched" % rel)

# sanity: manager detection supercalls must exist
d = (ksu / "supercall/dispatch.c").read_text(encoding="utf-8", errors="ignore")
for cmd in ("CMD_SUSFS_SHOW_VERSION", "CMD_SUSFS_SHOW_VARIANT", "CMD_SUSFS_SHOW_ENABLED_FEATURES"):
    if cmd not in d:
        print("  WARN  dispatch.c missing %s - manager may not detect SuSFS" % cmd)

sys.exit(rc)
PY
rc=$?

if [ "$rc" -eq 0 ]; then
    echo "[+] BakaSU ready for SuSFS v2.4.0"
elif [ "$rc" -eq 2 ]; then
    echo "[!] Patch(es) missing, re-run without --check to apply"
else
    echo "[ERROR] Patching failed, see FAIL lines above" >&2
fi
exit "$rc"
