#!/usr/bin/env bash
# セッション予算ガード(サーキットブレーカー)
#
# トランスクリプト(各ターンの usage が記録された JSONL)から現在セッションの
# 推定コストを毎回集計し、
#   - 警告閾値超過: 一度だけツール実行をブロックして Claude に是正を指示
#     (/compact・explore 委譲・作業の絞り込み)。以降は通す。
#   - 上限超過:     すべてのツール実行(PreToolUse)と新規プロンプト
#     (UserPromptSubmit)をブロックする。
#
# モデル呼び出しを一切行わない決定論的スクリプトなので、ガード自体のコストはゼロ。
#
# 設定(settings.json の env またはシェル環境変数):
#   CLAUDE_SESSION_BUDGET_USD       セッション上限(USD)。デフォルト 5
#   CLAUDE_SESSION_BUDGET_WARN_USD  警告閾値(USD)。デフォルトは上限の 50%
#
# 制約(README/docs 参照):
#   - 進行中の1リクエストは止められない(検知は次のフック発火時点)
#   - 推定単価は代表値。実際の請求額とは誤差がある
set -euo pipefail

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

HARD="${CLAUDE_SESSION_BUDGET_USD:-5}"
WARN="${CLAUDE_SESSION_BUDGET_WARN_USD:-}"
if [ -z "$WARN" ]; then
  WARN=$(awk -v h="$HARD" 'BEGIN{printf "%.4f", h * 0.5}')
fi

# トランスクリプトの usage を集計して推定コスト(USD)を出す。
# 同一メッセージが複数行に分かれて記録される場合があるため message.id で重複排除。
# 単価は代表値(/1M tokens): opus 5/25, haiku 1/5, その他(sonnet等) 3/15。
# キャッシュ書込は入力の1.25倍、キャッシュ読出は0.1倍。
cost=$(jq -s '
  def price(m):
    if   ((m // "") | test("opus"))  then {i: 5, o: 25}
    elif ((m // "") | test("haiku")) then {i: 1, o: 5}
    else {i: 3, o: 15} end;
  [ .[]
    | select(.message.usage != null)
  ]
  | unique_by(.message.id // .uuid)
  | [ .[]
      | price(.message.model) as $p
      | (.message.usage.input_tokens // 0)                  * $p.i
      + (.message.usage.cache_creation_input_tokens // 0)   * $p.i * 1.25
      + (.message.usage.cache_read_input_tokens // 0)       * $p.i * 0.1
      + (.message.usage.output_tokens // 0)                 * $p.o
    ]
  | (add // 0) / 1000000
' "$transcript" 2>/dev/null) || exit 0

over_hard=$(awk -v c="$cost" -v h="$HARD" 'BEGIN{print (c >= h) ? 1 : 0}')
over_warn=$(awk -v c="$cost" -v w="$WARN" 'BEGIN{print (c >= w) ? 1 : 0}')
cost_fmt=$(awk -v c="$cost" 'BEGIN{printf "%.2f", c}')

if [ "$over_hard" = "1" ]; then
  if [ "$event" = "UserPromptSubmit" ]; then
    # ユーザー向けメッセージ(exit 2 の stderr はユーザーに表示される)
    {
      echo "🛑 セッション予算超過: 推定 \$${cost_fmt} / 上限 \$${HARD}"
      echo "   このセッションでの続行はブロックされています。/clear で新しいセッションを開始してください。"
      echo "   上限の変更: settings.json の env CLAUDE_SESSION_BUDGET_USD"
    } >&2
  else
    # Claude 向けメッセージ(作業を要約して終了させる)
    {
      echo "セッション予算超過(推定 \$${cost_fmt} / 上限 \$${HARD})。これ以降のツール実行はすべてブロックされます。"
      echo "新たな作業を開始せず、ここまでの結果と未完了事項を簡潔に要約してターンを終了してください。"
      echo "続きは新しいセッションで行うようユーザーに案内してください。"
    } >&2
  fi
  exit 2
fi

if [ "$over_warn" = "1" ] && [ "$event" = "PreToolUse" ]; then
  marker="${TMPDIR:-/tmp}/claude-budget-warn-${session}"
  if [ ! -f "$marker" ]; then
    touch "$marker"
    {
      echo "予算警告: このセッションの推定コストが \$${cost_fmt} に達しました(上限 \$${HARD}、超過すると全ツール実行がブロックされます)。"
      echo "ここから先はトークン消費を抑えて進めてください:"
      echo " - 残作業を洗い出し、今のセッションで終えるべき最小範囲に絞る"
      echo " - 探索・調査は explore サブエージェントに委譲する"
      echo " - 不要になった文脈が多いなら、ユーザーに /compact または /clear を提案する"
      echo "この警告は一度だけです。同じツール呼び出しを再実行して続行してください。"
    } >&2
    exit 2
  fi
fi

exit 0
