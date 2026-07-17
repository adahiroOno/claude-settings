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
# CLAUDE_CONFIG_DIR もサンドボックスへ隔離する。handoff-notice の本体更新検知は
# フィンガープリントを $CLAUDE_CONFIG_DIR/.claude-code-fingerprint に保存するため、
# 隔離しないと本番 $HOME/.claude の古い値との差分で「更新通知」が紛れ込み、
# handoff テストがフレーキーになる(section 13 は自前の CFG を明示指定して上書き)。
export CLAUDE_CONFIG_DIR="$SB/cfghome"; mkdir -p "$CLAUDE_CONFIG_DIR"
# statusline の 1日合計(📅)は cost-daily/ の当日寄与を全セッション合算するため、
# テスト中に各セクションのガード実行が積む寄与が後続の statusline 描画へ漏れ出す。
# 既定でオフにして描画を決定論的にし、24 章だけ明示的に CLAUDE_STATUSLINE_DAILY=1 で検証する。
export CLAUDE_STATUSLINE_DAILY=0
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

user_line()  { printf '{"uuid":"u%s","type":"user","message":{"role":"user","content":"p%s"}}\n' "$1" "$1"; }
usage_line() { # id model in cc cr out
  printf '{"uuid":"a%s","type":"assistant","message":{"id":"m%s","model":"%s","usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":%d}}}\n' \
    "$1" "$1" "$2" "$3" "$4" "$5" "$6"
}
# 予算ガードの状態ファイルを決定論的にシードする(statusline のコスト/ターン表示検証用)。
# 形式: "offset raw turns ctx"。offset=0 にすることでトランスクリプトの有無や
# サイズに関係なく陳腐化判定を通過し、raw/1e6 のコストが必ず表示される。
seed_state() { # session raw turns [ctx]
  printf '0 %s %s %s\n' "$2" "$3" "${4:-1000}" > "$TMPDIR/claude-budget-state-$1"
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
TRF="$SB/fable.jsonl"; SIDF=tst-f1
{ user_line 1; usage_line 1 claude-fable-5 10000 0 0 2000; } > "$TRF"   # 10000*10 + 2000*50 = 200000
guard_in PreToolUse $SIDF Read x "$TRF" | bash "$GUARD" >/dev/null 2>&1
stf=$(cat "${TMPDIR:-/tmp}/claude-budget-state-$SIDF" 2>/dev/null || echo "")
case "$stf" in *" 200000.0000 1 10000") ok "fable/mythos 単価(10/50)で集計(過小評価の防止)";; *) ng "fable 単価不一致: [$stf]";; esac

# ターン数の合成エントリ除外(「2ターンが4に見える」バグの回帰防止)。
# 実プロンプト2件のあいだに、スラッシュコマンドの足場・標準出力・継続サマリ・
# サブエージェント内部ターンを挟んでも、ターン数は 2 のままであること。
TRT="$SB/turncount.jsonl"; SIDT=tst-tc1
{
  user_line 1; usage_line 1 claude-sonnet-5 1000 0 0 500
  printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-name>/model</command-name>\\n<command-args>opus</command-args>"}}\n'
  printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"<local-command-stdout>Set model to claude-opus-4-8</local-command-stdout>"}}\n'
  printf '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation..."}}\n'
  printf '{"type":"user","isSidechain":true,"message":{"role":"user","content":"サブエージェント内部の指示"}}\n'
  user_line 2; usage_line 2 claude-sonnet-5 1000 0 0 500
} > "$TRT"
guard_in PreToolUse $SIDT Read x "$TRT" | bash "$GUARD" >/dev/null 2>&1
stt=$(awk '{print $3}' "${TMPDIR:-/tmp}/claude-budget-state-$SIDT" 2>/dev/null || echo "")
[ "$stt" = "2" ] && ok "合成エントリ(コマンド/stdout/継続サマリ/sidechain)を除外しターン数=2" || ng "ターン数が過大計上: $stt(期待 2)"
# statusline も同じ除外ロジックであること(状態ファイルを消して自前集計に落とす)
rm -f "${TMPDIR:-/tmp}/claude-budget-state-$SIDT"
slt=$(printf '{"model":{"display_name":"S"},"session_id":"%s","transcript_path":"%s","cost":{"total_cost_usd":0.1}}' "$SIDT" "$TRT" | bash "$STATUS" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$slt" in *"🔄 2"*) ok "statusline のフォールバック集計も合成エントリを除外";; *) ng "statusline のターン数が不正: [$slt]";; esac

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
# 高価モデルでのペース超過 → モデル/effort 引き下げレバーを決定論的に案内(実測モデル依存)
TRM="$SB/pace-opus.jsonl"; SIDM=tst-pm1
for i in 1 2 3 4 5; do user_line "$i"; usage_line "$i" claude-opus-4-8 10000 0 0 14000; done > "$TRM"
msg=$(guard_in PreToolUse $SIDM Read x "$TRM" | bash "$GUARD" 2>&1 >/dev/null || true)
case "$msg" in *"高価なモデル"*"opus"*"/model sonnet"*) ok "opus でペース超過時にモデル引き下げレバーを案内";; *) ng "モデルレバー案内なし: [$msg]";; esac
# Sonnet(標準単価)でのペース超過ではモデルレバーを出さない(誤提案の防止)
TRS="$SB/pace-sonnet.jsonl"; SIDS=tst-ps1
for i in 1 2 3 4 5; do user_line "$i"; usage_line "$i" claude-sonnet-5 10000 0 0 14000; done > "$TRS"
msg=$(guard_in PreToolUse $SIDS Read x "$TRS" | bash "$GUARD" 2>&1 >/dev/null || true)
case "$msg" in *"高価なモデル"*) ng "sonnet なのにモデル引き下げを提案した: [$msg]";; *) ok "標準単価モデルではモデルレバーを出さない";; esac
# 公式仕様: UserPromptSubmit の exit 2 はプロンプトを消去し stderr はユーザーのみ。
# ペース・肥大・警告の3段は UserPromptSubmit で発火してはならない(プロンプト誤消去の防止)。
guard_in UserPromptSubmit tst-p3 "" "" "$TR" | bash "$GUARD" >/dev/null 2>&1
assert_exit "ペース超過でも UserPromptSubmit は素通し(プロンプトを消去しない)" 0 $?
TRC="$SB/pace-ctx.jsonl"
{ user_line 1; usage_line 1 claude-sonnet-5 2000 0 200000 1000; } > "$TRC"   # ctx 202k > 120k
guard_in UserPromptSubmit tst-p4 "" "" "$TRC" | bash "$GUARD" >/dev/null 2>&1
assert_exit "ctx 超過でも UserPromptSubmit は素通し(肥大警告は PreToolUse 限定)" 0 $?

echo "== 6. handoff-notice(本文注入による再開) =="
W="$SB/proj"; mkdir -p "$W/.claude"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); [ -z "$out" ] && ok "handoff なし → 出力なし" || ng "handoff なしで出力あり"
printf '# handoff: statusline改修の続き\n## 再開手順\n1. tests/run-tests.sh を実行\n' > "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE")
case "$out" in *"statusline改修の続き"*"tests/run-tests.sh"*) ok "本文をそのまま注入(1ターン目からRead不要で再開可能)";; *) ng "本文注入なし: [$out]";; esac
case "$out" in *"Read しない"*) ok "再Read不要の指示を含む";; *) ng "再Read指示なし";; esac
out=$(printf '{"cwd":"%s"}' "$W" | CLAUDE_HANDOFF_NOTICE=min bash "$NOTICE")
case "$out" in *"statusline改修の続き"*) ng "min モードで本文が注入された";; *handoff.md*) ok "CLAUDE_HANDOFF_NOTICE=min で従来の3行通知";; *) ng "min モード不正: [$out]";; esac
# git ルート探索: サブディレクトリから起動しても handoff を発見する
if command -v git >/dev/null 2>&1; then
  GW="$SB/gitproj"; mkdir -p "$GW/sub/dir" "$GW/.claude"
  git -C "$GW" init -q 2>/dev/null
  printf '# handoff: gitルートのメモ\n' > "$GW/.claude/handoff.md"
  out=$(printf '{"cwd":"%s"}' "$GW/sub/dir" | bash "$NOTICE")
  case "$out" in *"gitルートのメモ"*) ok "サブディレクトリ起動でも git ルートの handoff を発見";; *) ng "gitルート探索失敗: [$out]";; esac
fi
# 巨大 handoff は3000バイトで打ち切り(注入コストの上限保証)
yes 'あいうえおかきくけこ' | head -200 > "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE")
[ "$(printf '%s' "$out" | wc -c)" -lt 3800 ] && ok "注入サイズ上限(3000バイト+定型文)を保証" || ng "注入サイズ超過: $(printf '%s' "$out" | wc -c)B"
printf '# handoff: x\n' > "$W/.claude/handoff.md"
touch -d '3 days ago' "$W/.claude/handoff.md"
out=$(printf '{"cwd":"%s"}' "$W" | bash "$NOTICE"); [ -z "$out" ] && ok "48時間超の handoff → 注入なし" || ng "古い handoff を注入した"

