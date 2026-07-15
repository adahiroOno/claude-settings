#!/usr/bin/env bash
# SessionStart フック: /clear 後・新セッション開始時の作業再開を最小トークンで実現する。
#
# 仕組み:
#   - 引き継ぎメモ(.claude/handoff.md)が48時間以内に存在する場合、その本文を
#     そのままコンテキストに注入する(既定 full。上限3000バイト≒40行の全文)。
#     → モデルが handoff を Read しに行く往復が不要になり、1ターン目から
#       全情報を持って再開できる(再開のターン・ツール呼び出し消費をゼロに)。
#   - handoff は再開完了時に削除される一時ファイルなので、注入は実質
#     「再開が必要なセッションの先頭に1回」だけ。CLAUDE.md 常駐(毎リクエスト
#     ×全セッション)とはコスト構造が根本的に違う。
#   - 探索は cwd → git ルートの順(サブディレクトリで起動しても見つかる)。
#   - CLAUDE_HANDOFF_NOTICE=min で従来の「存在通知3行」(約110トークン)に戻せる。
#
# ついでに、予算ガードが /tmp に残す警告マーカーの古いものを掃除する。
set -u

input=$(cat 2>/dev/null || true)

# 古い警告マーカーの掃除(2日以上前のもの)
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'claude-budget-*' -mtime +2 -delete 2>/dev/null || true
# 1日合計コストの古いファイル(当日以外)も掃除。2日超の寄与ファイルとベースラインを削除
find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cost-daily" -maxdepth 1 -type f -mtime +2 -delete 2>/dev/null || true

# 仕様ドリフト検知③: Claude Code 本体の更新を検知したら再監査を促す
# (実行ファイルのフィンガープリント比較。stat のみ、コストゼロ)
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
bin=$(command -v claude 2>/dev/null || true)
if [ -n "$bin" ]; then
  real=$(readlink -f "$bin" 2>/dev/null || echo "$bin")
  fp=$(stat -c '%s %Y' "$real" 2>/dev/null || stat -f '%z %m' "$real" 2>/dev/null || true)
  vf="$cfg/.claude-code-fingerprint"
  if [ -n "$fp" ]; then
    old=$(cat "$vf" 2>/dev/null || true)
    if [ -z "$old" ]; then
      printf '%s' "$fp" > "$vf" 2>/dev/null || true
    elif [ "$old" != "$fp" ]; then
      printf '%s' "$fp" > "$vf" 2>/dev/null || true
      echo "Claude Code 本体が更新されています。仕様変更でコスト管理設定(フック・監査)の前提が変わっている可能性があります。区切りの良いところで selftest_guard.sh による自己診断と /cost-audit の実行をユーザーに提案してください。"
    fi
  fi
fi

cwd=""
if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"

# handoff の探索: cwd → git ルート(サブディレクトリからの起動でも迷子にならない)。
# 共有の handoff.md と、セッション別スタブ handoff-*.md のうち **最新** を選ぶ
# (複数セッションが並行してもバトンが衝突・消失しない)。
# newest_handoff <dir> : そのディレクトリ内の handoff*.md で最新の1つを返す(なければ空)
newest_handoff() {
  local d="$1"
  [ -d "$d" ] || return 0
  # mtime 降順で先頭。ls -t は handoff.md と handoff-*.md を一緒に並べる
  ls -t "$d"/handoff.md "$d"/handoff-*.md 2>/dev/null | head -1
}
handoff=$(newest_handoff "$cwd/.claude")
if [ -z "$handoff" ] && command -v git >/dev/null 2>&1; then
  root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$root" ] && [ "$root" != "$cwd" ]; then
    handoff=$(newest_handoff "$root/.claude")
  fi
fi
[ -n "$handoff" ] && [ -f "$handoff" ] || exit 0

# 48時間より古いメモは案内しない(陳腐化したメモの誤再開を防ぐ)
if ! find "$handoff" -mtime -2 2>/dev/null | grep -q .; then
  exit 0
fi

# SessionStart フックの stdout はコンテキストに追加される
if [ "${CLAUDE_HANDOFF_NOTICE:-full}" = "min" ]; then
  cat <<EOF
前回セッションからの引き継ぎメモが $handoff にあります(未完了作業の再開用)。
- ユーザーの依頼がその続きに関係する場合のみ読み込んで再開すること。無関係なタスクなら読み込まない。
- 引き継いだ作業が完了したら $handoff を削除すること。
EOF
else
  echo "前回セッションからの引き継ぎメモ(${handoff}):"
  echo '--- handoff ここから ---'
  head -c 3000 "$handoff"
  echo ""
  echo '--- handoff ここまで ---'
  echo "ユーザーの依頼がこの続きに関係する場合は、上記の内容だけで直ちに再開すること(このファイルを改めて Read しない)。無関係な依頼なら一切言及せず無視してよい。引き継いだ作業が完了したら $handoff を削除すること。"
fi
exit 0
