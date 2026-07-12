#!/usr/bin/env bash
# ステータスライン: 閾値に対する使用率をバーと絵文字で可視化する情報密度の高い表示。
#
# 表示(左から):
#   🤖 モデル
#   💰/⚠️/🛑 予算バー  $cost/$上限 [██████░░░░] NN%   ← セッションコスト vs 予算($5)
#   🧠/🔴 ctxバー      NNk/上限k  [████░░░░░░] NN%   ← 現在コンテキスト vs 閾値(12万)
#   🎯/🔥 10T換算ペース(目標対比)
#   🔄 ターン数 │ 💾 キャッシュ読出率 │ ✍️ 出力スタイル │ 📝 変更行数
#
# 注: effort は Claude Code ハーネス内部管理で statusline 入力に無く表示不可。
#     代わりに出力スタイル(モード)を表示。閾値は env(なければ既定値)から取得。
#
# 軽量性: ターン数は予算ガードの状態ファイルを再利用、ctx/キャッシュ率は末尾100行のみ解析。
set -u
input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '[claude] jq未導入'
  exit 0
fi

# 閾値(予算ガードと同じ env。statusline に env が渡らなければ既定値)
BUDGET="${CLAUDE_SESSION_BUDGET_USD:-5}"
CTXLIM="${CLAUDE_CTX_LIMIT_TOKENS:-120000}"

# ANSI 色
C_OK=$'\033[32m'; C_MID=$'\033[33m'; C_WARN=$'\033[31m'
C_MODEL=$'\033[36m'; C_DIM=$'\033[90m'; C_STYLE=$'\033[34m'; R=$'\033[0m'
SEP="${C_DIM} │ ${R}"

get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# 割合(整数%)に応じた色
pct_color() { if [ "$1" -ge 90 ]; then printf '%s' "$C_WARN"; elif [ "$1" -ge 70 ]; then printf '%s' "$C_MID"; else printf '%s' "$C_OK"; fi; }
# 使用率バー(塗り=状態色、空=グレー)。$1=percent $2=width
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

segs=()
segs+=("${C_MODEL}🤖 ${model}${R}")

# 予算バー(コスト / 上限)
if [ -n "$cost" ]; then
  bpct=$(awk -v c="$cost" -v b="$BUDGET" 'BEGIN{ if(b<=0){print 0}else{printf "%d", c/b*100} }')
  emo="💰"; [ "$bpct" -ge 100 ] && emo="🛑"; [ "$bpct" -ge 80 ] && [ "$bpct" -lt 100 ] && emo="⚠️"
  segs+=("${emo} \$$(printf '%.2f' "$cost")/\$${BUDGET} $(make_bar "$bpct" 10) ${bpct}%")
fi

turns=""; ctx=0; cachepct=-1
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  state="${TMPDIR:-/tmp}/claude-budget-state-${session}"
  if [ -n "$session" ] && [ -f "$state" ]; then
    turns=$(awk '{print $3}' "$state" 2>/dev/null || true); [[ "${turns:-}" =~ ^[0-9]+$ ]] || turns=""
  fi
  if [ -z "$turns" ] && [ "$(wc -c < "$transcript")" -le 2000000 ]; then
    turns=$(jq -Rn '[inputs|fromjson? // empty|select(.type=="user")|select(.isMeta!=true)|select(.toolUseResult==null)|(.message.content // empty)|if type=="string" then 1 elif type=="array" then (if any(.[]?;(.type? // "")=="tool_result") then empty else 1 end) else empty end]|length' "$transcript" 2>/dev/null) || turns=""
  fi
  stats=$(tail -n 100 "$transcript" 2>/dev/null | jq -Rrn '
    [inputs|fromjson? // empty|select(.message.usage!=null)|.message.usage] as $u
    | if ($u|length)==0 then "0 -1"
      else ($u|last) as $l
        | (($l.input_tokens//0)+($l.cache_read_input_tokens//0)+($l.cache_creation_input_tokens//0)) as $t
        | (if $t>0 then (($l.cache_read_input_tokens//0)*100/$t) else -1 end) as $p
        | "\($t) \($p|floor)" end' 2>/dev/null) || stats="0 -1"
  ctx=${stats%% *}; cachepct=${stats##* }
  [[ "$ctx" =~ ^[0-9]+$ ]] || ctx=0
  [[ "$cachepct" =~ ^-?[0-9]+$ ]] || cachepct=-1
fi

# ctxバー(現在コンテキスト / 閾値)
if [ "${ctx:-0}" -ge 1000 ]; then
  cpct=$(( ctx * 100 / CTXLIM ))
  ctxk=$(awk -v x="$ctx" 'BEGIN{printf "%.0f", x/1000}')
  limk=$(awk -v x="$CTXLIM" 'BEGIN{printf "%.0f", x/1000}')
  cemo="🧠"; { [ "$cpct" -ge 90 ] || [ "$over200k" = "true" ]; } && cemo="🔴"
  segs+=("${cemo} ${ctxk}k/${limk}k $(make_bar "$cpct" 10) ${cpct}%")
fi

# 10ターン換算ペース
if [ -n "$cost" ] && [[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ]; then
  pace10=$(awk -v c="$cost" -v t="$turns" 'BEGIN{printf "%.2f", c/t*10}')
  target10=$(awk -v b="${CLAUDE_TURN_BUDGET_USD:-0.10}" 'BEGIN{printf "%.2f", b*10}')
  if awk -v p="$pace10" -v g="$target10" 'BEGIN{exit !(p>g)}'; then
    segs+=("${C_WARN}🔥 10T:\$${pace10}${R}")
  else
    segs+=("${C_OK}🎯 10T:\$${pace10}${R}")
  fi
fi

# ターン数
[[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ] && segs+=("${C_DIM}🔄 ${turns}${R}")

# キャッシュ読出率(取得できたとき)
if [[ "${cachepct:-}" =~ ^[0-9]+$ ]] && [ "$cachepct" -ge 0 ]; then
  ccol="$C_OK"; [ "$cachepct" -lt 50 ] && ccol="$C_WARN"
  segs+=("${ccol}💾 ${cachepct}%${R}")
fi

# 出力スタイル(既定以外 = モード)
[ -n "$style" ] && [ "$style" != "default" ] && [ "$style" != "null" ] && segs+=("${C_STYLE}✍️ ${style}${R}")

# 変更行数
if [ -n "$added" ] || [ -n "$removed" ]; then
  segs+=("📝 ${C_OK}+${added:-0}${R}/${C_WARN}-${removed:-0}${R}")
fi

out=""
for i in "${!segs[@]}"; do [ "$i" -eq 0 ] && out="${segs[$i]}" || out="${out}${SEP}${segs[$i]}"; done
printf '%b' "$out"