echo "== 7. statusline(公式 context_window / effort / rate_limits を使用)=="
strip() { sed 's/\x1b\[[0-9;]*m//g'; }   # ANSI色除去
TR="$SB/sl.jsonl"; SID=tst-s1
{ user_line 1; usage_line 1 claude-sonnet-5 3000 2000 42000 500; } > "$TR"
# コストとターン数は予算ガードの状態ファイル由来(公式 cost.total_cost_usd は使わない)。
# 決定論的に検証するため直接シードする: raw=80000 → $0.08、turns=1。
seed_state "$SID" 80000 1
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
# 予算超過 → 🛑・満杯・実値%(状態を $6.00 に再シード)
seed_state "$SID" 6000000 1
out=$(printf '{"model":{"display_name":"Opus"},"session_id":"%s",%s}' "$SID" "$CW" | bash "$STATUS" | strip)
case "$out" in *"🛑 \$6.00/\$5"*"██████████"*"120%"*) ok "予算超過で🛑・満杯・実値%(120)";; *) ng "予算超過不正: [$out]";; esac
case "$out" in *"🔥 10T"*) ok "ペース超過で🔥";; *) ng "ペース超過不正: [$out]";; esac
# トークン内訳(2行化に伴い既定オン。CLAUDE_STATUSLINE_TOKENS=0 で非表示)
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":0.08},"session_id":"%s",%s}' "$SID" "$CW" | bash "$STATUS" | strip)
case "$out" in *"🎫 in:3k rd:42k wr:2k out:500"*) ok "トークン内訳(cache write含む)を既定で表示";; *) ng "内訳不正: [$out]";; esac
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":0.08},"session_id":"%s",%s}' "$SID" "$CW" | CLAUDE_STATUSLINE_TOKENS=0 bash "$STATUS" | strip)
case "$out" in *"🎫"*) ng "TOKENS=0 なのに内訳が表示: [$out]";; *) ok "CLAUDE_STATUSLINE_TOKENS=0 で非表示に切替可能";; esac
out=$(printf '{"model":{"display_name":"Sonnet"}}' | bash "$STATUS" 2>&1 | strip)
case "$out" in "🤖 Sonnet") ok "最小入力でも安全(エラーなし)";; *) ng "最小入力不正: [$out]";; esac
# 起動直後(状態ファイル未生成・セッションあり)でもセッションコストを表示する。
# ガードは初回プロンプト前は状態を作らないため、公式 total_cost_usd(なければ0)で補完。
out=$(printf '{"model":{"display_name":"Sonnet"},"session_id":"sl-startup","transcript_path":"","cost":{"total_cost_usd":0.0}}' | bash "$STATUS" | strip)
case "$out" in *'$0.00/$5'*) ok "起動直後(状態なし)でも予算バーを $0.00 で表示";; *) ng "起動時に予算バーが出ない: [$out]";; esac
out=$(printf '{"model":{"display_name":"Opus"},"session_id":"sl-resume","transcript_path":"","cost":{"total_cost_usd":2.30}}' | bash "$STATUS" | strip)
case "$out" in *'$2.30/$5'*) ok "resume 起動時は total_cost_usd を予算バーに反映";; *) ng "resume 起動時のコスト不正: [$out]";; esac
# セッションが無い最小入力ではフォールバックしない(予算バーを出さない=従来どおり)
out=$(printf '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":5.0}}' | bash "$STATUS" | strip)
case "$out" in *'💰'*) ng "セッション無しでフォールバック表示された: [$out]";; *) ok "セッション無しはフォールバックしない(予算バー非表示)";; esac

echo "== 8. install.sh 保持マージ =="
D="$SB/claudehome"; mkdir -p "$D"
cat > "$D/settings.json" <<'EOF'
{"model":"opus","env":{"MY_VAR":"keep"},"apiKeyHelper":"/bin/k.sh","permissions":{"deny":["Read(./mine/**)"],"allow":["Bash(make:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/my-own-hook.sh"}]}],"Notification":[{"hooks":[{"type":"command","command":"~/notify.sh"}]}]}}
EOF
CLAUDE_CONFIG_DIR="$D" bash "$INSTALL" >/dev/null 2>&1
# 既定(keep): あなたの既存 model は勝手に下位/古い参照へ差し替えない(維持)
m=$(jq -r '.model' "$D/settings.json"); [ "$m" = "opus" ] && ok "既存 model を維持(勝手に上書きしない)" || ng "model が上書きされた: $m"
v=$(jq -r '.env.MY_VAR' "$D/settings.json"); [ "$v" = "keep" ] && ok "既存 env を保持" || ng "env 喪失"
uh=$(jq -r '[.hooks.PreToolUse[].hooks[].command] | index("~/my-own-hook.sh")' "$D/settings.json")
[ "$uh" != "null" ] && ok "既存 PreToolUse フックを保持(消えない)" || ng "既存フックが消えた"
th=$(jq -r '[.hooks.PreToolUse[].hooks[].command] | any(test("session-budget-guard"))' "$D/settings.json")
[ "$th" = "true" ] && ok "テンプレのガードフックも追加(守りは足し込む)" || ng "ガードフックが入らない"
sl=$(jq -r '.statusLine.command // empty' "$D/settings.json")
case "$sl" in *statusline.sh*) ok "未設定だったキー(statusLine)はテンプレが補完" ;; *) ng "不足キーが補完されない: $sl" ;; esac
nh=$(jq -r '.hooks.Notification[0].hooks[0].command' "$D/settings.json")
[ "$nh" = "~/notify.sh" ] && ok "テンプレに無いイベント(Notification)も保持" || ng "Notification フック喪失"
k=$(jq -r '.apiKeyHelper' "$D/settings.json"); [ "$k" = "/bin/k.sh" ] && ok "独自キーを保持" || ng "独自キー喪失"
d=$(jq -r '.permissions.deny | index("Read(./mine/**)")' "$D/settings.json"); [ "$d" != "null" ] && ok "deny を和集合" || ng "deny 喪失"
# PREFER=template のときだけ、積極的にテンプレ推奨(model=sonnet)へ寄せる
DT="$SB/claudehome-tpl"; mkdir -p "$DT"
printf '{"model":"opus","env":{"MY_VAR":"keep"}}' > "$DT/settings.json"
CLAUDE_INSTALL_PREFER=template CLAUDE_CONFIG_DIR="$DT" bash "$INSTALL" >/dev/null 2>&1
mt=$(jq -r '.model' "$DT/settings.json"); [ "$mt" = "sonnet" ] && ok "PREFER=template で model をテンプレ推奨(sonnet)へ" || ng "template 指定で model=$mt"
vt=$(jq -r '.env.MY_VAR' "$DT/settings.json"); [ "$vt" = "keep" ] && ok "PREFER=template でも独自 env は保持" || ng "template で独自 env 喪失"

