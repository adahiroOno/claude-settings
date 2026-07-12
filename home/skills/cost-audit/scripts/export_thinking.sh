#!/usr/bin/env bash
# thinking(拡張思考=判断根拠)ブロックをトランスクリプトから抽出してMarkdown化する。
#
# 重要な前提(誤解しやすい点):
#   - thinking は生成された時点で出力トークンとして課金される。これは display 設定に
#     関わらず発生する不可避のコスト。このスクリプトは既に発生済みのコストを
#     「後からアーカイブする」だけであり、コストを削減するものではない。
#   - ただし、このスクリプト自体はモデルを一切呼び出さない(jq のみ)ため、
#     アーカイブ作業自体の追加コストはゼロ。
#   - thinking.display が既定の "omitted" の場合、API はブロックの中身を空文字列で
#     返す(課金はされるが内容は取得不可)。中身を残したい場合は "summarized" が
#     必要(可視性の設定であり、summarized にしてもコストは増えない)。
#
# 使い方: bash export_thinking.sh [transcript.jsonl] [出力先.md]
#   引数省略時は最新のトランスクリプトを自動検出し、標準出力に書く。
set -u

TR="${1:-}"
if [ -z "$TR" ]; then
  TR=$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/*.jsonl 2>/dev/null | head -1)
fi
[ -n "$TR" ] && [ -f "$TR" ] || { echo "エラー: トランスクリプトが見つかりません" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "エラー: jq が必要です" >&2; exit 1; }

OUT="${2:-}"

body=$(jq -Rrn '
  [inputs | fromjson? // empty
    | select(.type == "assistant")
    | select(.message.content != null)
    | {ts: .timestamp, blocks: [.message.content[]? | select(.type == "thinking")]}
    | select(.blocks | length > 0)
  ] as $entries
  | if ($entries | length) == 0 then
      "(このトランスクリプトに thinking ブロックはありません)"
    else
      ($entries | map(
          .ts as $ts
          | (.blocks | map(.thinking // "") | join("\n\n")) as $text
          | if ($text | length) == 0 then
              "## \($ts)\n\n_(空 — thinking.display が \"omitted\" のため中身は取得できません。生成コストは発生しています。summarized にすると内容が残ります)_\n"
            else
              "## \($ts)\n\n\($text)\n"
            end
        ) | join("\n"))
    end
' "$TR" 2>/dev/null) || { echo "エラー: 解析に失敗しました" >&2; exit 1; }

header="# thinking アーカイブ
抽出元: \`$TR\`
抽出日時: $(date '+%Y-%m-%d %H:%M:%S')

このファイルはトランスクリプトからの抽出のみで生成されており、モデル呼び出しは発生していません
(このアーカイブ作業自体のコストはゼロ)。thinking の生成コスト自体は元のセッションで既に発生済みです。

---
"

if [ -n "$OUT" ]; then
  { printf '%s\n' "$header"; printf '%s\n' "$body"; } > "$OUT"
  echo "書き出しました: $OUT"
else
  printf '%s\n' "$header"
  printf '%s\n' "$body"
fi
