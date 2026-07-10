#!/usr/bin/env bash
# SessionStart フック: /clear 後・新セッション開始時の作業再開を最小トークンで実現する。
#
# 仕組み(progressive disclosure):
#   - 引き継ぎメモ(.claude/handoff.md)が存在する場合、その「存在を知らせる数行」
#     だけをコンテキストに注入する(約60トークン、ファイル存在時のみ)。
#   - 本文はユーザーの依頼が続きの作業だった場合にのみ Read される。
#   - 常駐メモリ(CLAUDE.md への自動追記等)と違い、毎リクエストの固定費にならない。
#
# ついでに、予算ガードが /tmp に残す警告マーカーの古いものを掃除する。
set -u

input=$(cat 2>/dev/null || true)

# 古い警告マーカーの掃除(2日以上前のもの)
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'claude-budget-*' -mtime +2 -delete 2>/dev/null || true

cwd=""
if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"

handoff="$cwd/.claude/handoff.md"
[ -f "$handoff" ] || exit 0

# 48時間より古いメモは案内しない(陳腐化したメモの誤再開を防ぐ)
if ! find "$handoff" -mtime -2 2>/dev/null | grep -q .; then
  exit 0
fi

# SessionStart フックの stdout はコンテキストに追加される
cat <<'EOF'
前回セッションからの引き継ぎメモが .claude/handoff.md にあります(未完了作業の再開用)。
- ユーザーの依頼がその続きに関係する場合のみ読み込んで再開すること。無関係なタスクなら読み込まない。
- 引き継いだ作業が完了したら .claude/handoff.md を削除すること。
EOF
exit 0