# outputStyle レビュー: 出力トークンを増やす公式スタイル(Explanatory/Learning)だけ対象。
# terse・独自スタイルは節約になり得るので絶対に触らない(ユーザー報告の terse 上書き対策)。
mkstyle() { # dest-dir value
  mkdir -p "$1"
  printf '{"model":"opus","outputStyle":"%s","env":{"E":"1"}}' "$2" > "$1/settings.json"
}
# ★ terse(簡潔=節約系)は keep 既定でも PREFER=template でも維持し、警告も出さない
DOT="$SB/ostyleterse"; mkstyle "$DOT" "terse"
ot=$(CLAUDE_CONFIG_DIR="$DOT" bash "$INSTALL" < /dev/null 2>&1)
ost=$(jq -r '.outputStyle // "ABSENT"' "$DOT/settings.json")
[ "$ost" = "terse" ] && ok "terse スタイルは維持(節約系を壊さない)" || ng "terse が失われた: $ost"
case "$ot" in *冗長系*) ng "terse に不要な警告/変更が出た: [$ot]";; *) ok "terse には警告を出さない(触らない)";; esac
DOT2="$SB/ostyleterse2"; mkstyle "$DOT2" "terse"
CLAUDE_INSTALL_PREFER=template CLAUDE_CONFIG_DIR="$DOT2" bash "$INSTALL" >/dev/null 2>&1
ost2=$(jq -r '.outputStyle // "ABSENT"' "$DOT2/settings.json")
[ "$ost2" = "terse" ] && ok "PREFER=template でも terse は解除しない(冗長系のみ対象)" || ng "template で terse が消えた: $ost2"
# (a) Explanatory(冗長系)・非対話 keep 既定 → 維持 + 警告
DO1="$SB/ostyle1"; mkstyle "$DO1" "Explanatory"
o1=$(CLAUDE_CONFIG_DIR="$DO1" bash "$INSTALL" < /dev/null 2>&1)
os1=$(jq -r '.outputStyle // "ABSENT"' "$DO1/settings.json")
[ "$os1" = "Explanatory" ] && ok "outputStyle: 冗長系も既定は維持(破壊しない)" || ng "既定で outputStyle が失われた: $os1"
case "$o1" in *"outputStyle"*"維持"*) ok "冗長系維持時は節約提案を表示";; *) ng "維持の警告が出ていない: [$o1]";; esac
# (b) CLAUDE_INSTALL_PREFER=template → 冗長系を標準へリセット(キー削除)
DO2="$SB/ostyle2"; mkstyle "$DO2" "Explanatory"
CLAUDE_INSTALL_PREFER=template CLAUDE_CONFIG_DIR="$DO2" bash "$INSTALL" >/dev/null 2>&1
os2=$(jq -r '.outputStyle // "ABSENT"' "$DO2/settings.json")
[ "$os2" = "ABSENT" ] && ok "PREFER=template で冗長系 outputStyle を標準へリセット" || ng "template 指定でリセットされない: $os2"
# (c) Learning・keep → 維持
DO3="$SB/ostyle3"; mkstyle "$DO3" "Learning"
CLAUDE_INSTALL_PREFER=keep CLAUDE_CONFIG_DIR="$DO3" bash "$INSTALL" >/dev/null 2>&1
os3=$(jq -r '.outputStyle // "ABSENT"' "$DO3/settings.json")
[ "$os3" = "Learning" ] && ok "PREFER=keep で冗長系 outputStyle も維持" || ng "keep 指定で維持されない: $os3"
# 既定(default)スタイルはレビュー対象外(ノイズを出さない)
DO4="$SB/ostyle4"; mkstyle "$DO4" "default"
o4=$(CLAUDE_CONFIG_DIR="$DO4" bash "$INSTALL" < /dev/null 2>&1)
case "$o4" in *冗長系*) ng "既定スタイルなのにレビュー行が出た";; *) ok "既定スタイルはレビュー対象外(不要な警告なし)";; esac
# 冪等性: 同一結果の再実行はスキップ(再書き込み・再バックアップ・冗長メッセージを出さない)
DID="$SB/idem"; mkdir -p "$DID"
printf '{"model":"opus","env":{"K":"v"}}' > "$DID/settings.json"
CLAUDE_CONFIG_DIR="$DID" bash "$INSTALL" >/dev/null 2>&1         # 1回目(マージ)
md5a=$(md5sum "$DID/settings.json" | awk '{print $1}')
nb1=$(ls -d "$DID"/backup-* 2>/dev/null | wc -l | tr -d ' ')
sleep 1   # backup-<TS> は秒粒度。2回目で新規 backup が作られたかを確実に判定するため
o5=$(CLAUDE_CONFIG_DIR="$DID" bash "$INSTALL" 2>&1)              # 2回目(変更なしのはず)
md5b=$(md5sum "$DID/settings.json" | awk '{print $1}')
nb2=$(ls -d "$DID"/backup-* 2>/dev/null | wc -l | tr -d ' ')
case "$o5" in *"変更なし"*"スキップ"*) ok "2回目: settings.json が変更なしでスキップ";; *) ng "変更なしにならない: [$o5]";; esac
[ "$md5a" = "$md5b" ] && ok "変更なし時は settings.json を書き換えない(md5一致)" || ng "no-op で書き換わった"
[ "$nb2" = "$nb1" ] && ok "変更なし時は追加バックアップを作らない($nb1→$nb2)" || ng "no-op で backup が増えた($nb1→$nb2)"
case "$o5" in *"更新 0"*) ok "2回目: 非settingsファイルも全て『変更なし』でスキップ";; *) ng "スキップ集計が不正: [$o5]";; esac
# 差分があるときはマージして退避する(スキップの副作用で更新が止まらないこと)
printf '{"model":"opus","env":{"K":"v","NEW":"z"}}' > "$DID/settings.json"   # env を1つ増やす
o6=$(CLAUDE_CONFIG_DIR="$DID" bash "$INSTALL" 2>&1)
nz=$(jq -r '.env.NEW' "$DID/settings.json")
[ "$nz" = "z" ] && ok "差分あり: 既存の新規 env を保持してマージ" || ng "差分マージで env 喪失"
case "$o6" in *"マージしました"*) ok "差分あり時はマージメッセージを表示";; *) ng "差分ありでマージされない: [$o6]";; esac
# 項目ごとの diff: 既定 keep では「既存を維持(推奨X)」で食い違いを明示し、黙って上書きしない
DKV="$SB/keydiff"; mkdir -p "$DKV"
printf '{"model":"opus","alwaysThinkingEnabled":true,"env":{"CLAUDE_SESSION_BUDGET_USD":"20","MY_OWN":"keep"}}' > "$DKV/settings.json"
o7=$(CLAUDE_CONFIG_DIR="$DKV" bash "$INSTALL" 2>&1)
case "$o7" in *'model: 既存 "opus" を維持(テンプレ推奨: "sonnet")'*) ok "項目diff: model は維持しつつ推奨を併記(黙って上書きしない)";; *) ng "model の維持diffが出ない: [$o7]";; esac
case "$o7" in *'env.CLAUDE_SESSION_BUDGET_USD: 既存 "20" を維持(テンプレ推奨: "5")'*) ok "項目diff: コスト関連 env も既存維持+推奨併記";; *) ng "env budget の維持diffが出ない: [$o7]";; esac
mb2=$(jq -r '.env.CLAUDE_SESSION_BUDGET_USD' "$DKV/settings.json"); [ "$mb2" = "20" ] && ok "既存の予算 env を実際に維持(20 のまま)" || ng "予算 env が上書きされた: $mb2"
mm=$(jq -r '.model' "$DKV/settings.json"); [ "$mm" = "opus" ] && ok "既存 model を実際に維持(opus のまま)" || ng "model が上書きされた: $mm"
case "$o7" in *"件 追加"*) ok "項目diff: 追加キーは件数で要約(維持と区別)";; *) ng "追加の要約が出ない: [$o7]";; esac
mo=$(jq -r '.env.MY_OWN' "$DKV/settings.json"); [ "$mo" = "keep" ] && ok "独自 env(MY_OWN)は維持され diff にも出ない" || ng "独自 env が失われた"
case "$o7" in *"MY_OWN"*) ng "維持された独自キーが誤って diff に出た";; *) ok "維持キーは項目diff に出さない(食い違いだけ表示)";; esac
# プラン(dry-run)モード: 副作用なしで conflicts/additions/same を JSON 出力(/settings-merge の入力)
DP="$SB/plan"; mkdir -p "$DP"
printf '{"model":"opus","alwaysThinkingEnabled":false,"env":{"CLAUDE_SESSION_BUDGET_USD":"20","MINE":"x"}}' > "$DP/settings.json"
pbefore=$(md5sum "$DP/settings.json" | awk '{print $1}')
plan=$(CLAUDE_INSTALL_PLAN=1 CLAUDE_CONFIG_DIR="$DP" bash "$INSTALL" 2>/dev/null)
pafter=$(md5sum "$DP/settings.json" | awk '{print $1}')
echo "$plan" | jq -e . >/dev/null 2>&1 && ok "plan: 妥当な JSON を出力" || ng "plan JSON 不正: [$plan]"
[ "$pbefore" = "$pafter" ] && ok "plan は副作用なし(settings.json 不変)" || ng "plan が settings を書き換えた"
[ ! -d "$DP"/backup-* ] 2>/dev/null && ok "plan はバックアップも作らない" || ng "plan が backup を作った"
ck=$(echo "$plan" | jq -r '[.conflicts[].key] | sort | join(",")')
[ "$ck" = "env.CLAUDE_SESSION_BUDGET_USD,model" ] && ok "plan: 競合キー(model・予算 env)を正しく列挙" || ng "conflicts 不正: $ck"
pce=$(echo "$plan" | jq -r '.conflicts[] | select(.key=="model") | "\(.existing)/\(.template)"')
[ "$pce" = "opus/sonnet" ] && ok "plan: 競合の existing/template 値を提示" || ng "conflict 値不正: $pce"
echo "$plan" | jq -e '.additions | index("statusLine.command")' >/dev/null 2>&1 && ok "plan: 追加候補(テンプレのみのキー)を列挙" || ng "additions に統計不足"
echo "$plan" | jq -e '.same | index("alwaysThinkingEnabled")' >/dev/null 2>&1 && ok "plan: 同値キーを same に分類(スキップ対象)" || ng "same 分類が不正"
# 決定オーバーレイ: AskUserQuestion の結果(例 outputStyle=terse)を確定適用できる
DDEC="$SB/decide"; mkdir -p "$DDEC"
printf '{"model":"opus","env":{"MINE":"x"}}' > "$DDEC/settings.json"
echo '{"model":"sonnet","outputStyle":"terse"}' > "$SB/dec.json"
CLAUDE_INSTALL_DECISIONS="$SB/dec.json" CLAUDE_CONFIG_DIR="$DDEC" bash "$INSTALL" </dev/null >/dev/null 2>&1
dm=$(jq -r '.model' "$DDEC/settings.json"); [ "$dm" = "sonnet" ] && ok "decisions: 確定した model=sonnet を適用" || ng "decisions model 未適用: $dm"
ds=$(jq -r '.outputStyle // "ABSENT"' "$DDEC/settings.json"); [ "$ds" = "terse" ] && ok "decisions: outputStyle=terse を適用(ユーザー希望どおり)" || ng "decisions outputStyle 未適用: $ds"
dmine=$(jq -r '.env.MINE' "$DDEC/settings.json"); [ "$dmine" = "x" ] && ok "decisions 適用後も独自 env を維持" || ng "decisions で独自 env 喪失"
# 決定に含めないキーは既定 keep のまま(既存維持)
DDEC2="$SB/decide2"; mkdir -p "$DDEC2"
printf '{"model":"opus","env":{"CLAUDE_SESSION_BUDGET_USD":"20"}}' > "$DDEC2/settings.json"
echo '{"outputStyle":"terse"}' > "$SB/dec2.json"
CLAUDE_INSTALL_DECISIONS="$SB/dec2.json" CLAUDE_CONFIG_DIR="$DDEC2" bash "$INSTALL" </dev/null >/dev/null 2>&1
d2m=$(jq -r '.model' "$DDEC2/settings.json"); d2b=$(jq -r '.env.CLAUDE_SESSION_BUDGET_USD' "$DDEC2/settings.json")
{ [ "$d2m" = "opus" ] && [ "$d2b" = "20" ]; } && ok "decisions に無いキー(model・予算)は既存維持(都度確認で「維持」を選んだ想定)" || ng "決定外キーが変わった: model=$d2m budget=$d2b"
# /settings-merge スキルの存在と方針
SMG="$ROOT/home/skills/settings-merge/SKILL.md"
[ -f "$SMG" ] && grep -q '^name: settings-merge$' "$SMG" && ok "/settings-merge スキルが存在" || ng "/settings-merge スキル不備"
grep -q 'AskUserQuestion' "$SMG" && grep -q 'CLAUDE_INSTALL_PLAN' "$SMG" && grep -q 'CLAUDE_INSTALL_DECISIONS' "$SMG" && ok "スキルが plan→AskUserQuestion→decisions の流れを規定" || ng "スキルの対話マージ手順が不備"
# グローバル方針は ~/.claude/rules/ に置き、ユーザーの CLAUDE.md は一切触らない。
# (1) 方針は rules/cost-optimization.md として配置され、CLAUDE.md は作られない
DCM="$SB/claudemd"; mkdir -p "$DCM"
CLAUDE_CONFIG_DIR="$DCM" bash "$INSTALL" </dev/null >/dev/null 2>&1
grep -q 'トークン倹約' "$DCM/rules/cost-optimization.md" 2>/dev/null && ok "方針: ~/.claude/rules/cost-optimization.md として配置" || ng "rules に方針が入らない"
[ ! -f "$DCM/CLAUDE.md" ] && ok "CLAUDE.md: 存在しなければ作らない(不干渉)" || ng "CLAUDE.md を勝手に作った"
# (2) ユーザーの CLAUDE.md があっても一切触らない(丸ごと保持)
DCM1="$SB/claudemd1"; mkdir -p "$DCM1"
printf '# 自分ルール\n- 常にテストを書く\n- 独自メモX\n' > "$DCM1/CLAUDE.md"
before1=$(md5sum "$DCM1/CLAUDE.md" | awk '{print $1}')
CLAUDE_CONFIG_DIR="$DCM1" bash "$INSTALL" </dev/null >/dev/null 2>&1
after1=$(md5sum "$DCM1/CLAUDE.md" | awk '{print $1}')
[ "$before1" = "$after1" ] && ok "CLAUDE.md: 既存があっても1バイトも変更しない(不干渉)" || ng "CLAUDE.md が変更された"
grep -q "独自メモX" "$DCM1/CLAUDE.md" && ok "CLAUDE.md: ユーザー記述はそのまま" || ng "ユーザー記述が失われた"
grep -qF "claude-settings managed" "$DCM1/CLAUDE.md" && ng "CLAUDE.md に管理ブロックが埋め込まれた(旧挙動)" || ok "CLAUDE.md に管理ブロックを埋め込まない(方針は rules/ へ)"
# (3) rules の方針は manifest 方式: ユーザーが編集したら上書きせず保持
printf '\n<!-- 自分の追記R -->\n' >> "$DCM/rules/cost-optimization.md"
CLAUDE_CONFIG_DIR="$DCM" bash "$INSTALL" </dev/null >/dev/null 2>&1
grep -q "自分の追記R" "$DCM/rules/cost-optimization.md" && ok "rules: 編集した方針ファイルは上書きせず保持(manifest)" || ng "編集した rules が上書きされた"
# (4) 移行: 旧・埋め込み管理ブロックがあれば除去(ブロック外の記述は保持・二重ロード解消)
DCMX="$SB/claudemdx"; mkdir -p "$DCMX"
{ printf '# 自分のメモ\n- 残す情報Z\n\n'; printf '%s\n' '<!-- >>> claude-settings managed (トークン倹約グローバル方針・自動更新) >>> -->'; echo '# グローバル方針(トークン倹約)'; echo '- 旧埋め込み本文'; printf '%s\n' '<!-- <<< claude-settings managed <<< -->'; } > "$DCMX/CLAUDE.md"
omx=$(CLAUDE_CONFIG_DIR="$DCMX" bash "$INSTALL" </dev/null 2>&1)
grep -q "残す情報Z" "$DCMX/CLAUDE.md" && ok "移行: 埋め込みブロック外のユーザー記述は保持" || ng "★データ損失★ 移行で記述が消えた"
grep -qF "claude-settings managed" "$DCMX/CLAUDE.md" && ng "移行後も埋め込みブロックが残っている" || ok "移行: 旧・埋め込みブロックを除去(二重ロード解消)"
case "$omx" in *"旧・埋め込み管理ブロックを除去"*) ok "移行: 除去した旨を通知" ;; *) ng "移行通知が出ない: [$omx]" ;; esac
# (5) 移行は片方マーカーだけ(破損)なら実施しない(巻き込み削除の防止)
DCMY="$SB/claudemdy"; mkdir -p "$DCMY"
{ printf '# メモ\n- 情報W\n'; printf '%s\n' '<!-- >>> claude-settings managed (トークン倹約グローバル方針・自動更新) >>> -->'; echo '本文だけEND無し'; } > "$DCMY/CLAUDE.md"
CLAUDE_CONFIG_DIR="$DCMY" bash "$INSTALL" </dev/null >/dev/null 2>&1
{ grep -q "情報W" "$DCMY/CLAUDE.md" && grep -q "本文だけEND無し" "$DCMY/CLAUDE.md"; } && ok "移行: マーカー破損(片側)では触らない(巻き込み削除しない)" || ng "★データ損失★ 破損マーカーで消えた"
# (6) マーカー無しでも、テンプレ本文と完全一致する旧方針は自動除去(追記は保持)
DCMZ="$SB/claudemdz"; mkdir -p "$DCMZ"
cp "$ROOT/home/rules/cost-optimization.md" "$DCMZ/CLAUDE.md"; printf '\n## 追記M\n- 大事Z\n' >> "$DCMZ/CLAUDE.md"
omz=$(CLAUDE_CONFIG_DIR="$DCMZ" bash "$INSTALL" </dev/null 2>&1)
grep -q "^# グローバル方針(トークン倹約)" "$DCMZ/CLAUDE.md" && ng "★残存★ 完全一致の旧方針が消えていない" || ok "移行: テンプレ完全一致の旧方針(探索・出力等)を自動除去"
{ grep -q "追記M" "$DCMZ/CLAUDE.md" && grep -q "大事Z" "$DCMZ/CLAUDE.md"; } && ok "移行: 旧方針除去でもあなたの追記は保持" || ng "★データ損失★ 追記が消えた"
case "$omz" in *"完全一致する箇所"*"除去"*) ok "移行: 除去した旨を通知" ;; *) ng "除去通知が出ない: [$omz]" ;; esac
# (7) 手編集で完全一致しない旧方針 → 自動削除せず案内のみ(誤削除防止)
DCMW="$SB/claudemdw"; mkdir -p "$DCMW"
cp "$ROOT/home/rules/cost-optimization.md" "$DCMW/CLAUDE.md"
sed -i.bak 's/^## 出力$/## 出力(自分で追記)/' "$DCMW/CLAUDE.md" 2>/dev/null || sed -i '' 's/^## 出力$/## 出力(自分で追記)/' "$DCMW/CLAUDE.md"; rm -f "$DCMW/CLAUDE.md.bak"
bw=$(md5sum "$DCMW/CLAUDE.md" | awk '{print $1}')
omw=$(CLAUDE_CONFIG_DIR="$DCMW" bash "$INSTALL" </dev/null 2>&1)
aw=$(md5sum "$DCMW/CLAUDE.md" | awk '{print $1}')
[ "$bw" = "$aw" ] && ok "移行: 手編集で完全一致しない旧方針は自動削除しない(誤削除防止)" || ng "★誤削除★ 手編集版を勝手に消した"
case "$omw" in *"手編集あり"*) ok "移行: 完全一致しない場合は手動削除を案内" ;; *) ng "案内が出ない: [$omw]" ;; esac
# マニフェスト方式: あなたが編集した statusline/hooks/skills を上書きしない
DMAN="$SB/manifest"; mkdir -p "$DMAN"
CLAUDE_CONFIG_DIR="$DMAN" bash "$INSTALL" </dev/null >/dev/null 2>&1     # 初回配置(manifest 作成)
[ -f "$DMAN/.claude-settings-manifest" ] && ok "manifest: 初回インストールで作成される" || ng "manifest が作られない"
printf '\n# 自分のカスタム\n' >> "$DMAN/hooks/handoff-notice.sh"      # ユーザーが編集
oman=$(CLAUDE_CONFIG_DIR="$DMAN" bash "$INSTALL" </dev/null 2>&1)
grep -q "自分のカスタム" "$DMAN/hooks/handoff-notice.sh" && ok "manifest: 編集した hook を上書きせず保持" || ng "編集した hook が上書きされた"
[ -f "$DMAN/hooks/handoff-notice.sh.claude-settings-new" ] && ok "manifest: テンプレ新版を .claude-settings-new として隣に置く" || ng "新版が置かれない"
case "$oman" in *"保持 1"*"handoff-notice.sh"*) ok "manifest: 保持したファイルを明示通知" || ng "保持通知が不正" ;; *) ng "保持通知が出ない: [$oman]" ;; esac
# 未編集ファイルは自動更新される(manifest 記録と一致 → 安全に上書き)
printf '\n# pretend-old\n' >> "$DMAN/statusline.sh"                    # 旧版を演出
nh=$(sha256sum "$DMAN/statusline.sh" 2>/dev/null | awk '{print $1}'); [ -n "$nh" ] || nh=$(shasum -a 256 "$DMAN/statusline.sh" | awk '{print $1}')
awk -F'\t' -v OFS='\t' -v h="$nh" '$2=="statusline.sh"{$1=h} {print}' "$DMAN/.claude-settings-manifest" > "$DMAN/.m2" && mv "$DMAN/.m2" "$DMAN/.claude-settings-manifest"
CLAUDE_CONFIG_DIR="$DMAN" bash "$INSTALL" </dev/null >/dev/null 2>&1
grep -q "pretend-old" "$DMAN/statusline.sh" && ng "未編集ファイルが自動更新されない" || ok "manifest: 未編集ファイル(記録一致)は自動更新される"
# CLAUDE_INSTALL_FORCE=1 で保持を無視して一括上書き
printf '\n# force-me\n' >> "$DMAN/statusline.sh"
CLAUDE_INSTALL_FORCE=1 CLAUDE_CONFIG_DIR="$DMAN" bash "$INSTALL" </dev/null >/dev/null 2>&1
grep -q "force-me" "$DMAN/statusline.sh" && ng "FORCE=1 で上書きされない" || ok "manifest: CLAUDE_INSTALL_FORCE=1 で一括上書き(退避あり)"
# .new を受理(mv)したら次回は掃除される
DMAN2="$SB/manifest2"; mkdir -p "$DMAN2"
CLAUDE_CONFIG_DIR="$DMAN2" bash "$INSTALL" </dev/null >/dev/null 2>&1
printf '\n# e\n' >> "$DMAN2/statusline.sh"; CLAUDE_CONFIG_DIR="$DMAN2" bash "$INSTALL" </dev/null >/dev/null 2>&1
mv "$DMAN2/statusline.sh.claude-settings-new" "$DMAN2/statusline.sh"
CLAUDE_CONFIG_DIR="$DMAN2" bash "$INSTALL" </dev/null >/dev/null 2>&1
[ -f "$DMAN2/statusline.sh.claude-settings-new" ] && ng ".new が掃除されない" || ok "manifest: 新版を受理後は .claude-settings-new を掃除"
# ★回帰★ マニフェスト以前の導入(ファイルあり・差分あり・manifest 無し)で無言終了しない
DPRE="$SB/premanifest"; mkdir -p "$DPRE/hooks"
echo "# 旧版フック" > "$DPRE/hooks/handoff-notice.sh"; echo "旧statusline" > "$DPRE/statusline.sh"
opre=$(CLAUDE_CONFIG_DIR="$DPRE" bash "$INSTALL" </dev/null 2>&1); rcpre=$?
[ "$rcpre" = "0" ] && ok "pre-manifest 導入でも異常終了しない(exit 0)" || ng "★無言終了★ pre-manifest で exit $rcpre"
case "$opre" in *"導入完了"*) ok "pre-manifest 導入でも出力が出る(サイレント化しない)" ;; *) ng "★出力なし★ pre-manifest 導入: [$opre]" ;; esac
[ -f "$DPRE/.claude-settings-manifest" ] && ok "pre-manifest 導入で manifest を作成(以後は編集検知が有効)" || ng "manifest が作られない"
# ★回帰★ 新規配置直後の再実行で settings.json が誤って再マージされない(配列順の揺れ対策)
DIDEM="$SB/settings-idem"; mkdir -p "$DIDEM"
CLAUDE_CONFIG_DIR="$DIDEM" bash "$INSTALL" </dev/null >/dev/null 2>&1     # 1回目=新規配置(テンプレの並び)
nbi=$(ls -d "$DIDEM"/backup-* 2>/dev/null | wc -l | tr -d ' ')
oidem=$(CLAUDE_CONFIG_DIR="$DIDEM" bash "$INSTALL" </dev/null 2>&1)       # 2回目=変更なしのはず
nbi2=$(ls -d "$DIDEM"/backup-* 2>/dev/null | wc -l | tr -d ' ')
case "$oidem" in *"settings.json: 変更なし"*) ok "新規配置→再実行で settings.json は変更なし(配列順で誤判定しない)" ;; *) ng "settings.json が誤って再マージ: [$oidem]" ;; esac
[ "$nbi" = "$nbi2" ] && ok "新規配置→再実行で余計なバックアップを作らない" || ng "no-op で backup が増えた($nbi→$nbi2)"

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
for id in $(grep -oE '[A-I]-[0-9]+b?' "$CMAP" | sort -u); do
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
for h in guard-heavy-read.sh session-budget-guard.sh handoff-notice.sh handoff-autostub.sh; do
  grep -q "$h" "$ROOT/home/settings.json" && ok "settings.json に $h が配線済み" || ng "$h が settings.json に無い"
