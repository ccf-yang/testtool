#!/usr/bin/env bash
# ============================================================================
# pp — 一体化工具脚本（下载 Flutter / 克隆仓库 / 推送 / 起上传服务 / flutter 测试 / 应用 pro.py）
#
# 把原先的 download_flutter.sh、gitclone.sh、gitpush.sh、server.sh、test.sh
# 全部整合进本文件，用子命令分发；再配一份环境配置 ~/.work/.work.sh，
# 让 `pp` 在任何目录下都能直接使用。
#
# ---------------------------------------------------------------------------
# 一、首次初始化（写配置 + 安装 /bin/pp）
# ---------------------------------------------------------------------------
#   bash pp.sh --init --repo <仓库名> --token <GitHub token> \
#               [--branch dev] [--project /workspace/booktest] [--port 9000]
#
#   --repo       仓库名（owner 固定为 ccf-yang），如 booktest
#   --token      GitHub Personal Access Token（会明文写入 ~/.work/.work.sh，权限 600）
#   --branch     分支名，默认 dev
#   --project    项目目录（flutter 测试、git 操作都在这里），默认 /workspace/booktest
#   --port       本地上传服务端口，默认 9000
#   --workbase   默认/workspace
#
#   --init 等价于 -i / --install：生成 ~/.work/.work.sh 与 ~/.work/pro.py，
#   并建软链 /bin/pp -> 本脚本。
#   未提供的参数沿用「已有配置 / 内置默认值」。
#
# ---------------------------------------------------------------------------
# 二、日常使用（会自动 source ~/.work/.work.sh）
# ---------------------------------------------------------------------------
#   pp -d / --download       下载并解压 Flutter 到 /tmp/opencode/flutter
#   pp -g / --clone          clone 仓库（分支 = 配置的 branch）到 /workspace
#   pp -u / --push [msg]     提交并 push 当前分支（不合并其它分支）
#   pp -s / --server         在 /workspace 起 uploadserver（端口 = --port）
#   pp -t / --flutter-test   进入 project 跑 flutter analyze / test
#   pp -a / --apply          把内嵌的 pro.py 生成/复制到 /workspace 并执行 pro.py -i all.json
#   pp -c / --clear          删除 ~/.work/.work.sh 配置
#   pp -h / --help           查看帮助
#
#   也可以临时覆盖配置：
#     pp -t --project /workspace/other
#     pp --init --repo newrepo   # 更新配置（会重写 ~/.work/.work.sh）
# ============================================================================

set -e

# ---------------------------------------------------------------------------
# 固定配置（不需要改的部分）
# ---------------------------------------------------------------------------
GIT_OWNER="ccf-yang"
FLUTTER_DIR="/tmp/opencode/flutter"
FLUTTER_ARCHIVE="/tmp/opencode/flutter347.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz"

# ---------------------------------------------------------------------------
# 可配置项的默认值（会被 ~/.work/.work.sh 覆盖，再被命令行覆盖）
# ---------------------------------------------------------------------------
REPO_NAME="booktest"
BRANCH="dev"
GIT_TOKEN=""
WORKBASE="/workspace"
PROJECT_DIR="${WORKSPACE}/booktest"


# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
SCRIPT_REAL_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_REAL_PATH")"
WORK_CONF_DIR="$HOME/.work"
WORK_CONF="$WORK_CONF_DIR/.work.sh"
PRO_PY_TARGET="$WORK_CONF_DIR/pro.py"   # --init 时由本脚本内嵌内容生成（整个工具只维护 pp.sh 一个文件）
PP_LINK="/bin/pp"

# ---------------------------------------------------------------------------
# 载入已有配置
# ---------------------------------------------------------------------------
load_conf() {
    if [ -f "$WORK_CONF" ]; then
        # shellcheck disable=SC1090
        source "$WORK_CONF"
    fi
}

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------
show_help() {
    cat <<'HELP'
Usage: pp [SUBCOMMAND] [OPTIONS]

一次性配置:
  -i, --init, --install   生成 ~/.work/.work.sh 与 ~/.work/pro.py，安装 /bin/pp
  -c, --clear             删除 ~/.work/ 下生成的配置与 pro.py

可覆盖的配置项:
      --repo <name>       仓库名(owner 固定 ccf-yang)，默认 booktest
      --token <token>     GitHub token(明文写入 ~/.work/.work.sh)
      --branch <branch>   分支名，默认 dev
      --project <dir>     项目目录，默认 /workspace/booktest
      --workbase <dir>    存放项目的目录，默认是/workspace

子命令(会自动 source ~/.work/.work.sh):
  -d, --download          下载并解压 Flutter 到 /tmp/opencode/flutter
  -g, --clone             克隆仓库到 /workspace
  -u, --push [msg]        提交并 push 当前分支
  -s, --server            在 /workspace 启动 uploadserver
  -t, --flutter-test      进入项目目录，运行 flutter analyze / test
  -a, --apply             在/workspace下应用 pro.py -i all.json（pro.py 会按需自动生成），能直接将更新应用到项目
  -h, --help              显示本帮助

示例:
  bash pp.sh --init --repo booktest --token ghp_xxx --branch dev --project /workspace/booktest --workbase /workspace
  pp -t
  pp -u "fix: 修复问题"
  pp -s --port 9100
HELP
}

