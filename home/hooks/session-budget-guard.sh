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
# さらに「ターン数に連動するペースガード」を持つ:
#   目標ペース(既定 $0.10/ターン = 10ターン ≒ $1)を超えて消費している場合、
#   5ターンごとに一度ツール実行をブロックして効率化を指示する。
#   ペース超過は品質を落とす理由にはしない — 削るのは無駄(再読・過剰探索・冗長出力)。
#
# 設定(settings.json の env またはシェル環境変数):
#   CLAUDE_SESSION_BUDGET_USD       セッション上限(USD)。デフォルト 5
#   CLAUDE_SESSION_BUDGET_WARN_USD  警告閾値(USD)。デフォルトは上限の 50%
#   CLAUDE_TURN_BUDGET_USD          目標ペース(USD/ターン)。デフォルト 0.10
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

# 仕様ドリフト検知①: フック入力は来ているのに想定フィールドが読めない場合、
# Claude Code 更新によるスキーマ変更の可能性が高い。フェイルオープンで黙って
# 無効化される代わりに、1日1回だけ警告して表面化させる。
if [ -n "$input" ] && { [ -z "$event" ] || [ -z "$transcript" ]; }; then
  m="${TMPDIR:-/tmp}/claude-budget-schemawarn"
  if [ ! -f "$m" ] || [ -n "$(find "$m" -mtime +1 2>/dev/null)" ]; then
    touch "$m"
    {
      echo "予算ガードがフック入力から必要フィールド(hook_event_name / transcript_path)を読めません。"
      echo "Claude Code の更新による仕様変更の可能性があります。コスト保護は現在機能していません。"
      echo "対処: bash ~/.claude/skills/cost-audit/scripts/selftest_guard.sh で自己診断し、/cost-audit を実行。"
      echo "(この警告は1日1回のみ。作業は同じ操作の再実行で続行できます)"
    } >&2
    exit 2
  fi
  exit 0
fi
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

HARD="${CLAUDE_SESSION_BUDGET_USD:-5}"
WARN="${CLAUDE_SESSION_BUDGET_WARN_USD:-}"
if [ -z "$WARN" ]; then
  WARN=$(awk -v h="$HARD" 'BEGIN{printf "%.4f", h * 0.5}')
fi

# トランスクリプトの usage を集計して推定コスト(USD)とターン数を出す。
# 【差分解析】毎回全体を再解析すると長時間セッション(数MB)でツール呼び出し毎に
# 遅延が蓄積するため、処理済みバイト位置と累計を状態ファイルに保持し、
# 前回以降に追記された部分だけを解析する(O(増分))。
#   - 書きかけの行(末尾が改行でない)は次回に回す
#   - 状態が壊れている/ファイルが縮んだ(別セッション等)場合は最初から再計算
#   - 重複排除(message.id)はチャンク内のみ。同一メッセージのusage行が
#     チャンク境界をまたいで重複記録されるケースは実運用上ほぼ無い
# 単価は代表値(/1M tokens): opus 5/25, haiku 1/5, その他(sonnet等) 3/15。
# キャッシュ書込は入力の1.25倍、キャッシュ読出は0.1倍。
size=$(wc -c < "$transcript") || exit 0
state="${TMPDIR:-/tmp}/claude-budget-state-${session}"

prev_off=0; prev_raw=0; prev_turns=0; prev_ctx=0
if [ -f "$state" ]; then
  read -r prev_off prev_raw prev_turns prev_ctx < "$state" 2>/dev/null || true
  if ! [[ "$prev_off" =~ ^[0-9]+$ && "$prev_raw" =~ ^[0-9]+(\.[0-9]+)?$ && "$prev_turns" =~ ^[0-9]+$ ]] \
     || [ "$prev_off" -gt "$size" ]; then
    prev_off=0; prev_raw=0; prev_turns=0; prev_ctx=0
    rm -f "$state"   # 壊れた/別ファイルの状態を残さない
  fi
  [[ "${prev_ctx:-}" =~ ^[0-9]+$ ]] || prev_ctx=0
fi

