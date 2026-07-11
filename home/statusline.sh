#!/usr/bin/env bash
# ステータスライン: トークン・コスト・ペースを一目で把握するための情報密度の高い表示。
#
# 表示項目(左から):
#   モデル名 │ セッションコスト │ 10ターン換算ペース(目標対比 ✓/⚠) │
#   コンテキストサイズ+キャッシュ読出率 │ ターン数 │ 出力スタイル(既定以外) │ 変更行数
#
# 注: effort は Claude Code のハーネス内部管理で statusline 入力に含まれないため表示不可。
#     代わりに出力スタイル(terse 等のモード)を表示する。
#
# 描画のたびに呼ばれるため軽量性を優先:
#   - ターン数は予算ガードの状態ファイルを再利用(なければ小さいファイルのみ自力計算)
#   - ctx とキャッシュ率はトランスクリプト末尾100行だけから算出
set -u
input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '[claude] jq未導入'
  exit 0
fi

# ANSI 色(端末が非対応でも無害)。ラベルより色で区別して視認性を上げる。
C_MODEL=$'\033[36m'   # シアン
C_COST=$'\033[33m'    # 黄
C_OK=$'\033[32m'      # 緑
C_WARN=$'\033[31m'    # 赤
C_CTX=$'\033[35m'     # マゼンタ
C_DIM=$'\033[90m'     # グレー
C_STYLE=$'\033[34m'   # 青
R=$'\033[0m'
SEP="${C_DIM} │ ${R}"

get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

model=$(get '.model.display_name')
[ -n "$model" ] || model=$(get '.model.id')
[ -n "$model" ] || model='?'
cost=$(get '.cost.total_cost_usd')
added=$(get '.cost.total_lines_added')
removed=$(get '.cost.total_lines_removed')
transcript=$(get '.transcript_path')
session=$(get '.session_id')
style=$(get '.output_style.name')
over200k=$(get '.exceeds_200k_tokens')

segs=()
segs+=("${C_MODEL}${model}${R}")

if [ -n "$cost" ]; then
  segs+=("${C_COST}\$$(printf '%.2f' "$cost")${R}")
fi

turns=""; ctx=0; cachepct=-1
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # ターン数: 予算ガードの状態ファイル(offset raw turns ctx)を優先
  state="${TMPDIR:-/tmp}/claude-budget-state-${session}"
  if [ -n "$session" ] && [ -f "$state" ]; then
    turns=$(awk '{print $3}' "$state" 2>/dev/null || true)
    [[ "${turns:-}" =~ ^[0-9]+$ ]] || turns=""
  fi
  if [ -z "$turns" ] && [ "$(wc -c < "$transcript")" -le 2000000 ]; then
    turns=$(jq -Rn '
      [inputs | fromjson? // empty
        | select(.type == "user") | select(.isMeta != true) | select(.toolUseResult == null)
        | (.message.content // empty)
        | if type == "string" then 1
          elif type == "array" then (if any(.[]?; (.type? // "") == "tool_result") then empty else 1 end)
          else empty end
      ] | length' "$transcript" 2>/dev/null) || turns=""
  fi

  # ctx(直近リクエストの入力サイズ)とキャッシュ読出率 — 末尾100行の最後の usage から
  stats=$(tail -n 100 "$transcript" 2>/dev/null | jq -Rrn '
    [inputs | fromjson? // empty | select(.message.usage != null) | .message.usage] as $u
    | if ($u | length) == 0 then "0 -1"
      else ($u | last) as $l
        | (($l.input_tokens // 0) + ($l.cache_read_input_tokens // 0) + ($l.cache_creation_input_tokens // 0)) as $tot
        | (if $tot > 0 then (($l.cache_read_input_tokens // 0) * 100 / $tot) else -1 end) as $pct
        | "\($tot) \($pct | floor)"
      end' 2>/dev/null) || stats="0 -1"
  ctx=${stats%% *}; cachepct=${stats##* }
  [[ "$ctx" =~ ^[0-9]+$ ]] || ctx=0
  [[ "$cachepct" =~ ^-?[0-9]+$ ]] || cachepct=-1
fi

# ペース(10ターン換算)
if [ -n "$cost" ] && [[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ]; then
  pace10=$(awk -v c="$cost" -v t="$turns" 'BEGIN{printf "%.2f", c / t * 10}')
  target10=$(awk -v b="${CLAUDE_TURN_BUDGET_USD:-0.10}" 'BEGIN{printf "%.2f", b * 10}')
  if awk -v p="$pace10" -v g="$target10" 'BEGIN{exit !(p > g)}'; then
    segs+=("${C_WARN}10T:\$${pace10}⚠${R}")
  else
    segs+=("${C_OK}10T:\$${pace10}✓${R}")
  fi
fi

# ctx + キャッシュ率
if [[ "${ctx:-0}" =~ ^[0-9]+$ ]] && [ "$ctx" -ge 1000 ]; then
  ctxk=$(awk -v x="$ctx" 'BEGIN{printf "%.0f", x / 1000}')
  ctxcol="$C_CTX"; [ "$over200k" = "true" ] && ctxcol="$C_WARN"
  cseg="${ctxcol}ctx:${ctxk}k${R}"
  if [[ "${cachepct:-}" =~ ^[0-9]+$ ]] && [ "$cachepct" -ge 0 ]; then
    ccol="$C_OK"; [ "$cachepct" -lt 50 ] && ccol="$C_WARN"
    cseg="${cseg} ${ccol}${cachepct}%cache${R}"
  fi
  segs+=("$cseg")
fi

# ターン数
if [[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ]; then
  segs+=("${C_DIM}T:${turns}${R}")
fi

# 出力スタイル(既定以外のときのみ = モード表示。effort の代替情報)
if [ -n "$style" ] && [ "$style" != "default" ] && [ "$style" != "null" ]; then
  segs+=("${C_STYLE}◆${style}${R}")
fi

# 変更行数
if [ -n "$added" ] || [ -n "$removed" ]; then
  segs+=("${C_DIM}${R}${C_OK}+${added:-0}${R}/${C_WARN}-${removed:-0}${R}")
fi

# 区切って出力
out=""
for i in "${!segs[@]}"; do
  [ "$i" -eq 0 ] && out="${segs[$i]}" || out="${out}${SEP}${segs[$i]}"
done
printf '%b' "$out"