done
jq -e '.hooks.SessionEnd[0].matcher == "clear"' "$ROOT/home/settings.json" >/dev/null && ok "autostub は SessionEnd(matcher: clear)に限定" || ng "SessionEnd matcher 不正"
ri=$(jq -r '.statusLine.refreshInterval' "$ROOT/home/settings.json")
[ "$ri" = "5" ] && ok "statusLine.refreshInterval が設定済み(モデル切替等イベント外の変更に追随)" || ng "refreshInterval 未設定: $ri"
# 仕様ドリフト追随: 公式ドキュメントから削除された env 変数を配布しない
jq -e '.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE == "1"' "$ROOT/home/settings.json" >/dev/null && ok "env にタイトル生成停止(公式文書化済みの変数)" || ng "CLAUDE_CODE_DISABLE_TERMINAL_TITLE 未設定"
jq -e '.env | has("DISABLE_NON_ESSENTIAL_MODEL_CALLS") | not' "$ROOT/home/settings.json" >/dev/null && ok "廃止変数 DISABLE_NON_ESSENTIAL_MODEL_CALLS を配布していない" || ng "廃止変数が settings.json に残存"
grep -q '^maxTurns: [0-9]' "$ROOT/home/agents/explore.md" && ok "explore に maxTurns 上限(サブエージェント暴走の決定論的天井)" || ng "explore に maxTurns がない"
# README のディレクトリツリーと実ファイルの整合(構成図の欠落・陳腐化の検知)
tree_miss=0
while IFS= read -r sf; do
  grep -q "$(basename "$sf")" "$RM" || { ng "README ツリーに $(basename "$sf") がない"; tree_miss=1; }
