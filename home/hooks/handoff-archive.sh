#!/usr/bin/env bash
# handoff を .claude/notes/ に日時付きで退避する(履歴の保存・並行タスクの記録)。
#
# 使い方:
#   handoff-archive.sh [cwd]        # 既定は $PWD。<cwd>/.claude/handoff.md を退避
#
# 設計:
#   - ファイル名 YYYYMMDD-HHMM-<タイトルslug>.md が「索引」そのもの。
#     `ls -t .claude/notes/` で日時+主題が一覧でき、常駐トークンはゼロ
#     (memory に索引を常駐させる案との決定的な差)。
#   - 中身は既存の handoff をそのまま退避するだけ(モデル未関与=コストゼロ)。
#   - 再開作業の完了時、モデルは「削除」の代わりにこれを呼ぶ(アーカイブ運用時)。
#     並行タスクを一旦横に置くときにも使える(handoff.md は再開スロット、
#     notes/ は参照用の履歴、という役割分担)。
set -u
# 多バイト(日本語)タイトルを保持しつつ文字単位で切り詰めるため UTF-8 を確保
if locale -a 2>/dev/null | grep -qi '^C\.utf-\?8$'; then export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-\?8$'; then export LC_ALL=en_US.UTF-8; fi

cwd="${1:-$PWD}"
src="$cwd/.claude/handoff.md"
[ -f "$src" ] || { echo "handoff.md がありません: $src" >&2; exit 0; }

notes="$cwd/.claude/notes"
mkdir -p "$notes" 2>/dev/null || { echo "notes ディレクトリを作成できません: $notes" >&2; exit 1; }

# タイトル行「# handoff: <要約>」から slug を作る。パス破壊文字・空白のみ '-' に置換し、
# 日本語などの多バイト文字は保持する(ファイル名として有効)。
raw_title=$(head -1 "$src" 2>/dev/null | sed 's/^#*[[:space:]]*handoff:*[[:space:]]*//')
[ -n "$raw_title" ] || raw_title="note"
slug=$(printf '%s' "$raw_title" \
  | sed 's#[/\\:*?"<>|]#-#g; s/[[:space:]]\{1,\}/-/g' \
  | cut -c1-40 \
  | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//')
[ -n "$slug" ] || slug="note"

ts=$(date +%Y%m%d-%H%M)
dest="$notes/$ts-$slug.md"
i=2
while [ -e "$dest" ]; do dest="$notes/$ts-$slug-$i.md"; i=$((i+1)); done

if mv "$src" "$dest" 2>/dev/null; then
  echo "アーカイブしました: $dest"
else
  echo "アーカイブに失敗しました(handoff.md は残っています): $src" >&2
  exit 1
fi