# ---------------------------------------------------------------------------
# 各子命令实现
# ---------------------------------------------------------------------------
do_download() {
    mkdir -p /tmp/opencode
    cd /tmp/opencode
    echo "-> 下载 Flutter: $FLUTTER_URL"
    curl -L --retry 3 -C - -o "$FLUTTER_ARCHIVE" "$FLUTTER_URL"
    tar xf "$FLUTTER_ARCHIVE"
    echo "-> Flutter 已就绪: $FLUTTER_DIR"
}

require_token() {
    if [ -z "$GIT_TOKEN" ]; then
        echo "错误: 未设置 token，请先执行 pp --init --token <token> 或用 --token 传入" >&2
        exit 1
    fi
}

repo_url() {
    echo "https://${GIT_OWNER}:${GIT_TOKEN}@github.com/${GIT_OWNER}/${REPO_NAME}.git"
}

do_clone() {
    require_token
    mkdir -p "$(dirname "$PROJECT_DIR")"
    if [ -d "$PROJECT_DIR/.git" ]; then
        echo "-> $PROJECT_DIR 已是 git 仓库，跳过 clone"
        return 0
    fi
    echo "-> 克隆 ${GIT_OWNER}/${REPO_NAME} (分支 $BRANCH) 到 $PROJECT_DIR"
    git clone -b "$BRANCH" --single-branch "$(repo_url)" "$PROJECT_DIR"
}

do_push() {
    require_token
    local msg="${1:-chore: 同步更新 $(date '+%Y-%m-%d %H:%M:%S')}"
    if [ ! -d "$PROJECT_DIR/.git" ]; then
        echo "错误: $PROJECT_DIR 不是 git 仓库，请先 pp -g" >&2
        exit 1
    fi
    cd "$PROJECT_DIR"
    git config user.name "$GIT_OWNER"
    git config user.email "${GIT_OWNER}@users.noreply.github.com"
    git remote set-url origin "$(repo_url)"
    git checkout "$BRANCH"

    git add -A
    if ! git diff --cached --quiet; then
        git commit -m "$msg"
    else
        echo "-> 无改动需要提交"
    fi

    git push origin "$BRANCH"
    git status -sb
}

do_server() {
    pip3 install uploadserver &>/dev/null || true
    cd "$WORKBASE"
    rm -f all.json
    echo "-> 上传目录: $WORKBASE"
    echo "-> 访问: http://0.0.0.0:8000"
    python3 -m uploadserver
}

do_test() {
    if [ ! -d "$FLUTTER_DIR" ]; then
        echo "错误: 未找到 Flutter ($FLUTTER_DIR)，请先执行 pp -d" >&2
        exit 1
    fi
    git config --global --add safe.directory "$FLUTTER_DIR" || true
    cd "$PROJECT_DIR"
    export PATH="$FLUTTER_DIR/bin:$PATH"
    flutter --version
    flutter pub get
    flutter analyze
    flutter test
}

do_apply() {
    mkdir -p "$PROJECT_DIR"
    if [ ! -f "$PRO_PY_TARGET" ]; then
        generate_pro_py
    fi
    if [ ! -f "$WORKBASE/pro.py" ]; then
        echo "-> 复制 pro.py 到 $WORKBASE"
        cp "$PRO_PY_TARGET" "$WORKBASE/pro.py"
    fi
    cd "$WORKBASE"
    if [ ! -f all.json ]; then
        echo "错误: $WORKBASE/all.json 不存在，请先用 pp -s 上传" >&2
        exit 1
    fi
    python3 pro.py -i all.json
    rm -f all.json
}

