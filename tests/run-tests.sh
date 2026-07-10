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
cleanup() { rm -rf "$SB"; rm -f "${TMPDIR:-/tmp}"/claude-budget-*-tst* 2>/dev/null; }
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

echo "== 6. handoff-notice =="
W="$SB/proj"; mkdir -p "$W/.claude"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); [ -z "$out" ] && ok "handoff なし → 出力なし" || ng "handoff なしで出力あり"
echo x > "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); case "$out" in *handoff.md*) ok "新しい handoff → 案内あり";; *) ng "案内なし";; esac
touch -d '3 days ago' "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); [ -z "$out" ] && ok "48時間超の handoff → 案内なし" || ng "古い handoff を案内した"

echo "== 7. statusline =="
TR="$SB/sl.jsonl"; SID=tst-s1
{ user_line 1; usage_line 1 claude-sonnet-5 3000 2000 42000 500; } > "$TR"
guard_in PreToolUse $SID Read x "$TR" | bash "$GUARD" >/dev/null 2>&1   # 状態ファイル生成
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":0.08},"transcript_path":"%s","session_id":"%s"}' "$TR" "$SID" | bash "$STATUS")
case "$out" in *"T:1"*"10T≈\$0.80"*"ctx:47k"*) ok "ペース+ctx 表示: [$out]";; *) ng "statusline 表示不正: [$out]";; esac
out=$(printf '{"model":{"display_name":"Sonnet"}}' | bash "$STATUS")
case "$out" in "[Sonnet]") ok "最小入力でも安全に表示";; *) ng "最小入力で不正: [$out]";; esac

echo "== 8. install.sh 保持マージ =="
D="$SB/claudehome"; mkdir -p "$D"
cat > "$D/settings.json" <<'EOF'
{"model":"opus","env":{"MY_VAR":"keep"},"apiKeyHelper":"/bin/k.sh","permissions":{"deny":["Read(./mine/**)"],"allow":["Bash(make:*)"]}}
EOF
CLAUDE_CONFIG_DIR="$D" bash "$INSTALL" >/dev/null 2>&1
m=$(jq -r '.model' "$D/settings.json"); [ "$m" = "sonnet" ] && ok "model をテンプレ値に更新" || ng "model=$m"
v=$(jq -r '.env.MY_VAR' "$D/settings.json"); [ "$v" = "keep" ] && ok "既存 env を保持" || ng "env 喪失"
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
for cat in A B C D E F G H; do
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

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
