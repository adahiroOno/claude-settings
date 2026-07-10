#!/usr/bin/env bash
# ステータスライン: モデル / セッションコスト / 10ターン換算ペース / コンテキストサイズ / 変更行数。
# - 10ターン換算ペース: 「10ターン ≒ $1」目標との乖離を一目で見る指標
# - ctx: 現在のコンテキストサイズ(毎ターンの入力コストを決める。/clear 判断の材料)
# 描画のたびに呼ばれるため軽量性を優先:
# - ターン数は予算ガードが維持する状態ファイルから読む(なければ小さいファイルのみ自力計算)
# - ctx はトランスクリプト末尾100行だけから算出
set -u
input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '[claude] jq未導入のためコスト表示不可'
  exit 0
fi

model=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"')
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')
added=$(printf '%s' "$input" | jq -r '.cost.total_lines_added // empty')
removed=$(printf '%s' "$input" | jq -r '.cost.total_lines_removed // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session=$(printf '%s' "$input" | jq -r '.session_id // empty')

out="[$model]"
if [ -n "$cost" ]; then
  out="$out \$$(printf '%.2f' "$cost")"
fi

if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # ターン数: 予算ガードの状態ファイル(offset raw turns)を優先
  turns=""
  state="${TMPDIR:-/tmp}/claude-budget-state-${session}"
  if [ -n "$session" ] && [ -f "$state" ]; then
    turns=$(awk '{print $3}' "$state" 2>/dev/null || true)
    [[ "${turns:-}" =~ ^[0-9]+$ ]] || turns=""
  fi
  if [ -z "$turns" ] && [ "$(wc -c < "$transcript")" -le 2000000 ]; then
    turns=$(jq -Rn '
      [inputs | fromjson? // empty
        | select(.type == "user")
        | select(.isMeta != true)
        | select(.toolUseResult == null)
        | (.message.content // empty)
        | if type == "string" then 1
          elif type == "array" then
            (if any(.[]?; (.type? // "") == "tool_result") then empty else 1 end)
          else empty end
      ] | length
    ' "$transcript" 2>/dev/null) || turns=""
  fi

  if [ -n "$cost" ] && [[ "${turns:-}" =~ ^[0-9]+$ ]] && [ "$turns" -ge 1 ]; then
    pace10=$(awk -v c="$cost" -v t="$turns" 'BEGIN{printf "%.2f", c / t * 10}')
    target10=$(awk -v b="${CLAUDE_TURN_BUDGET_USD:-0.10}" 'BEGIN{printf "%.2f", b * 10}')
    mark="✓"
    if awk -v p="$pace10" -v g="$target10" 'BEGIN{exit !(p > g)}'; then
      mark="⚠"
    fi
    out="$out T:${turns} 10T≈\$${pace10}${mark}"
  fi

  # ctx: 直近の assistant usage から現在のコンテキストサイズを推定(末尾100行のみ解析)
  ctx=$(tail -n 100 "$transcript" 2>/dev/null | jq -Rn '
    [inputs | fromjson? // empty | select(.message.usage != null)]
    | if length == 0 then 0
      else (last | .message.usage
            | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
      end
  ' 2>/dev/null) || ctx=0
  if [[ "${ctx:-0}" =~ ^[0-9]+$ ]] && [ "$ctx" -ge 1000 ]; then
    ctxk=$(awk -v x="$ctx" 'BEGIN{printf "%.0f", x / 1000}')
    out="$out ctx:${ctxk}k"
  fi
fi

if [ -n "$added" ] || [ -n "$removed" ]; then
  out="$out +${added:-0}/-${removed:-0}"
fi
printf '%s' "$out"