done < <(find "$ROOT/home" -name '*.sh' -o -name 'SKILL.md' -o -name '*.md' -path '*references*')
[ "$tree_miss" -eq 0 ] && ok "home/ の全スクリプト・スキル資産が README に記載"

echo "== 17. プロンプト品質(手戻り削減)レバー =="
REFINE="$ROOT/home/skills/refine/SKILL.md"
[ -f "$REFINE" ] && ok "refine スキルが存在" || ng "refine スキルがない"
grep -q '^name: refine$' "$REFINE" && ok "frontmatter name: refine" || ng "frontmatter name 不正"
grep -q '^description: .*refine' "$REFINE" && ok "description に発火条件(refine)を含む" || ng "description 不備"
grep -q '完了条件' "$REFINE" && grep -q '要確認' "$REFINE" && ok "仕様テンプレート(完了条件・要確認)を含む" || ng "仕様テンプレート欠落"
grep -q 'ファイル探索をしない' "$REFINE" && ok "整形段階の探索禁止ルールを含む" || ng "探索禁止ルール欠落"
grep -q '## 依頼の受け方' "$ROOT/home/rules/cost-optimization.md" && ok "CLAUDE.md に確認ファースト規範(依頼の受け方)" || ng "CLAUDE.md に確認ファースト規範がない"
grep -q '確認質問を1つだけ' "$ROOT/home/rules/cost-optimization.md" && ok "確認は1問だけの制約を明記(質問攻めの防止)" || ng "確認1問の制約なし"
grep -q '^### C-7\.' "$CHECK" && ok "checklist に C-7(手戻りループ)" || ng "checklist に C-7 がない"
grep -q 'C-7' "$CMAP" && ok "coverage-map が C-7 を参照" || ng "coverage-map に C-7 参照がない"
grep -q '/refine' "$RM" && grep -q '手戻りの削減' "$RM" && ok "README にレバー7(手戻り削減)の記載" || ng "README にレバー7の記載がない"
# 常駐コストの回帰防止: 規範追加後も CLAUDE.md が肥大化していないこと
tok=$(bash "$EST" "$ROOT/home/rules/cost-optimization.md" | awk 'NR==2{print $4}')
[ "$tok" -lt 1000 ] 2>/dev/null && ok "グローバル CLAUDE.md の常駐コストが 1000 トークン未満($tok)" || ng "CLAUDE.md が肥大化: $tok トークン"