# 从本脚本内嵌内容生成 pro.py，保证工具只有一个文件
generate_pro_py() {
    mkdir -p "$WORK_CONF_DIR"
    cat > "$PRO_PY_TARGET" <<'PRO_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
proj.py — 目录 <-> JSON 互转工具

导出(-e): 读取目录下所有文件(含子目录)，打包成一个 JSON:
          键 = 相对路径(以导出目录名为根，如 "dir/filea.js"、"dir/subdir/fileb.sh")
          值 = 文件内容(文本原样保留换行；二进制文件自动转 base64 存放)
          注: 空目录、软链接无法用 JSON 表达，会被跳过

导入(-i): 读取导出的 JSON，在【脚本所在目录】按原目录结构还原所有文件

用法:
  导出   python3 proj.py -e /path/to/dir               # JSON(单行)打印到终端
         python3 proj.py -e /path/to/dir -o out.json   # 写入指定文件
  导入   python3 proj.py -i out.json                   # 还原到脚本所在目录

示例:
  python3 proj.py -e /data -o data.json
  python3 proj.py -i data.json
"""

import argparse
import base64
import json
import os
import re
import sys

B64_KEY = "__b64__"                 # 二进制文件的包装格式: {B64_KEY: "base64字符串"}
DRIVE_RE = re.compile(r"^[A-Za-z]:")  # 拒绝 Windows 盘符式路径成分


def die(msg, code=1):
    sys.stderr.write("proj.py: 错误: %s\n" % msg)
    sys.exit(code)


def iter_files(src):
    """确定性地遍历 src 下所有普通文件(跳过软链接/fifo 等特殊文件)。"""
    for root, dirs, files in os.walk(src):
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(root, d)))
        for name in sorted(files):
            full = os.path.join(root, name)
            if os.path.islink(full) or not os.path.isfile(full):
                sys.stderr.write("proj.py: 跳过特殊文件: %s\n" % full)
                continue
            yield full


def read_entry(path):
    """读取一个文件: 优先按 UTF-8 文本(保留原始换行符)，失败则按 base64。"""
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            return f.read()
    except UnicodeDecodeError:
        with open(path, "rb") as f:
            return {B64_KEY: base64.b64encode(f.read()).decode("ascii")}


def cmd_export(src, out_path):
    src = os.path.abspath(src)
    if not os.path.isdir(src):
        die("目录不存在: %s" % src)

    parent = os.path.dirname(src)  # 键相对父目录 => 自带目录名作根(与示例 "dir/filea.js" 一致)
    data = {}
    total = 0
    for full in iter_files(src):
        rel = os.path.relpath(full, parent).replace(os.sep, "/")
        try:
            data[rel] = read_entry(full)
        except OSError as e:
            sys.stderr.write("proj.py: 跳过无法读取的文件 %s (%s)\n" % (rel, e))
            continue
        total += os.path.getsize(full)

    payload = json.dumps(data, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":"), indent=2)
    if out_path:
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(payload + "\n")
        sys.stderr.write("proj.py: 已导出 %d 个文件(共 %d 字节) -> %s\n"
                         % (len(data), total, out_path))
    else:
        sys.stdout.write(payload + "\n")
        sys.stderr.write("proj.py: 已导出 %d 个文件(共 %d 字节) 到标准输出\n"
                         % (len(data), total))


def safe_parts(key):
    """把键拆成安全路径成分(防绝对路径/目录穿越/盘符)，非法返回 None。"""
    parts = [p for p in key.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    if any(DRIVE_RE.match(p) for p in parts):
        return None
    return parts


def cmd_import(json_path):
    base = os.path.dirname(os.path.abspath(__file__))  # 还原到脚本所在目录
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        die("无法读取 JSON: %s (%s)" % (json_path, e))
    if not isinstance(data, dict):
        die("JSON 顶层必须是对象({\"路径\": 内容})")

    ok = skipped = 0
    for key in sorted(data):
        parts = safe_parts(key)
        if parts is None:
            sys.stderr.write("proj.py: 跳过非法路径键: %r\n" % key)
            skipped += 1
            continue
        target = os.path.join(base, *parts)
        val = data[key]
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if isinstance(val, dict) and B64_KEY in val:
                with open(target, "wb") as f:
                    f.write(base64.b64decode(val[B64_KEY]))
            else:
                text = val if isinstance(val, str) else json.dumps(val, ensure_ascii=False)
                with open(target, "w", encoding="utf-8", newline="") as f:
                    f.write(text)
            sys.stderr.write("proj.py:   + %s\n" % key)
            ok += 1
        except (OSError, ValueError) as e:
            sys.stderr.write("proj.py: 写入失败 %s (%s)\n" % (key, e))
            skipped += 1

    sys.stderr.write("proj.py: 完成: 在 %s 下还原 %d 个文件%s\n"
                     % (base, ok, ("，跳过 %d 项" % skipped) if skipped else ""))


def main():
    ap = argparse.ArgumentParser(
        prog="proj.py",
        description="目录 <-> JSON 互转: 导出目录所有文件为 JSON；从 JSON 还原到脚本所在目录",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python3 proj.py -e /data -o data.json\n"
               "  python3 proj.py -i data.json\n")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("-e", "--export", metavar="DIR",
                   help="导出指定目录的全部文件为 JSON")
    g.add_argument("-i", "--import", metavar="FILE", dest="import_file",
                   help="读取导出的 JSON，还原到脚本所在目录")
    ap.add_argument("-o", "--output", metavar="JSON",
                    help="(配合 -e)输出 JSON 文件路径，缺省打印到终端")
    args = ap.parse_args()

    if args.export:
        cmd_export(args.export, args.output)
    else:
        cmd_import(args.import_file)


if __name__ == "__main__":
    main()
PRO_PY_EOF
    chmod +x "$PRO_PY_TARGET"
    echo "-> 已生成: $PRO_PY_TARGET"
}

do_init() {
    mkdir -p "$WORK_CONF_DIR"
    generate_pro_py
    cat > "$WORK_CONF" <<EOF
# 由 pp --init 自动生成，请勿手工修改
# $(date '+%Y-%m-%d %H:%M:%S')
export REPO_NAME="$REPO_NAME"
export BRANCH="$BRANCH"
export GIT_TOKEN="$GIT_TOKEN"
export WORKBASE="$WORKBASE"
export PROJECT_DIR="$PROJECT_DIR"
export PORT="$PORT"
EOF
    chmod 600 "$WORK_CONF"
    echo "-> 已写入配置: $WORK_CONF"
    cat "$WORK_CONF"

    chmod +x "$SCRIPT_REAL_PATH"
    rm -f "$PP_LINK"
    ln -s "$SCRIPT_REAL_PATH" "$PP_LINK"
    chmod +x "$PP_LINK"
    echo "-> 已安装: $PP_LINK -> $SCRIPT_REAL_PATH"
    echo "-> 之后可直接使用 pp 命令"
}

do_clear() {
    local found=0
    if [ -f "$WORK_CONF" ]; then
        rm -f "$WORK_CONF"
        echo "-> 已删除配置: $WORK_CONF"
        cd "$WORKBASE" && rm -rf "$WORKBASE/*"
        found=1
    fi
    if [ -f "$PRO_PY_TARGET" ]; then
        rm -f "$PRO_PY_TARGET"
        echo "-> 已删除: $PRO_PY_TARGET"
        found=1
    fi
    if [ "$found" -eq 0 ]; then
        echo "-> 配置不存在: $WORK_CONF"
    fi
}

# ---------------------------------------------------------------------------
# 载入配置 + 解析参数
# ---------------------------------------------------------------------------
load_conf

WANT_INIT=0
WANT_CLEAR=0
ACTION=""
PUSH_MSG=""
HAS_ARG=0

while [ $# -gt 0 ]; do
    HAS_ARG=1
    case "$1" in
        --repo)      REPO_NAME="${2:-}"; shift 2 || true ;;
        --token)     GIT_TOKEN="${2:-}"; shift 2 || true ;;
        --branch)    BRANCH="${2:-}"; shift 2 || true ;;
        --workbase)  WORKBASE="${2:-}"; shift 2 || true ;;
        --project)   PROJECT_DIR="${2:-}"; shift 2 || true ;;
        --port)      PORT="${2:-}"; shift 2 || true ;;
        -i|--init|--install) WANT_INIT=1; shift ;;
        -c|--clear)  WANT_CLEAR=1; shift ;;
        -d|--download) ACTION="download"; shift ;;
        -g|--clone)  ACTION="clone"; shift ;;
        -u|--push)   ACTION="push"; shift
                     if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then PUSH_MSG="$1"; shift; fi ;;
        -s|--server) ACTION="server"; shift ;;
        -t|--flutter-test) ACTION="test"; shift ;;
        -a|--apply)  ACTION="apply"; shift ;;
        -h|--help)   show_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; show_help; exit 1 ;;
    esac
done

if [ "$HAS_ARG" -eq 0 ]; then
    show_help
    exit 1
fi

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
if [ "$WANT_CLEAR" -eq 1 ]; then
    do_clear
fi
if [ "$WANT_INIT" -eq 1 ]; then
    do_init
fi

case "$ACTION" in
    download) do_download ;;
    clone)    do_clone ;;
    push)     do_push "$PUSH_MSG" ;;
    server)   do_server ;;
    test)     do_test ;;
    apply)    do_apply ;;
    "")       : ;;
esac

