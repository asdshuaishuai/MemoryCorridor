#!/bin/sh
# MemoryCorridor WebUI 人工测试台（一键）——等你有空点着用。
#
# 用法:
#   scripts/demo_webui.sh                    # 默认 vault=/tmp/corridor-demo-vault，端口 18713
#   PORT=19000 VAULT=~/tmp/kb scripts/demo_webui.sh
#   RESET=1 scripts/demo_webui.sh            # 清掉旧演示库重新种数据
#   SMOKE_ONLY=1 scripts/demo_webui.sh       # 只跑冒烟断言，不起驻留服务
#
# 行为:
#   1. 缺二进制则构建 cli/web（native）。
#   2. 初始化并种一个小型演示库：3 份来源、4 个页面（含一对同义改写页，
#      便于肉眼验证 search 与去冗余提名）；注册 demo embedding provider 并
#      手工提交 2 维演示向量（零模型依赖），让 Web 面混合检索立即有活可干。
#   3. 启动只读 loopback Web 服务，八条路由逐条冒烟（PASS/FAIL 计数）。
#   4. 服务驻留并打印浏览器地址、常用 curl 与 CLI 侧进阶玩法（调档等）；
#      Ctrl-C 停止。SMOKE_ONLY=1 时冒烟后直接退出。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAULT="${VAULT:-/tmp/corridor-demo-vault}"
PORT="${PORT:-18713}"
CLI="$ROOT/_build/native/debug/build/cli/cli.exe"
WEB="$ROOT/_build/native/debug/build/web/web.exe"
CLI_BIN=$(ls "$CLI" "$CLI.exe" 2>/dev/null | head -1 || true)
WEB_BIN=$(ls "$WEB" "$WEB.exe" 2>/dev/null | head -1 || true)
if [ -z "$CLI_BIN" ] || [ -z "$WEB_BIN" ]; then
  echo "== 缺 cli/web 二进制，构建中（moon build --target native cli web）"
  (cd "$ROOT" && moon build --target native cli web >/dev/null)
  CLI_BIN=$(ls "$CLI" "$CLI.exe" 2>/dev/null | head -1)
  WEB_BIN=$(ls "$WEB" "$WEB.exe" 2>/dev/null | head -1)
fi

cli() { printf '%s\n' "$1" | "$CLI_BIN"; }

if [ "${RESET:-0}" = "1" ] && [ -d "$VAULT" ]; then
  echo "== RESET=1：删除旧演示库 $VAULT"
  rm -rf "$VAULT"
fi