echo "== 18. ターン数ガード(コストと独立した第2の上限軸) =="
TR="$SB/turns.jsonl"; SID=tst-t1
for i in 1 2 3 4 5 6 7 8 9 10 11; do user_line "$i"; usage_line "$i" claude-sonnet-5 1000 0 0 500; done > "$TR"   # 11T・低コスト($0.12)
# 上限10: 11ターン目のツール実行はブロック(コストは予算内でもターン軸で止まる)
guard_in PreToolUse $SID Read x "$TR" | CLAUDE_TURN_HARD_LIMIT=10 bash "$GUARD" >/dev/null 2>&1
assert_exit "コスト予算内でも 上限超過ターンの PreToolUse をブロック" 2 $?
guard_in UserPromptSubmit $SID "" "" "$TR" | CLAUDE_TURN_HARD_LIMIT=10 bash "$GUARD" >/dev/null 2>&1
assert_exit "上限到達後の新規プロンプトをブロック" 2 $?
msg=$(guard_in UserPromptSubmit $SID "" "" "$TR" | CLAUDE_TURN_HARD_LIMIT=10 bash "$GUARD" 2>&1 >/dev/null || true)
case "$msg" in *"CLAUDE_TURN_HARD_LIMIT"*) ok "ブロック文に上限変更方法を明記";; *) ng "案内不足: [$msg]";; esac
guard_in PreToolUse $SID Write /x/.claude/handoff.md "$TR" | CLAUDE_TURN_HARD_LIMIT=10 bash "$GUARD" >/dev/null 2>&1
assert_exit "ターン上限超過中も handoff.md への Write は許可(グレースレーン)" 0 $?
# 上限ちょうど(10ターン)までは PreToolUse を止めない(最終ターンを完走させる)
TRX="$SB/turns10.jsonl"; SIDX=tst-t2
for i in 1 2 3 4 5 6 7 8 9 10; do user_line "$i"; usage_line "$i" claude-sonnet-5 1000 0 0 500; done > "$TRX"
rm -f "${TMPDIR:-/tmp}/claude-budget-turnwarn-$SIDX"
guard_in PreToolUse $SIDX Read x "$TRX" | CLAUDE_TURN_HARD_LIMIT=10 CLAUDE_TURN_WARN_TURNS=8 bash "$GUARD" >/dev/null 2>&1
assert_exit "警告帯(8..10ターン)では一度だけ警告(exit 2)" 2 $?
guard_in PreToolUse $SIDX Read x "$TRX" | CLAUDE_TURN_HARD_LIMIT=10 CLAUDE_TURN_WARN_TURNS=8 bash "$GUARD" >/dev/null 2>&1
assert_exit "警告は1回のみ、以降は上限まで素通し(10ターン目を完走できる)" 0 $?
# 無効化(0/未設定)ではターン数に介入しない
guard_in PreToolUse tst-t3 Read x "$TR" | CLAUDE_TURN_HARD_LIMIT=0 bash "$GUARD" >/dev/null 2>&1
assert_exit "CLAUDE_TURN_HARD_LIMIT=0 で無効(11ターンでも素通し)" 0 $?
# settings.json がターン上限を配布していること
jq -e '.env.CLAUDE_TURN_HARD_LIMIT == "10"' "$ROOT/home/settings.json" >/dev/null && ok "settings.json に CLAUDE_TURN_HARD_LIMIT=10" || ng "settings.json にターン上限がない"
# statusline: 上限設定時は 🔄 n/上限 表示
printf '100 5000 7 3000\n' > "${TMPDIR:-/tmp}/claude-budget-state-tst-sl9"
slo=$(printf '{"model":{"display_name":"S"},"session_id":"tst-sl9","transcript_path":"","cost":{"total_cost_usd":0.5}}' | CLAUDE_TURN_HARD_LIMIT=10 bash "$STATUS" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$slo" in *"🔄 7/10"*) ok "statusline がターン上限比(7/10)を表示";; *) ng "ターン上限表示不正: [$slo]";; esac
rm -f "${TMPDIR:-/tmp}/claude-budget-turnwarn-$SID" "${TMPDIR:-/tmp}/claude-budget-turnwarn-$SIDX" "${TMPDIR:-/tmp}/claude-budget-state-tst-sl9"

echo "== 19. statusline 公式サンプルJSON準拠(docs掲載のフルスキーマ) =="
OFFICIAL='{"cwd":"/w","session_id":"tst-off1","transcript_path":"/nonexistent.jsonl","model":{"id":"claude-opus-4-8","display_name":"Opus"},"workspace":{"current_dir":"/w","project_dir":"/w","added_dirs":[]},"version":"2.1.90","output_style":{"name":"default"},"cost":{"total_cost_usd":0.01234,"total_duration_ms":45000,"total_api_duration_ms":2300,"total_lines_added":156,"total_lines_removed":23},"context_window":{"total_input_tokens":15500,"total_output_tokens":1200,"context_window_size":200000,"used_percentage":8,"remaining_percentage":92,"current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}},"exceeds_200k_tokens":false,"effort":{"level":"high"},"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}'
# 予算バーはガード状態由来(公式 total_cost_usd は使わない設計)。$0.01 相当をシード。
seed_state "tst-off1" 12340 1
out=$(printf '%s' "$OFFICIAL" | bash "$STATUS" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "公式サンプルで exit 0" || ng "公式サンプルで exit $rc"
p=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
case "$p" in *"Opus"*) ok "モデル表示";; *) ng "モデル欠落: [$p]";; esac
case "$p" in *"⚡ high"*) ok "effort.level を表示";; *) ng "effort 欠落";; esac
case "$p" in *'$0.01/$5'*) ok "予算バー(ガード状態のセッションコスト推定)を反映";; *) ng "予算表示不正: [$p]";; esac
case "$p" in *"💾 12%"*) ok "cache_read 比率 12%(2000/15500)";; *) ng "キャッシュ率不正: [$p]";; esac
case "$p" in *"5h:24%"*"7d:41%"*) ok "rate_limits の小数を整数%表示";; *) ng "レート制限表示不正: [$p]";; esac
case "$p" in *"💭"*) ok "thinking.enabled で 💭";; *) ng "thinking 欠落";; esac
case "$p" in *"+156"*"-23"*) ok "変更行数(+156/-23)";; *) ng "変更行数欠落";; esac
case "$p" in *"✍️"*) ng "default スタイルが表示されている";; *) ok "default スタイルは非表示";; esac
# 公式仕様: current_usage は初回API前と /compact 直後は null — 無害に通ること
NULLCU='{"model":{"display_name":"Opus"},"session_id":"tst-off2","transcript_path":"","context_window":{"current_usage":null,"used_percentage":null},"cost":{"total_cost_usd":0}}'
out2=$(printf '%s' "$NULLCU" | bash "$STATUS" 2>/dev/null); rc2=$?
[ "$rc2" -eq 0 ] && ok "current_usage=null(公式明記の状態)で exit 0" || ng "null current_usage で exit $rc2"
case "$(printf '%s' "$out2" | sed 's/\x1b\[[0-9;]*m//g')" in *"Opus"*) ok "null ケースでもモデル表示";; *) ng "null ケースで出力破損";; esac

