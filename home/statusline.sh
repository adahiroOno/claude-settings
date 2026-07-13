#!/usr/bin/env bash
# ステータスライン: 閾値に対する使用率をバーと絵文字で可視化。
# Claude Code が stdin に渡す公式 JSON(https://code.claude.com/docs/ja/statusline)を利用する。
#
# 表示(既定は2行。CLAUDE_STATUSLINE_LINES=1 で単一行):
#   1行目(環境・コンテキスト):
#     🤖 モデル │ ⚡ effort │ 🧠/🔴 ctxバー(現在/閾値 [██░░] %)│
#     💾 キャッシュ読出率 │ 📊 レート制限(サブスク時)│ ✍️ 出力スタイル │ 💭 thinking
#   2行目(コスト・進捗):
#     💰/⚠️/🛑 予算バー($cost/$上限 [██░░] %)│ 🎯/🔥 10T換算ペース │
#     🔄 ターン(上限設定時は 現在/上限)│ 📝 変更行 │ 🎫 トークン内訳(opt-in)
#
# トークン情報は公式 context_window.current_usage を使用(自作トランスクリプト解析は不要)。
# ターン数のみ予算ガードの状態ファイル(なければ軽量なトランスクリプト集計)から取得。
set -u
export LC_NUMERIC=C   # 小数点カンマのロケールで printf '%.2f' が壊れるのを防ぐ
input=$(cat)
command -v jq >/dev/null 2>&1 || { printf '[claude] jq未導入'; exit 0; }

BUDGET="${CLAUDE_SESSION_BUDGET_USD:-5}"
CTXLIM="${CLAUDE_CTX_LIMIT_TOKENS:-120000}"

C_OK=$'\033[32m'; C_MID=$'\033[33m'; C_WARN=$'\033[31m'
C_MODEL=$'\033[36m'; C_DIM=$'\033[90m'; C_STYLE=$'\033[34m'; C_EFF=$'\033[35m'; R=$'\033[0m'
SEP="${C_DIM} │ ${R}"