if [ ! -d "$VAULT/wiki" ]; then
  echo "== 种演示库 $VAULT"
  mkdir -p "$VAULT"
  cli "{\"op\":\"init\",\"vault\":\"$VAULT\",\"purpose\":\"WebUI 人工测试演示库\"}" >/dev/null
  mkdir -p "$VAULT/raw"
  printf '龙泉窑青瓷以粉青与梅子青两种釉色最为著名，釉料以石灰碱釉为基。\n' > "$VAULT/raw/celadon.md"
  printf '梅子青和粉青是龙泉窑最具代表性的两种青瓷釉色，配方基于石灰碱釉。\n' > "$VAULT/raw/glaze.md"
  printf '哥窑以开片釉闻名，紫口铁足是其辨识特征，与龙泉窑并列宋代名窑。\n' > "$VAULT/raw/ge-kiln.md"
  cli "{\"op\":\"scan\",\"vault\":\"$VAULT\"}" >/dev/null
  # 逐来源建工单并走完整分析-提交链
  for SRC in raw/celadon.md raw/glaze.md raw/ge-kiln.md; do
    ORDER=$(cli "{\"op\":\"plan\",\"vault\":\"$VAULT\"}" | python3 -c "
import json,sys
orders=json.load(sys.stdin)['result']
print(next(o['id'] for o in orders if o['source']=='$SRC'))")
    cli "{\"op\":\"context\",\"vault\":\"$VAULT\",\"order\":\"$ORDER\"}" >/dev/null
    cli "{\"op\":\"analysis-submit\",\"vault\":\"$VAULT\",\"order\":\"$ORDER\",\"analysis\":{\"entities\":[],\"concepts\":[],\"conflicts\":[],\"summary\":\"demo\"}}" >/dev/null
    mkdir -p "$VAULT/staging/$ORDER"
    case $SRC in
      raw/celadon.md) ID="concepts/celadon"; TITLE="龙泉青瓷"; BODY="龙泉窑青瓷以粉青与梅子青两种釉色最为著名。";;
      raw/glaze.md)   ID="concepts/glaze";   TITLE="梅子青釉"; BODY="梅子青与粉青是龙泉窑青瓷最具代表性的釉色。";;
      raw/ge-kiln.md) ID="concepts/ge-kiln"; TITLE="哥窑开片"; BODY="哥窑以开片釉闻名，紫口铁足是其辨识特征。";;
    esac
    printf -- "---\ntype: concept\ntitle: %s\nsources: [\"%s\"]\n---\n%s\n" "$TITLE" "$SRC" "$BODY" > "$VAULT/staging/$ORDER/0.md"
    cli "{\"op\":\"commit\",\"vault\":\"$VAULT\",\"order\":\"$ORDER\",\"at\":\"2026-11-05\",\"pages\":[{\"id\":\"$ID\",\"path\":\"wiki/$ID.md\",\"staged\":\"staging/$ORDER/0.md\"}]}" >/dev/null
  done
  cli "{\"op\":\"rebuild\",\"vault\":\"$VAULT\"}" >/dev/null

  # demo embedding provider（2 维手工向量，不依赖模型）：celadon 与 glaze 近、ge-kiln 远
  SPACE='{"id":"demo-v1","dimensions":2}'
  cli "{\"op\":\"provider-register\",\"vault\":\"$VAULT\",\"provider\":\"demo\",\"kind\":\"embedding\",\"space\":$SPACE,\"capabilities\":[\"embed\"],\"at\":\"2026-11-05T00:00:00Z\"}" >/dev/null
  python3 - "$VAULT" "$CLI_BIN" <<'PY'
import json, subprocess, sys
vault, cli = sys.argv[1], sys.argv[2]
space = {"id": "demo-v1", "dimensions": 2}
def run(req):
    p = subprocess.run([cli], input=json.dumps(dict(req, vault=vault)) + "\n",
                       text=True, capture_output=True, check=True)
    return json.loads(p.stdout)
plan = run({"op": "embedding-plan", "space": space})
assert plan["ok"], plan
vecs = {"concepts/celadon": [1, 0], "concepts/glaze": [0.97, 0.24], "concepts/ge-kiln": [0, 1]}
items = [{"page": it["page"], "sha256": it["sha256"], "values": vecs[it["page"]]}
         for it in plan["result"]["items"] if it["page"] in vecs]
res = run({"op": "embedding-submit", "space": space, "items": items, "provider": "demo"})
assert res["ok"], res
run({"op": "rebuild"})   # web 面需要目录编译收据跟随最新指纹（vectors 参与目录）
print("   demo 向量已提交:", [i["page"] for i in items])
PY
else
  echo "== 复用既有演示库 $VAULT（RESET=1 可重种）"
fi

echo "== 冒烟八条路由 http://127.0.0.1:$PORT"
"$WEB_BIN" "$VAULT" --port "$PORT" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT INT TERM
READY=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5
  if curl -fs -o /dev/null "http://127.0.0.1:$PORT/api/status"; then READY=1; break; fi
done
[ "$READY" = "1" ] || { echo "FAIL: web 服务未能启动"; exit 1; }

