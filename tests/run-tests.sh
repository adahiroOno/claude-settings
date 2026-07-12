#!/usr/bin/env bash
# 回帰テストスイート: フック・statusline・インストールの挙動を検証する。
# 依存: bash, jq。副作用なし(mktemp サンドボックス + 専用セッションIDのみ使用)。
# 使い方: bash tests/run-tests.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/home/hooks/session-budget-guard.sh"
HEAVY="$ROOT/home/hooks/guard-heavy-read.sh"
NOTICE="$ROOT/home/hooks/handoff-notice.sh"
STATUS="$ROOT/home/statusline.sh"
EST="$ROOT/home/skills/cost-audit/scripts/estimate_tokens.sh"
INSTALL="$ROOT/scripts/install.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
ng()   { FAIL=$((FAIL+1)); printf '  NG  %s\n' "$1"; }
assert_exit() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (expected exit=$2, got $3)"; fi
}

SB="$(mktemp -d)"
# TMPDIR をサンドボックス配下に隔離する。ガードや statusline が作る状態ファイル・
# 警告マーカー(セッション非依存の共通マーカー含む)がすべてここに入るため、
# 本番セッションのマーカーを汚染せず、テスト間の残留干渉も起きない。
export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

user_line()  { printf '{"uuid":"u%s","type":"user","message":{"role":"user","content":"p%s"}}\n' "$1" "$1"; }
usage_line() { # id model in cc cr out
  printf '{"uuid":"a%s","type":"assistant","message":{"id":"m%s","model":"%s","usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":%d}}}\n' \
    "$1" "$1" "$2" "$3" "$4" "$5" "$6"
}
guard_in() { # event session tool fpath transcript
  printf '{"hook_event_name":"%s","transcript_path":"%s","session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$5" "$2" "$3" "$4"
}