get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
fmt() { awk -v n="${1:-0}" 'BEGIN{ if(n>=1000000){printf "%.1fM",n/1000000} else if(n>=1000){printf "%.0fk",n/1000} else {printf "%d",n} }'; }
pct_color() { if [ "$1" -ge 90 ]; then printf '%s' "$C_WARN"; elif [ "$1" -ge 70 ]; then printf '%s' "$C_MID"; else printf '%s' "$C_OK"; fi; }
make_bar() {
  local pct="$1" w="${2:-10}" col; col=$(pct_color "$1")
  [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=0
  local filled=$(( pct * w / 100 )) i=0 f="" e=""
  while [ "$i" -lt "$filled" ]; do f="${f}█"; i=$((i+1)); done
  while [ "$i" -lt "$w" ];      do e="${e}░"; i=$((i+1)); done
  printf '%s%s%s%s%s' "$col" "$f" "$C_DIM" "$e" "$R"
}

model=$(get '.model.display_name'); [ -n "$model" ] || model=$(get '.model.id'); [ -n "$model" ] || model='?'
cost=$(get '.cost.total_cost_usd')
added=$(get '.cost.total_lines_added'); removed=$(get '.cost.total_lines_removed')
transcript=$(get '.transcript_path'); session=$(get '.session_id')
style=$(get '.output_style.name'); over200k=$(get '.exceeds_200k_tokens')
effort=$(get '.effort.level'); thinking=$(get '.thinking.enabled')
# 公式 context_window(事前計算): 現在のコンテキスト内訳
cu_in=$(get '.context_window.current_usage.input_tokens')
cu_rd=$(get '.context_window.current_usage.cache_read_input_tokens')
cu_wr=$(get '.context_window.current_usage.cache_creation_input_tokens')
cu_out=$(get '.context_window.current_usage.output_tokens')
# レート制限(Pro/Max サブスクのみ存在)
r5=$(get '.rate_limits.five_hour.used_percentage'); r7=$(get '.rate_limits.seven_day.used_percentage')
for v in cu_in cu_rd cu_wr cu_out; do eval "[[ \"\${$v:-}\" =~ ^[0-9]+$ ]] || $v=0"; done

ctx=$(( cu_in + cu_rd + cu_wr ))
if [ "$ctx" -gt 0 ]; then cachepct=$(( cu_rd * 100 / ctx )); else cachepct=-1; fi

# ターン数(ペース算出用): 予算ガードの状態ファイル → なければトランスクリプト
turns=""
state="${TMPDIR:-/tmp}/claude-budget-state-${session}"
if [ -n "$session" ] && [ -f "$state" ]; then
  turns=$(awk '{print $3}' "$state" 2>/dev/null || true); [[ "${turns:-}" =~ ^[0-9]+$ ]] || turns=""
fi
if [ -z "$turns" ] && [ -n "$transcript" ] && [ -f "$transcript" ] && [ "$(wc -c < "$transcript")" -le 2000000 ]; then
  turns=$(jq -Rn '[inputs|fromjson? // empty|select(.type=="user")|select(.isMeta!=true)|select(.toolUseResult==null)|(.message.content // empty)|if type=="string" then 1 elif type=="array" then (if any(.[]?;(.type? // "")=="tool_result") then empty else 1 end) else empty end]|length' "$transcript" 2>/dev/null) || turns=""
fi

# 各セグメントに「行グループ」を付けて格納する。
#   グループ1 = 環境・コンテキスト(モデル/effort/ctx/キャッシュ/レート制限/スタイル/thinking)
#   グループ2 = コスト・進捗    (予算バー/ペース/ターン数/変更行/トークン内訳)
# 表示行数は CLAUDE_STATUSLINE_LINES で切替(既定 2。"1" で従来の単一行)。
# segs は追加順(=単一行時の並び)を保持し、grp で行を振り分ける。
segs=(); grp=()
add() { grp+=("$1"); segs+=("$2"); }   # $1=行グループ, $2=表示文字列

add 1 "${C_MODEL}🤖 ${model}${R}"

# effort(モデルが対応する場合のみ)
[ -n "$effort" ] && [ "$effort" != "null" ] && add 1 "${C_EFF}⚡ ${effort}${R}"

# 予算バー
if [ -n "$cost" ]; then
  bpct=$(awk -v c="$cost" -v b="$BUDGET" 'BEGIN{ if(b<=0){print 0}else{printf "%d", c/b*100} }')
  emo="💰"; [ "$bpct" -ge 100 ] && emo="🛑"; [ "$bpct" -ge 80 ] && [ "$bpct" -lt 100 ] && emo="⚠️"
  add 2 "${emo} \$$(printf '%.2f' "$cost")/\$${BUDGET} $(make_bar "$bpct" 10) ${bpct}%"
fi

# ctxバー(現在コンテキスト / 肥大ガード閾値)
if [ "$ctx" -ge 1000 ]; then
  cpct=$(( ctx * 100 / CTXLIM ))
  cemo="🧠"; { [ "$cpct" -ge 90 ] || [ "$over200k" = "true" ]; } && cemo="🔴"
  add 1 "${cemo} $(fmt "$ctx")/$(fmt "$CTXLIM") $(make_bar "$cpct" 10) ${cpct}%"
fi

# 10ターン換算ペース
if [ -n "$cost" ] && [[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ]; then
  pace10=$(awk -v c="$cost" -v t="$turns" 'BEGIN{printf "%.2f", c/t*10}')
  target10=$(awk -v b="${CLAUDE_TURN_BUDGET_USD:-0.10}" 'BEGIN{printf "%.2f", b*10}')
  if awk -v p="$pace10" -v g="$target10" 'BEGIN{exit !(p>g)}'; then add 2 "${C_WARN}🔥 10T:\$${pace10}${R}"; else add 2 "${C_OK}🎯 10T:\$${pace10}${R}"; fi
fi

# ターン数(CLAUDE_TURN_HARD_LIMIT 設定時は n/上限 を使用率の色で表示)
if [[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ]; then
  TLIM="${CLAUDE_TURN_HARD_LIMIT:-0}"
  if [[ "$TLIM" =~ ^[0-9]+$ ]] && [ "$TLIM" -gt 0 ]; then
    tpct=$(( turns * 100 / TLIM ))
    add 2 "$(pct_color "$tpct")🔄 ${turns}/${TLIM}${R}"
  else
    add 2 "${C_DIM}🔄 ${turns}${R}"
  fi
fi

# キャッシュ読出率
if [ "$cachepct" -ge 0 ]; then
  ccol="$C_OK"; [ "$cachepct" -lt 50 ] && ccol="$C_WARN"; add 1 "${ccol}💾 ${cachepct}%${R}"
fi

# レート制限(サブスクのみ。トークン枠の消費 = 使いすぎ防止の指標)
if [ -n "$r5" ] || [ -n "$r7" ]; then
  rl="📊"
  [ -n "$r5" ] && { r5i=$(printf '%.0f' "$r5"); rc=$(pct_color "$r5i"); rl="$rl ${rc}5h:${r5i}%${R}"; }
  [ -n "$r7" ] && { r7i=$(printf '%.0f' "$r7"); rc=$(pct_color "$r7i"); rl="$rl ${rc}7d:${r7i}%${R}"; }
  add 1 "$rl"
fi

# 出力スタイル(既定以外)
[ -n "$style" ] && [ "$style" != "default" ] && [ "$style" != "null" ] && add 1 "${C_STYLE}✍️ ${style}${R}"

# thinking(有効時のみ)
[ "$thinking" = "true" ] && add 1 "${C_DIM}💭${R}"

# 変更行数
if [ -n "$added" ] || [ -n "$removed" ]; then add 2 "📝 ${C_OK}+${added:-0}${R}/${C_WARN}-${removed:-0}${R}"; fi

# トークン内訳: 直近リクエストの 新規入力/キャッシュ読出/キャッシュ書込/出力。
# 2行表示で幅に余裕があるため既定で表示(CLAUDE_STATUSLINE_TOKENS=0 で非表示)
if [ "${CLAUDE_STATUSLINE_TOKENS:-1}" = "1" ] && [ "$ctx" -gt 0 ]; then
  add 2 "${C_DIM}🎫 in:$(fmt "$cu_in") rd:$(fmt "$cu_rd") wr:$(fmt "$cu_wr") out:$(fmt "$cu_out")${R}"
fi

# 指定グループのセグメントを SEP 連結する($1="*" で全グループ=単一行)。空でも安全。
render_line() {
  local want="$1" out="" first=1 i
  for i in "${!segs[@]}"; do
    if [ "$want" = "*" ] || [ "${grp[$i]}" = "$want" ]; then
      if [ "$first" -eq 1 ]; then out="${segs[$i]}"; first=0; else out="${out}${SEP}${segs[$i]}"; fi
    fi
  done
  printf '%s' "$out"
}

if [ "${CLAUDE_STATUSLINE_LINES:-2}" = "1" ]; then
  printf '%b' "$(render_line '*')"
else
  line1=$(render_line 1); line2=$(render_line 2)
  # 2行目が空(初回API前など)のときは改行を出さず1行にする
  if [ -n "$line2" ]; then printf '%b\n%b' "$line1" "$line2"; else printf '%b' "$line1"; fi
fi