PASS=0; FAIL=0
hit() { # hit <name> <url> <grep-pattern>
  body=$(curl -fs "$2" 2>/dev/null || true)
  if printf '%s' "$body" | grep -q "$3"; then
    PASS=$((PASS+1)); echo "   PASS $1"
  else
    FAIL=$((FAIL+1)); echo "   FAIL $1  ($2)"
  fi
}
hit "/ 视觉三视图(HTML)"      "http://127.0.0.1:$PORT/"                       "<html\|<!doctype"
hit "/api/status"             "http://127.0.0.1:$PORT/api/status"             '"ok":true'
hit "/api/pages"              "http://127.0.0.1:$PORT/api/pages"              'concepts/celadon'
hit "/api/page"               "http://127.0.0.1:$PORT/api/page?id=concepts/celadon" '龙泉'
hit "/api/search 关键词"      "http://127.0.0.1:$PORT/api/search?q=%E9%9D%92%E7%93%B7" 'hits'
vec_body=$(curl -fsG "http://127.0.0.1:$PORT/api/search" --data-urlencode "q=" --data-urlencode 'query_vector={"space":{"id":"demo-v1","dimensions":2},"values":[1,0]}')
if printf '%s' "$vec_body" | grep -q 'concepts/celadon'; then PASS=$((PASS+1)); echo "   PASS /api/search 向量混合"; else FAIL=$((FAIL+1)); echo "   FAIL /api/search 向量混合"; fi
hit "/api/tree"               "http://127.0.0.1:$PORT/api/tree"               '"ok":true'
hit "/api/topics"             "http://127.0.0.1:$PORT/api/topics"             '"ok":true'
hit "/api/lint"               "http://127.0.0.1:$PORT/api/lint"               '"ok":true'
# 负例：只读与 Host 校验
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/status"); [ "$code" = "405" ] && { PASS=$((PASS+1)); echo "   PASS POST 405"; } || { FAIL=$((FAIL+1)); echo "   FAIL POST 期望 405 得 $code"; }
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$PORT/api/status"); [ "$code" = "403" ] && { PASS=$((PASS+1)); echo "   PASS Host 403"; } || { FAIL=$((FAIL+1)); echo "   FAIL Host 期望 403 得 $code"; }
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/nope"); [ "$code" = "404" ] && { PASS=$((PASS+1)); echo "   PASS 未知路由 404"; } || { FAIL=$((FAIL+1)); echo "   FAIL 未知路由 期望 404 得 $code"; }

echo "== 冒烟结果: PASS=$PASS FAIL=$FAIL"
if [ "${SMOKE_ONLY:-0}" = "1" ]; then
  [ "$FAIL" = "0" ] || exit 1
  echo "== SMOKE_ONLY 完成"; exit 0
fi

cat <<EOF

== Web 服务已驻留: http://127.0.0.1:$PORT   (Ctrl-C 停止)
   浏览器打开上面地址看三视图；库目录: $VAULT

可玩的项目（README 之外的人测清单）:
  浏览器:
    /                      视觉三视图（目录/搜索/详情，纯静态渲染）
    搜索框输入「青瓷」      关键词排名；同义改写页 celadon/glaze 应同批靠前
  curl:
    curl -s 'http://127.0.0.1:$PORT/api/search?q=%E7%A3%81%E5%8F%A3%E9%93%81%E8%B6%B3'
    curl -s 'http://127.0.0.1:$PORT/api/search?q=&query_vector={"space":{"id":"demo-v1","dimensions":2},"values":[1,0]}' | python3 -m json.tool
      （向量查询：celadon 应排第一，glaze 次之，ge-kiln 靠后）
  CLI 进阶（Web 面只读，写面与治理走 cli/mcp，同一引擎）:
    "$CLI_BIN" <<< '{"op":"page-redundancy","vault":"'$VAULT'","space":{"id":"demo-v1","dimensions":2}}'          # 默认 0.92 档: celadon/glaze 应被 vector_cosine 提名
    "$CLI_BIN" <<< '{"op":"page-redundancy","vault":"'$VAULT'","space":{"id":"demo-v1","dimensions":2},"cosine_floor":0.995}'   # 调高档: 0.9676 对消失（续二十七）
    "$CLI_BIN" <<< '{"op":"search","vault":"'$VAULT'","query":"青瓷","limit":5}' | python3 -m json.tool
    "$CLI_BIN" <<< '{"op":"lint","vault":"'$VAULT'"}'   # 冗余 warning 谓词
  多模态（需 fetch_clip.sh + cargo build adapters/embed-rs，可选）:
    往 $VAULT/raw 放一张 .png 并写页面引用它，再用 demo provider 换
    capabilities=["embed","embed-multimodal"] 注册后 embedding-plan 会发图片任务。
EOF

wait $SERVER