echo "== 20. statusline 2行表示(既定)と単一行切替 =="
SL2='{"model":{"display_name":"Sonnet"},"session_id":"tst-2l","transcript_path":"","cost":{"total_cost_usd":0.5,"total_lines_added":10,"total_lines_removed":2},"effort":{"level":"high"},"thinking":{"enabled":true},"context_window":{"current_usage":{"input_tokens":3000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":42000,"output_tokens":500}}}'
# 予算バーはガード状態由来。$0.50 相当をシード(トランスクリプト空でも offset=0 で表示)。
seed_state "tst-2l" 500000 1
# 既定(2行): 出力に改行が1つ含まれる
out=$(printf '%s' "$SL2" | bash "$STATUS" 2>/dev/null)
nl=$(printf '%s' "$out" | wc -l | tr -d ' ')
[ "$nl" = "1" ] && ok "既定で2行(改行1つ)を出力" || ng "改行数が想定外: $nl"
sp=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
l1=$(printf '%s' "$sp" | sed -n '1p'); l2=$(printf '%s' "$sp" | sed -n '2p')
# 1行目=環境系(モデル/effort/ctx/thinking)、2行目=コスト系(予算バー/変更行)
case "$l1" in *"🤖 Sonnet"*"⚡ high"*"🧠"*"💭"*) ok "1行目に 環境・コンテキスト系(model/effort/ctx/thinking)";; *) ng "1行目不正: [$l1]";; esac
case "$l1" in *"💰"*) ng "予算バーが1行目に混入: [$l1]";; *) ok "予算バーは1行目に無い";; esac
case "$l2" in *"💰 \$0.50/\$5"*"📝"*"+10"*"-2"*) ok "2行目に コスト・進捗系(予算バー/変更行)";; *) ng "2行目不正: [$l2]";; esac
# 単一行モード: CLAUDE_STATUSLINE_LINES=1 で改行なし・全項目
out1=$(printf '%s' "$SL2" | CLAUDE_STATUSLINE_LINES=1 bash "$STATUS" 2>/dev/null)
[ "$(printf '%s' "$out1" | wc -l | tr -d ' ')" = "0" ] && ok "LINES=1 で単一行(改行なし)" || ng "単一行にならない"
sp1=$(printf '%s' "$out1" | sed 's/\x1b\[[0-9;]*m//g')
case "$sp1" in *"🤖 Sonnet"*"💰"*"📝"*) ok "単一行に全項目(環境系+コスト系)";; *) ng "単一行の項目欠落: [$sp1]";; esac
grep -q 'CLAUDE_STATUSLINE_LINES' "$RM" && ok "README に2行表示/単一行切替の記載" || ng "README に行数切替の記載がない"

echo "== 21. /clear 時の handoff 自動スタブ(SessionEnd)と /handoff スキル =="
STUB="$ROOT/home/hooks/handoff-autostub.sh"
WP="$SB/stubproj"; mkdir -p "$WP/.claude"
TRS="$SB/stub.jsonl"
{ user_line 1; usage_line 1 claude-sonnet-5 1000 0 0 500; printf '{"uuid":"u2","type":"user","message":{"role":"user","content":"statuslineを2行にして"}}\n'; } > "$TRS"
se_in() { printf '{"hook_event_name":"SessionEnd","reason":"%s","cwd":"%s","transcript_path":"%s","session_id":"tst-se1"}' "$1" "$WP" "$TRS"; }
# スタブはセッション別ファイル: session_id "tst-se1" → sid8 "tstse1" → handoff-tstse1.md
SF="$WP/.claude/handoff-tstse1.md"
se_in clear | bash "$STUB"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$SF" ] && ok "/clear でスタブを自動生成(セッション別ファイル)" || ng "スタブ未生成 (rc=$rc)"
grep -q "自動生成スタブ" "$SF" && grep -q "statuslineを2行にして" "$SF" && ok "スタブに直近プロンプトを収録" || ng "スタブ内容不備"
grep -q "$TRS" "$SF" && grep -q "部分検索" "$SF" && ok "元トランスクリプトへのポインタ+部分検索指示" || ng "ポインタ欠落"
grep -q "$WP" "$SF" && ok "ディレクトリと日時をスタブ自身に記録" || ng "cwd 記録なし"
# 新鮮な(モデルが書いた)共有 handoff.md があれば、良質なバトンがある前提でスタブを作らない
printf '# 手書きhandoff\n' > "$WP/.claude/handoff.md"
rm -f "$SF"
se_in clear | bash "$STUB"
[ ! -f "$SF" ] && grep -q "手書きhandoff" "$WP/.claude/handoff.md" && ok "48時間以内の共有 handoff があればスタブを作らない(上書きしない)" || ng "既存 handoff が上書きされた"
# clear 以外の reason では書かない
rm -f "$WP/.claude/"handoff*.md
se_in logout | bash "$STUB"
[ ! -f "$SF" ] && ok "reason=logout では生成しない(clear 限定)" || ng "clear 以外で生成された"
# .claude ディレクトリの無いプロジェクトを汚染しない
WNP="$SB/noclaude"; mkdir -p "$WNP"
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s"}' "$WNP" "$TRS" | bash "$STUB"
[ ! -e "$WNP/.claude" ] && ok ".claude の無いディレクトリには何も作らない" || ng "無関係ディレクトリを汚染"
# 無効化フラグ
se_in clear | CLAUDE_HANDOFF_AUTOSTUB=0 bash "$STUB"
[ ! -f "$SF" ] && ok "CLAUDE_HANDOFF_AUTOSTUB=0 で無効化" || ng "無効化が効かない"
# 精度向上: git リポジトリなら「作業中ファイル(git status)」と「直近コミット」を収録する
WG="$SB/gitstubproj"; mkdir -p "$WG/.claude"
( cd "$WG" && git init -q && git config user.email t@t && git config user.name t \
  && echo base > tracked.txt && git add tracked.txt && git commit -qm "seed: 初期コミット" \
  && echo edit >> tracked.txt && echo new > untracked.txt ) >/dev/null 2>&1
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s","session_id":"tst-git1"}' "$WG" "$TRS" | bash "$STUB"
GF="$WG/.claude/handoff-tstgit1.md"
grep -q "作業中のファイル" "$GF" 2>/dev/null && grep -q "untracked.txt" "$GF" 2>/dev/null && ok "スタブに未コミットの作業中ファイル(git status)を収録" || ng "git status セクション欠落"
grep -q "直近のコミット" "$GF" 2>/dev/null && grep -q "初期コミット" "$GF" 2>/dev/null && ok "スタブに直近コミット(直前に確定した成果)を収録" || ng "直近コミット欠落"
# git 管理外のプロジェクトでは git セクションを出さない(壊れず素通し)
rm -f "$WP/.claude/"handoff*.md; se_in clear | bash "$STUB"
grep -q "作業中のファイル" "$SF" 2>/dev/null && ng "非gitプロジェクトに git セクションが混入" || ok "非gitプロジェクトでは git セクションを出さない"
HOFF="$ROOT/home/skills/handoff/SKILL.md"
[ -f "$HOFF" ] && grep -q '^name: handoff$' "$HOFF" && ok "/handoff スキル(半自動・モデル品質の引き継ぎ)が存在" || ng "/handoff スキル不備"
grep -q '40行以内' "$HOFF" && ok "handoff スキルにサイズ上限(40行)を明記" || ng "サイズ上限なし"
grep -q '次の一手' "$HOFF" && grep -q '現在地' "$HOFF" && ok "handoff スキルが精度要素(次の一手/現在地)を要求" || ng "精度要素が未定義"
grep -q '現在地' "$NOTICE" && ok "notice が再開前のスナップショット照合(現在地/git status)を指示" || ng "notice に照合指示がない"

echo "== 22. handoff アーカイブ(履歴・並行タスク → .claude/notes/) =="
ARCH="$ROOT/home/hooks/handoff-archive.sh"
WA="$SB/archproj"; mkdir -p "$WA/.claude"
printf '# handoff: statusline 2行化の続き\n## 再開手順\n1. done\n' > "$WA/.claude/handoff.md"
out=$(bash "$ARCH" "$WA"); rc=$?
[ "$rc" -eq 0 ] && ok "アーカイブ実行が成功" || ng "アーカイブ失敗 (rc=$rc)"
[ ! -f "$WA/.claude/handoff.md" ] && ok "元 handoff.md は move(削除)される" || ng "handoff.md が残存"
archived=$(ls "$WA/.claude/notes/"*.md 2>/dev/null | head -1)
[ -n "$archived" ] && ok "notes/ にアーカイブファイルが生成" || ng "notes/ にファイルなし"
case "$(basename "$archived")" in *"statusline"*"2行化"*".md") ok "ファイル名=日時+タイトルslug(索引そのもの・日本語保持)";; *) ng "slug 不正: $(basename "$archived")";; esac
case "$(basename "$archived")" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-*) ok "ファイル名先頭が YYYYMMDD-HHMM";; *) ng "日時プレフィックス不正: $(basename "$archived")";; esac
grep -q "statusline 2行化の続き" "$archived" && ok "本文がそのまま退避されている" || ng "本文が退避されていない"
# handoff が無いときは安全に no-op(exit 0)
bash "$ARCH" "$SB/noproj" >/dev/null 2>&1
assert_exit "handoff.md 不在でも安全(no-op)" 0 $?
# autostub 連携: CLAUDE_HANDOFF_ARCHIVE=1 かつ陳腐化した実 handoff は退避してからスタブ生成
WB="$SB/archstub"; mkdir -p "$WB/.claude"
printf '# handoff: 古い実作業メモ\n## 再開手順\n1. x\n' > "$WB/.claude/handoff.md"
touch -d '3 days ago' "$WB/.claude/handoff.md"   # >48h → スタブ上書き対象
TRB="$SB/archstub.jsonl"; { user_line 1; usage_line 1 claude-sonnet-5 1000 0 0 500; } > "$TRB"
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s"}' "$WB" "$TRB" | CLAUDE_HANDOFF_ARCHIVE=1 bash "$STUB"
ls "$WB/.claude/notes/"*"古い実作業メモ"*.md >/dev/null 2>&1 && ok "autostub: 陳腐化した実 handoff を退避してから上書き" || ng "退避されなかった"
grep -q "自動生成スタブ" "$WB/.claude/handoff.md" && ok "退避後に新しい自動スタブを生成" || ng "スタブが生成されていない"
# 自動生成スタブ自身は退避しない(ノイズ回避)
WC="$SB/archstub2"; mkdir -p "$WC/.claude/notes"
printf '# handoff(自動生成スタブ)\n- 生成: x\n' > "$WC/.claude/handoff.md"
touch -d '3 days ago' "$WC/.claude/handoff.md"
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s"}' "$WC" "$TRB" | CLAUDE_HANDOFF_ARCHIVE=1 bash "$STUB"
[ -z "$(ls "$WC/.claude/notes/" 2>/dev/null)" ] && ok "自動生成スタブは退避しない(履歴ノイズ回避)" || ng "スタブが退避された"
# アーカイブ運用が既定オフ(削除運用)であること
WD="$SB/archoff"; mkdir -p "$WD/.claude"
printf '# handoff: 退避対象外\n' > "$WD/.claude/handoff.md"; touch -d '3 days ago' "$WD/.claude/handoff.md"
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s"}' "$WD" "$TRB" | bash "$STUB"
[ ! -d "$WD/.claude/notes" ] && ok "CLAUDE_HANDOFF_ARCHIVE 未設定なら notes/ を作らない(既定は削除運用)" || ng "既定でアーカイブが作動した"
grep -q '^name: handoff$' "$HOFF" && grep -q 'handoff-archive.sh' "$HOFF" && ok "/handoff スキルがアーカイブ手順を案内" || ng "スキルにアーカイブ案内なし"
grep -q 'notes/' "$ROOT/project-template/.gitignore" && ok "project-template の .gitignore が notes/ を既定除外" || ng ".gitignore に notes/ がない"

