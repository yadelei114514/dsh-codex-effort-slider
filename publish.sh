#!/usr/bin/env bash
# 发布前自检 + 发布助手（Linux / macOS / WSL）。
#
# 用法：
#   ./publish.sh check     只跑自检，不改任何东西（推荐先跑这个）
#   ./publish.sh github    自检 + 初始化 git 并推到 GitHub（需要已装 git）
#   ./publish.sh npm       自检 + 发布到 npm（需要先 npm login）
#   ./publish.sh zip       自检 + 打一个可以直接发给朋友的 zip
#
# 为什么要有这个脚本：发布漏一步的代价很高（比如忘记跑测试、忘记改 cordis.patch.yml
# 的包名、YAML 里 scoped 包名没加引号），而这些都能在本地静态查出来。

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-check}"
PKG_NAME="$(node -p "require('./package.json').name")"
PKG_VERSION="$(node -p "require('./package.json').version")"

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

say "=== 发布自检 ==="
printf '  包名    : %s\n  版本    : %s\n\n' "$PKG_NAME" "$PKG_VERSION"

# ── 1. 测试必须全绿 ────────────────────────────────────────────────────────
say "[1/6] 离线测试"
if npm test >/tmp/ces-test.log 2>&1; then
  ok "$(grep -oE '[0-9]+ 项通过' /tmp/ces-test.log | tail -1)"
else
  tail -20 /tmp/ces-test.log
  die "测试失败 —— 不要发布（日志：/tmp/ces-test.log）"
fi

# ── 2. 包名必须是 scoped 且不是原作者的 ────────────────────────────────────
say "[2/6] 包名冲突检查"
case "$PKG_NAME" in
  @*/*) ok "是 scoped 包（不会和 npm 上的原版冲突）" ;;
  dsh-codex-effort-slider) die "包名还是原作者的 dsh-codex-effort-slider —— npm 上已被占用，必须改名" ;;
  *) ok "是普通包名 $PKG_NAME" ;;
esac

# ── 3. cordis.patch.yml 的 name 必须和 package.json 一致 ───────────────────
say "[3/6] 组合包声明一致性"
PATCH_NAME="$(node -e '
const fs = require("fs");
const y = fs.readFileSync("cordis.patch.yml", "utf8");
const m = /name:\s*"?([^"\n]+)"?/.exec(y);
process.stdout.write(m ? m[1].trim() : "");
')"
if [ "$PATCH_NAME" = "$PKG_NAME" ]; then
  ok "cordis.patch.yml 的 name 与 package.json 一致"
else
  die "不一致：cordis.patch.yml = '$PATCH_NAME'，package.json = '$PKG_NAME'"
fi
# scoped 包名带 @ 时 YAML 里必须加引号（@ 是 YAML 保留字符）
if grep -qE 'name:\s*@' cordis.patch.yml; then
  die "cordis.patch.yml 里 scoped 包名没加引号 —— YAML 解析会失败"
fi
ok "YAML 里包名已加引号"

# ── 4. 运行时内部 id 不该跟着包名改（改了会丢已装用户的设置） ──────────────
say "[4/6] 运行时标识"
if grep -q 'id: "dsh-codex-effort-slider"' lib/client.js \
   && grep -q 'PACKAGE_ID = "dsh-codex-effort-slider"' lib/index.js; then
  ok "内部 id 保持稳定（老用户的 localStorage 设置不会丢）"
else
  bad "内部 id 被改动过 —— 确认这是有意的（会让已装用户丢失设置）"
fi

# ── 5. 打包内容抽查 ───────────────────────────────────────────────────────
say "[5/6] 打包内容"
export npm_config_cache="${TMPDIR:-/tmp}/ces-npmcache"
PACK_JSON="$(npm pack --dry-run --json 2>/dev/null)"
node -e '
const fs = require("fs");
const raw = process.argv[1];
const data = JSON.parse(raw);
const files = (data[0] && data[0].files || []).map((f) => f.path);
const need = ["package.json", "lib/index.js", "lib/client.js", "cordis.patch.yml", "README.md", "LICENSE"];
const missing = need.filter((n) => !files.includes(n));
if (missing.length) { console.error("缺文件：" + missing.join(", ")); process.exit(1); }
console.log("  \u001b[32m✓\u001b[0m " + files.length + " 个文件，关键文件齐全");
' "$PACK_JSON" || die "打包内容不完整"

# ── 6. 预览页能生成 ───────────────────────────────────────────────────────
say "[6/6] 预览页生成"
if npm run preview >/tmp/ces-preview.log 2>&1; then
  ok "preview/panel.html 生成成功"
else
  tail -10 /tmp/ces-preview.log
  die "预览页生成失败（CSS/函数抽取的防漂移守卫可能拦住了）"
fi

say ""
say "=== 自检全部通过 ==="

# ── 按模式执行 ────────────────────────────────────────────────────────────
case "$MODE" in
  check)
    say "只做了自检。下一步可选："
    say "  ./publish.sh github   # 推到 GitHub"
    say "  ./publish.sh npm      # 发布到 npm"
    say "  ./publish.sh zip      # 打一个发给朋友的 zip"
    ;;

  github)
    command -v git >/dev/null || die "没装 git"
    if [ -d .git ]; then
      say "已有 git 仓库，直接提交"
    else
      git init
      git branch -M main
    fi
    git add -A
    git commit -m "feat: 档位按语义高度排序（上游 efforts 顺序反转也不会反向显示）" || say "没有新改动可提交"
    say ""
    say "接下来手动推："
    say "  git remote add origin https://github.com/yadelei114514/dsh-codex-effort-slider.git"
    say "  git push -u origin main"
    ;;

  npm)
    say "确认已登录：npm whoami"
    npm whoami >/dev/null 2>&1 || die "未登录 npm —— 先跑 npm login"
    say "发布 $PKG_NAME@$PKG_VERSION ..."
    npm publish --access public
    ok "已发布"
    say "朋友安装：dsh plugin --profile web add $PKG_NAME"
    ;;

  zip)
    command -v zip >/dev/null || die "没装 zip"
    mkdir -p dist
    OUT="dist/yadelei114514-dsh-codex-effort-slider-${PKG_VERSION}.zip"
    rm -f "$OUT"
    zip -qr "$OUT" . \
      -x 'node_modules/*' 'dist/*' '.git/*' '*.tgz' '.DS_Store' 'Thumbs.db'
    ok "$OUT（$(du -h "$OUT" | cut -f1)）"
    say "朋友拿到后：解压 → 设置 → 插件 → 添加插件 → 填解压出的目录路径"
    say "或者命令行：dsh plugin --profile web add link:\"<解压后的绝对路径>\""
    ;;

  *)
    die "未知模式：$MODE（可用：check / github / npm / zip）"
    ;;
esac
