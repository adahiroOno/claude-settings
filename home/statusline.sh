#!/usr/bin/env bash
# ステータスライン: モデル / セッションコスト / 10ターン換算ペース / 変更行数 を常時表示。
# 10ターン換算ペースは「10ターン ≒ $1」目標との乖離を一目で見るための指標。
# Claude Code から JSON が stdin で渡される。jq が無い環境ではモデル名のみ表示。
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

out="[$model]"
if [ -n "$cost" ]; then
  out="$out \$$(printf '%.2f' "$cost")"
fi

# 10ターン換算ペース(ターン数はユーザーの実プロンプト数)
# 巨大トランスクリプト(5MB超)は描画のたびの解析が重いのでスキップ(表示だけの機能のため)
if [ -n "$cost" ] && [ -n "$transcript" ] && [ -f "$transcript" ] && [ "$(wc -c < "$transcript")" -le 5000000 ]; then
  turns=$(jq -s '
    [ .[]
      | select(.type == "user")
      | select(.isMeta != true)
      | select(.toolUseResult == null)
      | (.message.content // empty)
      | if type == "string" then 1
        elif type == "array" then
          (if any(.[]?; (.type? // "") == "tool_result") then empty else 1 end)
        else empty end
    ] | length
  ' "$transcript" 2>/dev/null) || turns=0
  if [ "${turns:-0}" -ge 1 ]; then
    pace10=$(awk -v c="$cost" -v t="$turns" 'BEGIN{printf "%.2f", c / t * 10}')
    target10=$(awk -v b="${CLAUDE_TURN_BUDGET_USD:-0.10}" 'BEGIN{printf "%.2f", b * 10}')
    mark="✓"
    if awk -v p="$pace10" -v g="$target10" 'BEGIN{exit !(p > g)}'; then
      mark="⚠"
    fi
    out="$out T:${turns} 10T≈\$${pace10}${mark}"
  fi
fi

if [ -n "$added" ] || [ -n "$removed" ]; then
  out="$out +${added:-0}/-${removed:-0}"
fi
printf '%s' "$out"
