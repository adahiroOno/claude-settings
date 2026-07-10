#!/usr/bin/env bash
# PreToolUse フック(Bash): ロックファイル・生成物の全文読み込みをブロックする。
# permissions.deny は Read ツールにしか効かないため、`cat package-lock.json` のような
# Bash 経由の読み込みをここで塞ぐ。exit 2 でツール呼び出しをブロックし、stderr の
# メッセージが Claude にフィードバックされて代替手段(rg/jq での部分抽出)に誘導される。
set -euo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

heavy='(package-lock\.json|pnpm-lock\.yaml|[^ /]*\.lock|go\.sum|node_modules/|\.venv/|__pycache__/|\.terraform/|/dist/|/build/|\.min\.(js|css)|\.map)'
reader='^[[:space:]]*(cat|head|tail|less|more|bat)[[:space:]]'

if printf '%s' "$cmd" | grep -Eq "$reader" && printf '%s' "$cmd" | grep -Eq "$heavy"; then
  # パイプで加工している場合(cat x | jq .version 等)は部分抽出とみなして許可
  if ! printf '%s' "$cmd" | grep -q '|'; then
    echo "コスト保護: ロックファイル/生成物の全文読み込みはブロックしました。必要な情報は rg / jq / grep で部分抽出してください。" >&2
    exit 2
  fi
fi

exit 0