echo "== 23. モデル/effort 過剰検知の規範(双方向)=="
grep -q '過剰側の提案は控えめに' "$ROOT/home/rules/cost-optimization.md" && ok "CLAUDE.md に過剰検知(下位提案・控えめ)の規範がある" || ng "過剰検知の規範がない"
grep -q '切替はユーザー操作が必要' "$ROOT/home/rules/cost-optimization.md" && ok "規範が「提案のみ・実切替はユーザー操作」の限界を明記" || ng "限界の明記がない"
tok2=$(bash "$EST" "$ROOT/home/rules/cost-optimization.md" | awk 'NR==2{print $4}')
[ "$tok2" -lt 1000 ] 2>/dev/null && ok "規範追加後も CLAUDE.md が1000トークン未満($tok2)" || ng "CLAUDE.md が肥大化: $tok2 トークン"
grep -q '双方向' "$ROOT/docs/cost-optimization.md" && ok "docs にモデル規範が双方向である旨を記載" || ng "docs に双方向の記載がない"
grep -q 'launch-effort pin' "$ROOT/docs/cost-optimization.md" && ok "docs が effort 固定(変更不可)ケースに言及" || ng "effort 固定への言及がない"
grep -q 'セッション一度きり' "$ROOT/home/rules/cost-optimization.md" && ok "CLAUDE.md の下位提案がナグ防止(一度きり)に制約" || ng "ナグ防止の制約がない"

echo "== 24. 1日合計コスト(セッション横断・/clear でズレない) =="
today=$(date +%Y%m%d); ddir="$CLAUDE_CONFIG_DIR/cost-daily"
au_() { printf '{"type":"assistant","message":{"id":"m%s","model":"claude-sonnet-5","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":%s}}}\n' "$1" "$2" "$3"; }
dsum() { cat "$ddir/${today}-"*.sum 2>/dev/null | awk '{s+=$1}END{printf "%.2f",s+0}'; }
rm -f "$ddir/${today}-"*.sum "$ddir/session-"*.base 2>/dev/null
TDA="$SB/dayA.jsonl"; { user_line 1; au_ 1 100000 100000; } > "$TDA"   # sonnet: 100k*3+100k*15=1.80
guard_in PreToolUse dcsA Read x "$TDA" | bash "$GUARD" >/dev/null 2>&1
{ user_line 2; au_ 2 100000 100000; } >> "$TDA"
guard_in PreToolUse dcsA Read x "$TDA" | bash "$GUARD" >/dev/null 2>&1
[ "$(dsum)" = "3.60" ] && ok "単一セッションの当日コストを正しく積む(3.60)" || ng "日次積算が不正: $(dsum)(期待3.60)"
TDB="$SB/dayB.jsonl"; { user_line 1; au_ 1 100000 0; } > "$TDB"   # 0.30
guard_in PreToolUse dcsB Read x "$TDB" | bash "$GUARD" >/dev/null 2>&1
[ "$(dsum)" = "3.90" ] && ok "別セッションの寄与を二重計上せず合算(3.90)" || ng "セッション横断合算が不正: $(dsum)(期待3.90)"
user_line 9 > "$TDA"   # /clear(トランスクリプト縮小)
guard_in PreToolUse dcsA Read x "$TDA" | bash "$GUARD" >/dev/null 2>&1
[ "$(dsum)" = "3.90" ] && ok "/clear で日次合計が減らない(過去分を保持)" || ng "/clear で日次が減った: $(dsum)"
au_ 9 100000 0 >> "$TDA"   # /clear 後に 0.30 積み増し
guard_in PreToolUse dcsA Read x "$TDA" | bash "$GUARD" >/dev/null 2>&1
[ "$(dsum)" = "4.20" ] && ok "/clear 後の積み増しも取りこぼさず加算(4.20)" || ng "/clear後の積み増しが欠落: $(dsum)(期待4.20)"
# 別日のベースライン(日跨ぎ)は過去分を当日へ持ち込まない
rm -f "$ddir/${today}-"*.sum 2>/dev/null; printf '99.0 20200101\n' > "$ddir/session-dcsC.base"
TDC="$SB/dayC.jsonl"; { user_line 1; au_ 1 100000 0; } > "$TDC"
guard_in PreToolUse dcsC Read x "$TDC" | bash "$GUARD" >/dev/null 2>&1
[ "$(dsum)" = "0.00" ] && ok "日跨ぎは前日累積を当日へ持ち込まない(0.00)" || ng "日跨ぎで過去分が混入: $(dsum)"
# statusline が 📅 で日次合計を表示
rm -f "$ddir/${today}-"*.sum; printf '2.500000\n' > "$ddir/${today}-slsess.sum"
slday=$(printf '{"model":{"display_name":"S"},"session_id":"slsess","transcript_path":""}' | CLAUDE_STATUSLINE_DAILY=1 bash "$STATUS" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$slday" in *"📅 \$2.50"*) ok "statusline が 1日合計(📅)を表示";; *) ng "日次表示なし: [$slday]";; esac

echo "== 25. セッションコストの /clear リセット + handoff 衝突回避 =="
# /clear(トランスクリプト縮小=state offset > 現ファイルサイズ)でバーのコストが 0 に戻る
CLR="$SB/clr.jsonl"; { user_line 1; usage_line 1 claude-sonnet-5 100000 0 0 100000; } > "$CLR"  # $1.80
guard_in PreToolUse clrs Read x "$CLR" | bash "$GUARD" >/dev/null 2>&1
before=$(printf '{"model":{"display_name":"S"},"session_id":"clrs","transcript_path":"%s"}' "$CLR" | bash "$STATUS" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$before" in *'$1.80/$5'*) ok 'セッションコストをガード推定で表示(/clear前 $1.80)';; *) ng "コスト表示不正: [$before]";; esac
user_line 9 > "$CLR"   # /clear 相当でトランスクリプト縮小(state はまだ更新前=陳腐化)
after=$(printf '{"model":{"display_name":"S"},"session_id":"clrs","transcript_path":"%s"}' "$CLR" | bash "$STATUS" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$after" in *'$0.00/$5'*) ok "/clear(トランスクリプト縮小)でコストが即 0 にリセット";; *) ng "/clear でコストが0に戻らない: [$after]";; esac
# handoff 衝突回避: 2セッションの /clear が別ファイルになり、notice は最新を注入
HP="$SB/hcproj"; mkdir -p "$HP/.claude"; HTR="$SB/hc.jsonl"; user_line 1 > "$HTR"
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s","session_id":"AAAAAAAA1111"}' "$HP" "$HTR" | bash "$STUB"
printf '{"hook_event_name":"SessionEnd","reason":"clear","cwd":"%s","transcript_path":"%s","session_id":"BBBBBBBB2222"}' "$HP" "$HTR" | bash "$STUB"
n1=$(ls "$HP/.claude/"handoff-*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$n1" = "2" ] && ok "並行セッションの handoff が別ファイルで共存(衝突しない)" || ng "handoff ファイル数が想定外: $n1"
nout=$(printf '{"cwd":"%s"}' "$HP" | bash "$NOTICE")
case "$nout" in *"handoff-BBBBBBBB"*) ok "notice は最新の handoff(セッションB)を注入";; *) ng "最新 handoff を選べていない";; esac

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
