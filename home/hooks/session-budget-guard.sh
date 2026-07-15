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
#   CLAUDE_TURN_HARD_LIMIT          ターン数上限(コストと独立の第2軸)。0/未設定で無効
#   CLAUDE_TURN_WARN_TURNS          ターン警告閾値。デフォルトは上限-2
#
# 制約(README/docs 参照):
#   - 進行中の1リクエストは止められない(検知は次のフック発火時点)
#   - 推定単価は代表値。実際の請求額とは誤差がある
set -euo pipefail
# 小数点がカンマになるロケール(de_DE 等)では awk/printf の小数出力・解析が壊れ、
# 状態ファイルが数値検証に落ちて毎回フル再解析になるため、数値書式をCに固定する。
export LC_NUMERIC=C

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
# 単価は代表値(/1M tokens): fable/mythos 10/50, opus 5/25, haiku 1/5, その他(sonnet等) 3/15。
# キャッシュ書込は入力の1.25倍(5分TTLの係数。1時間TTLでは2倍のため控えめな見積り)、読出は0.1倍。
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
        if   ((m // "") | test("fable|mythos")) then {i: 10, o: 50}
        elif ((m // "") | test("opus"))  then {i: 5, o: 25}
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
          | select(.isSidechain != true)      # サブエージェント内部の user ターンを除外
          | select(.isCompactSummary != true) # /compact・継続サマリの合成 user を除外
          | select(.toolUseResult == null)
          | (.message.content // empty)
          # 文字列内容でも、スラッシュコマンドの足場(<command-*>)とその標準出力
          # (<local-command-*>)、継続サマリ本文は「ユーザーの実プロンプト」ではない。
          # これらを数えると 1操作=command+stdout の2重計上になる(ターン数が倍増する主因)。
          | if type == "string" then
              (if test("^<command-|^<local-command|^This session is being continued") then empty else 1 end)
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

# ---- 1日の合計コスト累積(セッション横断・/clear やセッション終了でズレない)-------
# 設計: セッション別の「当日寄与」を単調増加で積む。日次合計は当日の全セッション
# 寄与ファイルの総和(statusline が表示)。共有ファイルへの競合書き込みを避けるため、
# 各セッションは自分の寄与ファイルだけを更新する。
#   - /clear でセッションコストが 0 に戻っても、delta=max(0, 現在-前回) が 0 になる
#     だけで、既に積んだ当日寄与は減らない(過去分を保持)。
#   - 日跨ぎ・resume(--continue)・新規セッションの初回は「再ベースライン」して
#     過去日の累積を当日へ二重計上しない(ズレ防止を最優先。初回の微少分のみ切り捨て)。
# 保存先は永続(TMPDIR ではなく CLAUDE_CONFIG_DIR。セッション終了後も残す)。
# コストが 0 でも base は毎回更新する。そうしないと /clear 直後(コスト≈0)に base が
# 下落前の高い値のまま残り、次の積み増しが「まだ下落中」扱いで取りこぼされる。
if [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  ddir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cost-daily"
  if mkdir -p "$ddir" 2>/dev/null; then
    today=$(date +%Y%m%d)
    basef="$ddir/session-${session}.base"      # "前回コスト 前回日付"
    sumf="$ddir/${today}-${session}.sum"        # 当日このセッションの寄与(単調増加)
    # 基準値 base_lc の決め方(過去日の二重計上を防ぎつつ、新規セッションの初回分は取りこぼさない):
    #   - base ファイルなし(このセッション初出) → 基準 0(初回コストを全額計上)
    #   - 同日の記録あり → 前回コストが基準(増分のみ加算)
    #   - 別日の記録あり(日跨ぎ/resume) → 基準を現在コストに置き、当日は増分のみ計上
    #     (前日までに積んだ分を当日へ持ち込まない)
    if [ -f "$basef" ]; then
      read -r b_cost b_date < "$basef" 2>/dev/null || { b_cost=0; b_date="none"; }
      [[ "$b_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] || b_cost=0
      if [ "$b_date" = "$today" ]; then base_lc="$b_cost"; else base_lc="$cost"; fi
    else
      base_lc=0
    fi
    # /clear・/compact でコストが基準を下回ったら delta は 0(既に積んだ当日寄与は減らさない)
    d_add=$(awk -v c="$cost" -v p="$base_lc" 'BEGIN{d=c-p; printf "%.6f", (d>0)?d:0}')
    if awk -v d="$d_add" 'BEGIN{exit !(d + 0 > 0)}'; then
      cur=0; [ -f "$sumf" ] && { read -r cur < "$sumf" 2>/dev/null || cur=0; [[ "$cur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || cur=0; }
      awk -v a="$cur" -v b="$d_add" 'BEGIN{printf "%.6f\n", a + b}' > "$sumf"
    fi
    printf '%s %s\n' "$cost" "$today" > "$basef"
  fi
fi
# -----------------------------------------------------------------------------

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

# グレースレーン判定: 上限超過中でも「引き継ぎメモの保存」だけは許可する。
# これがないと状態を書き残す手段ごとブロックされ、作業が失われる。
is_handoff_write() {
  local tool fpath
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  case "$tool" in Write|Edit) ;; *) return 1 ;; esac
  fpath=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
  case "$fpath" in
    */.claude/handoff.md|.claude/handoff.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Claude 向けの終了手順(ハード上限到達時に共通)
block_with_wrapup() { # $1 = 超過理由の1行
  {
    echo "$1 これ以降のツール実行はブロックされます。"
    echo "ただし例外として .claude/handoff.md への Write/Edit だけは許可されています。次の順で終了処理をしてください:"
    echo " 1. .claude/handoff.md に引き継ぎメモを書く(40行以内): 「# handoff: 一行要約」+ 目的 / 完了済み / 再開手順(コマンド・パス付き) / 重要な決定・注意点"
    echo " 2. ここまでの結果を簡潔に要約する"
    echo " 3. 「/clear 後の新セッションで handoff.md から再開できる」ことをユーザーに案内する"
  } >&2
  exit 2
}

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
  is_handoff_write && exit 0
  block_with_wrapup "セッション予算超過(推定 \$${cost_fmt} / 上限 \$${HARD})。"
fi

# ---- ターン数ガード(コストと独立した第2の上限軸) ----------------------------
# 「コスト上限 OR ターン数上限」のどちらか早く達した方でブロックする。
#   CLAUDE_TURN_HARD_LIMIT  上限ターン数(0 または未設定で無効)。
#     上限までのターン(1..N)は完走でき、N+1 ターン目のプロンプトと
#     それ以降のツール実行がブロックされる。グレースレーンは予算ガードと共通。
#   CLAUDE_TURN_WARN_TURNS  警告ターン(既定: 上限-2)。PreToolUse で一度だけ
#     「残りターンで畳む」指示を注入する(急停止の防止)。
TLIM="${CLAUDE_TURN_HARD_LIMIT:-0}"
if [[ "$TLIM" =~ ^[0-9]+$ ]] && [ "$TLIM" -gt 0 ]; then
  if [ "$event" = "UserPromptSubmit" ] && [ "${turns:-0}" -ge "$TLIM" ]; then
    {
      echo "🛑 ターン上限到達: このセッションは ${turns} ターン(上限 ${TLIM})に達しました。"
      echo "   このセッションでの続行はブロックされています。/clear で新しいセッションを開始してください。"
      echo "   引き継ぎメモが .claude/handoff.md に保存されていれば、新セッションが自動で検知し再開できます。"
      echo "   上限の変更: settings.json の env CLAUDE_TURN_HARD_LIMIT(0 で無効化)"
    } >&2
    exit 2
  fi
  if [ "$event" = "PreToolUse" ] && [ "${turns:-0}" -gt "$TLIM" ]; then
    is_handoff_write && exit 0
    block_with_wrapup "ターン上限超過(${turns} ターン / 上限 ${TLIM})。"
  fi
  # 上限接近の警告(セッション1回のみ)
  TWARN="${CLAUDE_TURN_WARN_TURNS:-$((TLIM - 2))}"
  if [ "$event" = "PreToolUse" ] && [ "$TWARN" -gt 0 ] \
     && [ "${turns:-0}" -ge "$TWARN" ] && [ "${turns:-0}" -le "$TLIM" ]; then
    tmarker="${TMPDIR:-/tmp}/claude-budget-turnwarn-${session}"
    if [ ! -f "$tmarker" ]; then
      touch "$tmarker"
      {
        echo "ターン上限接近: 現在 ${turns} ターン(上限 ${TLIM}。超過すると全ツール実行がブロックされます)。"
        echo "残りターンで作業を畳んでください:"
        echo " - 未完了事項を洗い出し、残りターンで終えられる最小範囲に絞る"
        echo " - 区切りで .claude/handoff.md に引き継ぎメモを更新する(上限到達後も handoff.md への書き込みだけは許可される)"
        echo " - 続きが必要なら「/clear 後の新セッションで handoff.md から再開できる」ことをユーザーに案内する"
        echo "この警告はセッション1回のみです。同じツール呼び出しを再実行して作業を続行してください。"
      } >&2
      exit 2
    fi
  fi
fi
# -----------------------------------------------------------------------------

# ---- ペースガード(10ターン ≒ $1 目標) --------------------------------------
# ターン数(=ユーザーの実プロンプト数。ツール結果・メタ・sidechain・コマンド足場や
# その標準出力・継続サマリは除外)は上の差分解析で累計済み。
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
      # 現在(直近)のモデルを決定論的に取得。高価モデル(opus/fable/mythos)で
      # ペース超過しているなら、モデル/effort 引き下げが最大の削減レバーになりうる
      # ため案内する。判定はトランスクリプトの実測値で、モデルの自己識別に依存しない。
      # 発火は5ターンに1回に絞られているため、この tail+jq の追加コストは無視できる。
      lastmodel=$(tail -c 200000 "$transcript" 2>/dev/null \
        | jq -Rrn '[inputs|fromjson? // empty|select(.message.model!=null)|.message.model]|last // empty' 2>/dev/null || true)
      {
        echo "ペース超過: ここまで ${turns} ターンで推定 \$${cost_fmt}(10ターン換算 \$${pace10}、目標 \$${target10})。"
        echo "品質を落とすのではなく、無駄を削って目標ペースに戻すこと:"
        echo " - 既に読んだファイル・確認済みの事実を再取得しない"
        echo " - 横断的な探索・調査は explore サブエージェントに委譲する"
        echo " - 出力は結論と変更箇所のみ。ファイル全文や長い引用の再掲をしない"
        echo " - 同じ検証やビルドを不必要に繰り返さない"
        echo " - 現在のタスクに不要な文脈が多いなら、ユーザーに /compact を提案する"
        case "$lastmodel" in
          *opus*|*fable*|*mythos*)
            echo " - 現在は高価なモデル(${lastmodel})です。いまの作業が難所(設計判断・数回試して解けない類)でないなら、モデル/effort の引き下げが最大の削減レバー。ユーザーに「/model sonnet(必要なら効いていれば /effort を下げる)で十分そうです」と一度だけ提案してよい。難所ならこのまま維持する。" ;;
        esac
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