echo "== 1. 構文・JSON妥当性 =="
for s in "$ROOT"/home/*.sh "$ROOT"/home/hooks/*.sh "$ROOT"/home/skills/cost-audit/scripts/*.sh "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  if bash -n "$s" 2>/dev/null; then ok "bash -n $(basename "$s")"; else ng "bash -n $s"; fi
done
for j in "$ROOT/home/settings.json" "$ROOT/project-template/settings.json"; do
  if jq -e . "$j" >/dev/null 2>&1; then ok "jq $(basename "$(dirname "$j")")/settings.json"; else ng "jq $j"; fi
done

echo "== 2. guard-heavy-read =="
H() { printf '{"tool_input":{"command":"%s"}}' "$1" | bash "$HEAVY" 2>/dev/null; echo $?; }
assert_exit "cat package-lock.json をブロック" 2 "$(H 'cat package-lock.json')"
assert_exit "cat Gemfile.lock をブロック" 2 "$(H 'cat Gemfile.lock')"
assert_exit "cat .venv/x.py をブロック" 2 "$(H 'cat .venv/lib/x.py')"
assert_exit "cat src/main.py は許可" 0 "$(H 'cat src/main.py')"
assert_exit "パイプ付き部分抽出は許可" 0 "$(H 'cat flake.lock | jq .nodes')"
assert_exit "rg は許可" 0 "$(H 'rg foo src/')"

echo "== 3. 予算ガード: 閾値・グレースレーン =="
TR="$SB/hard.jsonl"
{ user_line 1; usage_line 1 claude-sonnet-5 10000 0 0 400000; } > "$TR"   # $6.15 > $5
guard_in PreToolUse tst-h1 Read x "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "上限超過で Read ブロック" 2 $?
guard_in PreToolUse tst-h1 Write /x/.claude/handoff.md "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "グレースレーン: handoff.md への Write 許可" 0 $?
guard_in PreToolUse tst-h1 Write /x/src/main.py "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "上限超過で他ファイル Write ブロック" 2 $?
guard_in UserPromptSubmit tst-h1 "" "" "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "上限超過で新規プロンプトブロック" 2 $?
msg=$(guard_in PreToolUse tst-h1 Read x "$TR" | bash "$GUARD" 2>&1 >/dev/null || true)
case "$msg" in *handoff.md*) ok "上限メッセージに handoff 手順を含む";; *) ng "上限メッセージに handoff 手順がない";; esac

echo "== 4. 予算ガード: 差分解析の正確性 =="
TR="$SB/inc.jsonl"; SID=tst-i1
{ user_line 1; usage_line 1 claude-sonnet-5 10000 0 0 14000; user_line 2; usage_line 2 claude-sonnet-5 10000 0 0 14000; } > "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
st=$(cat "${TMPDIR:-/tmp}/claude-budget-state-$SID" 2>/dev/null || echo "")
case "$st" in *" 480000.0000 2 10000") ok "累計が検算値と一致 (raw=480000, turns=2, ctx=10000)";; *) ng "累計不一致: [$st]";; esac
printf '{"uuid":"u3","type":"user","message":{"role":"user","content":"p3' >> "$TR"   # 書きかけ行
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
st2=$(cat "${TMPDIR:-/tmp}/claude-budget-state-$SID" 2>/dev/null || echo "")
case "$st2" in *" 480000.0000 2 10000") ok "書きかけ行は繰り越し(turns=2 のまま)";; *) ng "書きかけ行を誤処理: [$st2]";; esac
printf '"}}\n' >> "$TR"; { user_line 4; usage_line 4 claude-sonnet-5 10000 0 0 14000; usage_line 5 claude-haiku-4-5 30000 0 0 2000; } >> "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
st3=$(cat "${TMPDIR:-/tmp}/claude-budget-state-$SID" 2>/dev/null || echo "")
# 期待: raw = 480000 + 240000(sonnet) + 30000*1+2000*5=40000(haiku) = 760000, turns=4
case "$st3" in *" 760000.0000 4 30000") ok "完結後の差分+haiku単価を正しく累計(ctx更新含む)";; *) ng "差分累計不一致: [$st3]";; esac
user_line 9 > "$TR"   # ファイル縮小 → リセット
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
st4=$(cat "${TMPDIR:-/tmp}/claude-budget-state-$SID" 2>/dev/null || echo "")
case "$st4" in *" 0.0000 1 0") ok "ファイル縮小でフル再計算";; *) ng "縮小時の再計算失敗: [$st4]";; esac

echo "== 5. ペースガード =="
TR="$SB/pace.jsonl"; SID=tst-p1
for i in 1 2 3 4 5; do user_line "$i"; usage_line "$i" claude-sonnet-5 10000 0 0 14000; done > "$TR"  # 5T $1.2 > 許容0.6
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "ペース超過で警告(1回目)" 2 $?
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "同ターン内は再警告しない" 0 $?
for i in 6 7 8 9 10; do user_line "$i"; usage_line "$i" claude-sonnet-5 10000 0 0 14000; done >> "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1; assert_exit "5ターン経過後は再警告" 2 $?
TR2="$SB/pace-ok.jsonl"
for i in 1 2 3 4 5; do user_line "$i"; usage_line "$i" claude-sonnet-5 5000 0 0 3000; done > "$TR2"   # $0.30 < 0.6
guard_in PreToolUse tst-p2 Read x "$TR2" | bash "$GUARD" >/dev/null 2>&1; assert_exit "ペース内は無干渉" 0 $?
# 公式仕様: UserPromptSubmit の exit 2 はプロンプトを消去し stderr はユーザーのみ。
# ペース・肥大・警告の3段は UserPromptSubmit で発火してはならない(プロンプト誤消去の防止)。
guard_in UserPromptSubmit tst-p3 "" "" "$TR" | bash "$GUARD" >/dev/null 2>&1
assert_exit "ペース超過でも UserPromptSubmit は素通し(プロンプトを消去しない)" 0 $?
TRC="$SB/pace-ctx.jsonl"
{ user_line 1; usage_line 1 claude-sonnet-5 2000 0 200000 1000; } > "$TRC"   # ctx 202k > 120k
guard_in UserPromptSubmit tst-p4 "" "" "$TRC" | bash "$GUARD" >/dev/null 2>&1
assert_exit "ctx 超過でも UserPromptSubmit は素通し(肥大警告は PreToolUse 限定)" 0 $?

echo "== 6. handoff-notice =="
W="$SB/proj"; mkdir -p "$W/.claude"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); [ -z "$out" ] && ok "handoff なし → 出力なし" || ng "handoff なしで出力あり"
echo x > "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); case "$out" in *handoff.md*) ok "新しい handoff → 案内あり";; *) ng "案内なし";; esac
touch -d '3 days ago' "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); [ -z "$out" ] && ok "48時間超の handoff → 案内なし" || ng "古い handoff を案内した"

echo "== 7. statusline(公式 context_window / effort / rate_limits を使用)=="
strip() { sed 's/\x1b\[[0-9;]*m//g'; }   # ANSI色除去
TR="$SB/sl.jsonl"; SID=tst-s1
{ user_line 1; usage_line 1 claude-sonnet-5 3000 2000 42000 500; } > "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1   # ターン数の状態ファイル生成
# 公式 context_window.current_usage を入力JSONで渡す: ctx=3k+2k+42k=47k(閾値12万の39%)、cache=42k/47k=89%
CW='"context_window":{"current_usage":{"input_tokens":3000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":42000,"output_tokens":500}}'
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":0.08},"transcript_path":"%s","session_id":"%s","output_style":{"name":"terse"},"effort":{"level":"high"},"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":23.5}},%s}' "$TR" "$SID" "$CW" | bash "$STATUS" | strip)
case "$out" in *"⚡ high"*) ok "effort 表示(公式フィールド)";; *) ng "effort不正: [$out]";; esac
case "$out" in *"💰 \$0.08/\$5"*"1%"*) ok "予算バー+使用率%";; *) ng "予算バー不正: [$out]";; esac
case "$out" in *"🧠 47k/120k"*"39%"*) ok "ctxバー(公式context_window由来)";; *) ng "ctxバー不正: [$out]";; esac
case "$out" in *"█"*"░"*) ok "使用率バー(█/░)描画";; *) ng "バー文字なし: [$out]";; esac
case "$out" in *"🎯 10T:\$0.80"*) ok "ペース表示(目標内🎯)";; *) ng "ペース不正: [$out]";; esac
case "$out" in *"💾 89%"*) ok "キャッシュ率(current_usage由来)";; *) ng "キャッシュ率不正: [$out]";; esac
case "$out" in *"🔄 1"*) ok "ターン数表示";; *) ng "ターン数不正: [$out]";; esac
case "$out" in *"📊"*"5h:24%"*) ok "レート制限表示(サブスク)";; *) ng "レート制限不正: [$out]";; esac
case "$out" in *"✍️ terse"*) ok "出力スタイル表示";; *) ng "スタイル不正: [$out]";; esac
case "$out" in *"💭"*) ok "thinking有効表示";; *) ng "thinking不正: [$out]";; esac
# effort/rate_limits なし(従量制・非対応モデル想定)→ ⚡・📊 が出ない
out=$(printf '{"model":{"display_name":"Haiku"},"cost":{"total_cost_usd":0.30},"session_id":"%s",%s}' "$SID" "$CW" | bash "$STATUS" | strip)
case "$out" in *"⚡"*) ng "effort非対応なのに表示された: [$out]";; *) ok "effort不在時は非表示";; esac
case "$out" in *"📊"*) ng "レート無しなのに表示された: [$out]";; *) ok "レート不在時は非表示";; esac
# 予算超過 → 🛑・満杯・実値%
out=$(printf '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":6.00},"session_id":"%s",%s}' "$SID" "$CW" | bash "$STATUS" | strip)
case "$out" in *"🛑 \$6.00/\$5"*"██████████"*"120%"*) ok "予算超過で🛑・満杯・実値%(120)";; *) ng "予算超過不正: [$out]";; esac
case "$out" in *"🔥 10T"*) ok "ペース超過で🔥";; *) ng "ペース超過不正: [$out]";; esac
# トークン内訳(opt-in)
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":0.08},"session_id":"%s",%s}' "$SID" "$CW" | bash "$STATUS" | strip)
case "$out" in *"🎫"*) ng "内訳が既定で表示(opt-inのはず): [$out]";; *) ok "トークン内訳は既定オフ";; esac
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":0.08},"session_id":"%s",%s}' "$SID" "$CW" | CLAUDE_STATUSLINE_TOKENS=1 bash "$STATUS" | strip)
case "$out" in *"🎫 in:3k rd:42k wr:2k out:500"*) ok "トークン内訳(opt-in・current_usage由来)";; *) ng "内訳不正: [$out]";; esac
out=$(printf '{"model":{"display_name":"Sonnet"}}' | bash "$STATUS" 2>&1 | strip)
case "$out" in "🤖 Sonnet") ok "最小入力でも安全(エラーなし)";; *) ng "最小入力不正: [$out]";; esac

echo "== 8. install.sh 保持マージ =="
D="$SB/claudehome"; mkdir -p "$D"
cat > "$D/settings.json" <<'EOF'
{"model":"opus","env":{"MY_VAR":"keep"},"apiKeyHelper":"/bin/k.sh","permissions":{"deny":["Read(./mine/**)"],"allow":["Bash(make:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/my-own-hook.sh"}]}],"Notification":[{"hooks":[{"type":"command","command":"~/notify.sh"}]}]}}
EOF
CLAUDE_CONFIG_DIR="$D" bash "$INSTALL" >/dev/null 2>&1
m=$(jq -r '.model' "$D/settings.json"); [ "$m" = "sonnet" ] && ok "model をテンプレ値に更新" || ng "model=$m"
v=$(jq -r '.env.MY_VAR' "$D/settings.json"); [ "$v" = "keep" ] && ok "既存 env を保持" || ng "env 喪失"
uh=$(jq -r '[.hooks.PreToolUse[].hooks[].command] | index("~/my-own-hook.sh")' "$D/settings.json")
[ "$uh" != "null" ] && ok "既存 PreToolUse フックを保持(消えない)" || ng "既存フックが消えた"
th=$(jq -r '[.hooks.PreToolUse[].hooks[].command] | any(test("session-budget-guard"))' "$D/settings.json")
[ "$th" = "true" ] && ok "テンプレのガードフックも追加" || ng "ガードフックが入らない"
nh=$(jq -r '.hooks.Notification[0].hooks[0].command' "$D/settings.json")
[ "$nh" = "~/notify.sh" ] && ok "テンプレに無いイベント(Notification)も保持" || ng "Notification フック喪失"
k=$(jq -r '.apiKeyHelper' "$D/settings.json"); [ "$k" = "/bin/k.sh" ] && ok "独自キーを保持" || ng "独自キー喪失"
d=$(jq -r '.permissions.deny | index("Read(./mine/**)")' "$D/settings.json"); [ "$d" != "null" ] && ok "deny を和集合" || ng "deny 喪失"

echo "== 9. トークン見積り(日本語) =="
printf 'これは日本語のテストです。' > "$SB/jp.txt"
mb=$(bash "$EST" "$SB/jp.txt" | awk 'NR==2{print $3}')
[ "${mb:-0}" -gt 0 ] 2>/dev/null && ok "マルチバイト文字を計数 (mb=$mb)" || ng "マルチバイト計数失敗 (mb=$mb)"

echo "== 10. ガードの増分性能(2MB トランスクリプト) =="
TR="$SB/big.jsonl"; SID=tst-perf
for i in $(seq 1 40); do user_line "$i"; usage_line "$i" claude-sonnet-5 2000 100 20000 1000; done > "$TR"
# 2MB程度まで水増し(usage を持たない中間行)
yes '{"uuid":"filler","type":"progress","data":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' | head -20000 >> "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1   # 初回(フル)
{ user_line 41; usage_line 41 claude-sonnet-5 2000 100 20000 1000; } >> "$TR"
t0=$(date +%s%N)
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1   # 2回目(増分のみ)
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 500 ]; then ok "増分呼び出し ${ms}ms (< 500ms)"; else ng "増分呼び出しが遅い: ${ms}ms"; fi

echo "== 11. バックグラウンド消費スキャナ =="
SCAN="$ROOT/home/skills/cost-audit/scripts/scan_background.sh"
BADP="$SB/badproj"; mkdir -p "$BADP/.claude/hooks"
echo 'claude -p "summarize" --model haiku' > "$BADP/.claude/hooks/expensive-hook.sh"
out=$(bash "$SCAN" "$BADP" 2>/dev/null)
case "$out" in *expensive-hook.sh*) ok "フック内の claude -p を検出";; *) ng "claude -p フック未検出";; esac
CLEANP="$SB/cleanproj"; mkdir -p "$CLEANP/.claude/hooks"
echo 'jq -r .foo input.json' > "$CLEANP/.claude/hooks/ok-hook.sh"
out=$(bash "$SCAN" "$CLEANP" 2>/dev/null)
case "$out" in *ok-hook.sh*) ng "無害なフックを誤検出";; *) ok "無害なフックは検出しない";; esac
case "$out" in *"結果:"*) ok "サマリ行を出力";; *) ng "サマリ行なし";; esac

echo "== 12. 監査ドキュメントの整合性 =="
CHECK="$ROOT/home/skills/cost-audit/references/checklist.md"
CMAP="$ROOT/home/skills/cost-audit/references/coverage-map.md"
[ -f "$CMAP" ] && ok "coverage-map.md が存在" || ng "coverage-map.md がない"
for cat in A B C D E F G H I; do
  grep -q "^## $cat\." "$CHECK" && ok "checklist にカテゴリ $cat" || ng "checklist にカテゴリ $cat がない"
done
# coverage-map が参照する全チェック項目 ID が checklist に実在するか
missing=0
for id in $(grep -oE '[A-G]-[0-9]+b?' "$CMAP" | sort -u); do
  grep -q "^### $id\." "$CHECK" || { ng "coverage-map の参照先 $id が checklist にない"; missing=1; }
done
[ "$missing" -eq 0 ] && ok "coverage-map の全参照先が checklist に実在"
grep -q 'coverage-map' "$ROOT/home/skills/cost-audit/SKILL.md" && ok "SKILL.md がフェーズ0で coverage-map を参照" || ng "SKILL.md が coverage-map 未参照"

echo "== 13. 仕様ドリフト検知 =="
SELFTEST="$ROOT/home/skills/cost-audit/scripts/selftest_guard.sh"
if bash "$SELFTEST" "$GUARD" >/dev/null 2>&1; then ok "自己診断カナリアが合格"; else ng "自己診断カナリアが失敗"; fi
# フック入力スキーマドリフト: transcript_path が無い入力 → 1日1回警告
rm -f "${TMPDIR:-/tmp}/claude-budget-schemawarn"
printf '{"hook_event_name":"PreToolUse","tool_name":"Read"}' | bash "$GUARD" >/dev/null 2>&1
assert_exit "フィールド欠落入力で警告(初回)" 2 $?
printf '{"hook_event_name":"PreToolUse","tool_name":"Read"}' | bash "$GUARD" >/dev/null 2>&1
assert_exit "同日2回目は素通し" 0 $?
rm -f "${TMPDIR:-/tmp}/claude-budget-schemawarn"
# トランスクリプト解釈不能(200KB超・集計ゼロ)→ セッション毎1回警告
TR="$SB/drift.jsonl"; SID=tst-d1
yes '{"totally":"different","schema":"vXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}' | head -3000 > "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
assert_exit "集計ゼロの大型セッションで警告(初回)" 2 $?
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
assert_exit "同セッション2回目は素通し" 0 $?
# 本体更新検知(SessionStart)
BIND="$SB/bin"; mkdir -p "$BIND"
printf '#!/bin/sh\nexit 0\n' > "$BIND/claude"; chmod +x "$BIND/claude"
CFG="$SB/cfg"; mkdir -p "$CFG"; WV="$SB/projv"; mkdir -p "$WV"
out=$(printf '{"cwd":"%s"}' "$WV" | PATH="$BIND:$PATH" CLAUDE_CONFIG_DIR="$CFG" bash "$NOTICE")
case "$out" in *更新されています*) ng "初回でフィンガープリント未保存のまま通知";; *) ok "初回は保存のみ(通知なし)";; esac
sleep 1.1; echo "# changed" >> "$BIND/claude"
out=$(printf '{"cwd":"%s"}' "$WV" | PATH="$BIND:$PATH" CLAUDE_CONFIG_DIR="$CFG" bash "$NOTICE")
case "$out" in *更新されています*) ok "本体更新を検知して再監査を促す";; *) ng "本体更新を検知できない: [$out]";; esac

echo "== 14. コンテキスト肥大ガード =="
TR="$SB/ctx.jsonl"; SID=tst-c1
{ user_line 1; usage_line 1 claude-sonnet-5 2000 0 200000 1000; } > "$TR"   # ctx=202k > 120k
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
assert_exit "ctx 閾値超過で介入(初回)" 2 $?
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1
assert_exit "同セッション2回目は素通し(ctx)" 0 $?
rm -f "${TMPDIR:-/tmp}/claude-budget-ctx-$SID" "${TMPDIR:-/tmp}/claude-budget-state-$SID"
msg=$(guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" 2>&1 >/dev/null || true)
case "$msg" in *explore*handoff.md*) ok "介入メッセージに explore 委譲と handoff 手順を含む";; *) ng "介入メッセージ不備: [$msg]";; esac
TR2="$SB/ctx-ok.jsonl"
{ user_line 1; usage_line 1 claude-sonnet-5 2000 0 50000 1000; } > "$TR2"   # ctx=52k < 120k
guard_in PreToolUse tst-c2 Read x "$TR2" | bash "$GUARD" >/dev/null 2>&1
assert_exit "閾値未満は無干渉(ctx)" 0 $?

echo "== 15. thinking エクスポート(モデル呼び出しなしの検証) =="
EXPORT="$ROOT/home/skills/cost-audit/scripts/export_thinking.sh"
T15="$SB/thinking.jsonl"
printf '{"uuid":"a1","type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"content":[{"type":"thinking","thinking":"テスト思考内容"},{"type":"text","text":"回答"}]}}\n' > "$T15"
out=$(bash "$EXPORT" "$T15")
case "$out" in *"テスト思考内容"*) ok "中身ありのthinkingを抽出";; *) ng "抽出失敗: [$out]";; esac
case "$out" in *"モデル呼び出しは発生していません"*) ok "コストゼロである旨を明記";; *) ng "コスト説明が欠落";; esac
T15b="$SB/thinking-empty.jsonl"
printf '{"uuid":"a1","type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"content":[{"type":"thinking","thinking":""}]}}\n' > "$T15b"
out=$(bash "$EXPORT" "$T15b")
case "$out" in *"omitted"*"summarized"*) ok "空thinking(omitted)の説明を表示";; *) ng "空thinkingの説明なし: [$out]";; esac
T15c="$SB/no-thinking.jsonl"
printf '{"uuid":"a1","type":"assistant","message":{"content":[{"type":"text","text":"回答のみ"}]}}\n' > "$T15c"
out=$(bash "$EXPORT" "$T15c")
case "$out" in *"thinking ブロックはありません"*) ok "thinkingなしケースを正しく報告";; *) ng "不正: [$out]";; esac
bash "$EXPORT" "$T15" "$SB/exported.md" >/dev/null
[ -f "$SB/exported.md" ] && grep -q "テスト思考内容" "$SB/exported.md" && ok "ファイル出力モードが機能" || ng "ファイル出力失敗"

echo "== 16. README のアーキテクチャ記述と実設定値の整合性 =="
RM="$ROOT/README.md"
grep -q '## 制御の仕組み' "$RM" && ok "README に「制御の仕組み」節がある" || ng "README にアーキテクチャ説明がない"
grep -q 'session-budget-guard.sh.*PreToolUse.*UserPromptSubmit\|PreToolUse.*UserPromptSubmit' "$RM" && ok "README に発火イベントの記載" || ng "発火イベントの記載なし"
# settings.json の既定値と README 記載値が一致しているか(閾値ドリフト検知)
def_budget=$(jq -r '.env.CLAUDE_SESSION_BUDGET_USD' "$ROOT/home/settings.json")
def_turn=$(jq -r '.env.CLAUDE_TURN_BUDGET_USD' "$ROOT/home/settings.json")
def_ctx=$(jq -r '.env.CLAUDE_CTX_LIMIT_TOKENS' "$ROOT/home/settings.json")
[ "$def_budget" = "5" ] && grep -q '既定 \$5' "$RM" && ok "予算既定値(\$5)が settings.json と README で一致" || ng "予算既定値が不一致(settings=$def_budget)"
[ "$def_turn" = "0.10" ] && grep -q '既定 \$1/10T' "$RM" && ok "ペース既定値(10T≒\$1)が一致" || ng "ペース既定値が不一致(settings=$def_turn)"
[ "$def_ctx" = "120000" ] && grep -q '既定 12万トークン' "$RM" && ok "ctx既定値(12万)が一致" || ng "ctx既定値が不一致(settings=$def_ctx)"
# hooks 設定側にも3フックが登録されているか(READMEの説明とsettings.jsonの実配線の整合)
for h in guard-heavy-read.sh session-budget-guard.sh handoff-notice.sh; do
  grep -q "$h" "$ROOT/home/settings.json" && ok "settings.json に $h が配線済み" || ng "$h が settings.json に無い"
done
ri=$(jq -r '.statusLine.refreshInterval' "$ROOT/home/settings.json")
[ "$ri" = "5" ] && ok "statusLine.refreshInterval が設定済み(モデル切替等イベント外の変更に追随)" || ng "refreshInterval 未設定: $ri"
# 仕様ドリフト追随: 公式ドキュメントから削除された env 変数を配布しない
jq -e '.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE == "1"' "$ROOT/home/settings.json" >/dev/null && ok "env にタイトル生成停止(公式文書化済みの変数)" || ng "CLAUDE_CODE_DISABLE_TERMINAL_TITLE 未設定"
jq -e '.env | has("DISABLE_NON_ESSENTIAL_MODEL_CALLS") | not' "$ROOT/home/settings.json" >/dev/null && ok "廃止変数 DISABLE_NON_ESSENTIAL_MODEL_CALLS を配布していない" || ng "廃止変数が settings.json に残存"
grep -q '^maxTurns: [0-9]' "$ROOT/home/agents/explore.md" && ok "explore に maxTurns 上限(サブエージェント暴走の決定論的天井)" || ng "explore に maxTurns がない"

echo "== 17. プロンプト品質(手戻り削減)レバー =="
REFINE="$ROOT/home/skills/refine/SKILL.md"
[ -f "$REFINE" ] && ok "refine スキルが存在" || ng "refine スキルがない"
grep -q '^name: refine$' "$REFINE" && ok "frontmatter name: refine" || ng "frontmatter name 不正"
grep -q '^description: .*refine' "$REFINE" && ok "description に発火条件(refine)を含む" || ng "description 不備"
grep -q '完了条件' "$REFINE" && grep -q '要確認' "$REFINE" && ok "仕様テンプレート(完了条件・要確認)を含む" || ng "仕様テンプレート欠落"
grep -q 'ファイル探索をしない' "$REFINE" && ok "整形段階の探索禁止ルールを含む" || ng "探索禁止ルール欠落"
grep -q '## 依頼の受け方' "$ROOT/home/CLAUDE.md" && ok "CLAUDE.md に確認ファースト規範(依頼の受け方)" || ng "CLAUDE.md に確認ファースト規範がない"
grep -q '確認質問を1つだけ' "$ROOT/home/CLAUDE.md" && ok "確認は1問だけの制約を明記(質問攻めの防止)" || ng "確認1問の制約なし"
grep -q '^### C-7\.' "$CHECK" && ok "checklist に C-7(手戻りループ)" || ng "checklist に C-7 がない"
grep -q 'C-7' "$CMAP" && ok "coverage-map が C-7 を参照" || ng "coverage-map に C-7 参照がない"
grep -q '/refine' "$RM" && grep -q '手戻りの削減' "$RM" && ok "README にレバー7(手戻り削減)の記載" || ng "README にレバー7の記載がない"
# 常駐コストの回帰防止: 規範追加後も CLAUDE.md が肥大化していないこと
tok=$(bash "$EST" "$ROOT/home/CLAUDE.md" | awk 'NR==2{print $4}')
[ "$tok" -lt 1000 ] 2>/dev/null && ok "グローバル CLAUDE.md の常駐コストが 1000 トークン未満($tok)" || ng "CLAUDE.md が肥大化: $tok トークン"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