raw="$prev_raw"; turns="$prev_turns"; ctx="$prev_ctx"
if [ "$size" -gt "$prev_off" ]; then
  delta=$(mktemp "${TMPDIR:-/tmp}/claude-budget-delta.XXXXXX")
  trap 'rm -f "$delta"' EXIT
  tail -c +"$((prev_off + 1))" "$transcript" > "$delta"
  proc=$(wc -c < "$delta")
  # 末尾が改行でなければ書きかけの行を除外(次回のフックで処理される)
  if [ -n "$(tail -c 1 "$delta")" ]; then
    partial=$(tail -n 1 "$delta" | wc -c)
    proc=$((proc - partial))
  fi
  if [ "$proc" -gt 0 ]; then
    head -c "$proc" "$delta" > "$delta.done"
    out=$(jq -Rrn '
      def price(m):
        if   ((m // "") | test("opus"))  then {i: 5, o: 25}
        elif ((m // "") | test("haiku")) then {i: 1, o: 5}
        else {i: 3, o: 15} end;
      [inputs | fromjson? // empty] as $L
      | ([ $L[] | select(.message.usage != null) ]
         | unique_by(.message.id // .uuid)
         | map( price(.message.model) as $p
              | (.message.usage.input_tokens // 0)                * $p.i
              + (.message.usage.cache_creation_input_tokens // 0) * $p.i * 1.25
              + (.message.usage.cache_read_input_tokens // 0)     * $p.i * 0.1
              + (.message.usage.output_tokens // 0)               * $p.o )
         | add // 0) as $raw
      | ([ $L[]
          | select(.type == "user")
          | select(.isMeta != true)
          | select(.toolUseResult == null)
          | (.message.content // empty)
          | if type == "string" then 1
            elif type == "array" then
              (if any(.[]?; (.type? // "") == "tool_result") then empty else 1 end)
            else empty end
        ] | length) as $t
      | ([ $L[] | select(.message.usage != null) ]
         | if length == 0 then -1
           else (last | .message.usage
                 | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
           end) as $ctx
      | "\($raw) \($t) \($ctx)"
    ' "$delta.done" 2>/dev/null) || out=""
    rm -f "$delta.done"
    if [ -n "$out" ]; then
      d_raw=${out%% *}; rest=${out#* }; d_turns=${rest%% *}; d_ctx=${rest##* }
      if [[ "$d_turns" =~ ^[0-9]+$ ]]; then
        raw=$(awk -v a="$prev_raw" -v b="$d_raw" 'BEGIN{printf "%.4f", a + b}')
        turns=$((prev_turns + d_turns))
        if [[ "$d_ctx" =~ ^[0-9]+$ ]]; then ctx="$d_ctx"; fi   # チャンクに usage が無ければ前回値を維持
        printf '%s %s %s %s\n' "$((prev_off + proc))" "$raw" "$turns" "$ctx" > "$state"
      fi
    fi
  fi
  rm -f "$delta"
  trap - EXIT
fi

cost=$(awk -v r="$raw" 'BEGIN{printf "%.6f", r / 1000000}')

# 仕様ドリフト検知②: セッションが十分進んでいる(200KB超)のに usage もターンも
# 一切解釈できていない場合、トランスクリプトのスキーマ変更の可能性。一度だけ警告。
if [ "$size" -gt 200000 ] && [ "${turns:-0}" -eq 0 ] && awk -v r="$raw" 'BEGIN{exit !(r + 0 == 0)}'; then
  m="${TMPDIR:-/tmp}/claude-budget-sanity-${session}"
  if [ ! -f "$m" ]; then
    touch "$m"
    {
      echo "予算ガードがこのセッションのトランスクリプトを解釈できていません(集計ゼロのまま)。"
      echo "Claude Code の更新でトランスクリプト形式が変わった可能性があり、コスト保護が無効化されています。"
      echo "対処: bash ~/.claude/skills/cost-audit/scripts/selftest_guard.sh で自己診断し、結果をユーザーに報告してください。"
      echo "(この警告はセッション毎に1回のみ。作業は同じ操作の再実行で続行できます)"
    } >&2
    exit 2
  fi
fi

over_hard=$(awk -v c="$cost" -v h="$HARD" 'BEGIN{print (c >= h) ? 1 : 0}')
over_warn=$(awk -v c="$cost" -v w="$WARN" 'BEGIN{print (c >= w) ? 1 : 0}')
cost_fmt=$(awk -v c="$cost" 'BEGIN{printf "%.2f", c}')

if [ "$over_hard" = "1" ]; then
  if [ "$event" = "UserPromptSubmit" ]; then
    # ユーザー向けメッセージ(exit 2 の stderr はユーザーに表示される)
    {
      echo "🛑 セッション予算超過: 推定 \$${cost_fmt} / 上限 \$${HARD}"
      echo "   このセッションでの続行はブロックされています。/clear で新しいセッションを開始してください。"
      echo "   引き継ぎメモが .claude/handoff.md に保存されていれば、新セッションが自動で検知し再開できます。"
      echo "   上限の変更: settings.json の env CLAUDE_SESSION_BUDGET_USD"
    } >&2
    exit 2
  fi

  # グレースレーン: 上限超過中でも「引き継ぎメモの保存」だけは許可する。
  # これがないと状態を書き残す手段ごとブロックされ、作業が失われる。
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  fpath=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
  case "$tool" in
    Write|Edit)
      case "$fpath" in
        */.claude/handoff.md|.claude/handoff.md) exit 0 ;;
      esac
      ;;
  esac

  # Claude 向けメッセージ(引き継ぎメモを書かせてから終了させる)
  {
    echo "セッション予算超過(推定 \$${cost_fmt} / 上限 \$${HARD})。これ以降のツール実行はブロックされます。"
    echo "ただし例外として .claude/handoff.md への Write/Edit だけは許可されています。次の順で終了処理をしてください:"
    echo " 1. .claude/handoff.md に引き継ぎメモを書く(40行以内): 目的 / 完了済み / 未完了と次の一手 / 重要な決定・注意点"
    echo " 2. ここまでの結果を簡潔に要約する"
    echo " 3. 「/clear 後の新セッションで handoff.md から再開できる」ことをユーザーに案内する"
  } >&2
  exit 2
fi

# ---- ペースガード(10ターン ≒ $1 目標) --------------------------------------
# ターン数(=ユーザーの実プロンプト数。ツール結果・メタ行は除外)は上の差分解析で累計済み。
TURNB="${CLAUDE_TURN_BUDGET_USD:-0.10}"

# 立ち上がりのノイズを避けるため3ターン目から判定。許容額 = (ターン数+1) × ペース
if [ "$event" = "PreToolUse" ] && [ "${turns:-0}" -ge 3 ]; then
  allowed=$(awk -v t="$turns" -v b="$TURNB" 'BEGIN{printf "%.4f", (t + 1) * b}')
  over_pace=$(awk -v c="$cost" -v a="$allowed" 'BEGIN{print (c > a) ? 1 : 0}')
  if [ "$over_pace" = "1" ]; then
    pmarker="${TMPDIR:-/tmp}/claude-budget-pace-${session}"
    last=$(cat "$pmarker" 2>/dev/null || echo "-999")
    if [ $(( turns - last )) -ge 5 ]; then
      printf '%s' "$turns" > "$pmarker"
      pace10=$(awk -v c="$cost" -v t="$turns" 'BEGIN{printf "%.2f", c / t * 10}')
      target10=$(awk -v b="$TURNB" 'BEGIN{printf "%.2f", b * 10}')
      {
        echo "ペース超過: ここまで ${turns} ターンで推定 \$${cost_fmt}(10ターン換算 \$${pace10}、目標 \$${target10})。"
        echo "品質を落とすのではなく、無駄を削って目標ペースに戻すこと:"
        echo " - 既に読んだファイル・確認済みの事実を再取得しない"
        echo " - 横断的な探索・調査は explore サブエージェントに委譲する"
        echo " - 出力は結論と変更箇所のみ。ファイル全文や長い引用の再掲をしない"
        echo " - 同じ検証やビルドを不必要に繰り返さない"
        echo " - 現在のタスクに不要な文脈が多いなら、ユーザーに /compact を提案する"
        echo "この指示を反映したら、同じツール呼び出しを再実行して作業を続行してください。タスクの完遂が最優先であることは変わらない。"
      } >&2
      exit 2
    fi
  fi
fi
# -----------------------------------------------------------------------------

# ---- コンテキスト肥大ガード ---------------------------------------------------
# ユーザーが /clear を意識しなくても、膨張の早期段階で自動介入する。
# ctx(直近リクエストの入力サイズ)が閾値を超えたら、セッション1回だけブロックして
# 「以後の読み込み禁止・explore 委譲・handoff 更新・/clear 提案」を指示する。
# (/clear 自体は Claude Code の仕様上ユーザー操作が必要 — ここまで準備すれば
#  ユーザーの仕事は提案に1回応じるだけになる)
CTXLIM="${CLAUDE_CTX_LIMIT_TOKENS:-120000}"
if [ "$event" = "PreToolUse" ] && [ "${ctx:-0}" -gt "$CTXLIM" ]; then
  cmarker="${TMPDIR:-/tmp}/claude-budget-ctx-${session}"
  if [ ! -f "$cmarker" ]; then
    touch "$cmarker"
    ctxk=$(awk -v x="$ctx" 'BEGIN{printf "%.0f", x / 1000}')
    limk=$(awk -v x="$CTXLIM" 'BEGIN{printf "%.0f", x / 1000}')
    {
      echo "コンテキスト肥大警告: 現在 約${ctxk}k トークン(閾値 ${limk}k)。この文脈は毎リクエスト再送され続けます。"
      echo "これ以降は次を厳守してください:"
      echo " - 新たなファイル・ログ・Web結果をメイン文脈に読み込まない。読取・調査が必要なら explore サブエージェントに委譲し、結論だけ受け取る"
      echo " - いま扱っているタスクの区切りで .claude/handoff.md を更新し、ユーザーに次を提案する:"
      echo "   「コンテキストが肥大しているため /clear を推奨します。引き継ぎメモは保存済みで、新しいセッションが自動検知して続きから再開できます」"
      echo "この警告はセッション1回のみです。同じツール呼び出しを再実行して作業を続行してください。"
    } >&2
    exit 2
  fi
fi
# -----------------------------------------------------------------------------

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
      echo " - 上限(\$${HARD})に達すると強制終了されるため、作業の区切りで .claude/handoff.md に未完了事項を書き残しておく"
      echo "この警告は一度だけです。同じツール呼び出しを再実行して続行してください。"
    } >&2
    exit 2
  fi
fi

exit 0
