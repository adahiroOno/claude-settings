#!/usr/bin/env bash
# SessionEnd フック(matcher: clear): /clear 時に引き継ぎスタブを自動生成する。
#
# 制約(公式仕様): SessionEnd はモデルを呼べず、既定タイムアウト1.5秒。
# したがってモデル品質の要約は書けない。代わりに決定論的な「スタブ」を書く:
#   日時 / 作業ディレクトリ / gitブランチ / 直近のユーザープロンプト(最大5件)/
#   元トランスクリプトのパス(ディスクに残るため、詳細は必要時に部分検索で復元可能)
#
# 設計判断:
#   - モデル(claude -p)をここから呼ぶのは反パターン(G-3): /clear の度に課金され、
#     1.5秒制限でタイムアウトする。決定論的スタブ+ポインタ方式が正解。
#   - Claude が書いた新鮮な handoff.md(48時間以内)があれば上書きしない。
#   - $cwd/.claude ディレクトリが存在するプロジェクトのみ対象(無関係な
#     ディレクトリに .claude/ を作って汚染しない)。
#   - 無効化: CLAUDE_HANDOFF_AUTOSTUB=0
set -u
export LC_NUMERIC=C

[ "${CLAUDE_HANDOFF_AUTOSTUB:-1}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

reason=$(printf '%s' "$input" | jq -r '.reason // empty')
[ "$reason" = "clear" ] || exit 0   # matcher と二重の防御

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -n "$cwd" ] && [ -d "$cwd/.claude" ] || exit 0

handoff="$cwd/.claude/handoff.md"
# Claude が書いた新鮮な handoff があれば尊重して触らない
if [ -f "$handoff" ] && find "$handoff" -mtime -2 2>/dev/null | grep -q .; then
  exit 0
fi

branch=""
command -v git >/dev/null 2>&1 && branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)

prompts=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # 末尾512KBだけ読む(1.5秒制限内で確実に終わらせる)。ユーザーの実プロンプトの直近5件。
  prompts=$(tail -c 524288 "$transcript" 2>/dev/null | jq -Rr '
    fromjson? // empty
    | select(.type == "user") | select(.isMeta != true) | select(.toolUseResult == null)
    | .message.content
    | if type == "string" then . else empty end
    | gsub("[\\n\\r]"; " ") | .[0:160]' 2>/dev/null | tail -n 5 | sed 's/^/- /')
fi

{
  echo "# handoff(自動生成スタブ)"
  echo ""
  echo "- 生成: $(date '+%Y-%m-%d %H:%M') / clear 時に自動保存(モデル未関与)"
  echo "- ディレクトリ: $cwd"
  [ -n "$branch" ] && echo "- ブランチ: $branch"
  echo ""
  echo "## 直近の依頼(新しいものが下)"
  if [ -n "$prompts" ]; then echo "$prompts"; else echo "- (取得できず)"; fi
  echo ""
  echo "## 完全な文脈の復元"
  echo "- 元トランスクリプト: $transcript"
  echo "- 上記の依頼内容で足りない場合のみ、このファイルを rg / jq で**部分検索**して"
  echo "  必要箇所だけ読み込むこと(全文読み込みはしない)。"
  echo ""
  echo "(このスタブは再開完了後に削除すること)"
} > "$handoff" 2>/dev/null || true

exit 0
