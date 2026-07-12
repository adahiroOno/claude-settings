#!/usr/bin/env bash
# バックグラウンドでトークンを消費しうるものの検出(読み取り専用・モデル呼び出しなし)
#
# 検出対象:
#   1. 実行中の claude プロセス(放置セッション・多重起動・ヘッドレス実行)
#   2. cron / systemd タイマー / launchd からの自動起動
#   3. フックやスクリプト内からのモデル呼び出し(claude -p 等。イベント毎に課金される)
# 使い方: bash scan_background.sh [プロジェクトルート...]
set -u

found=0
section() { echo ""; echo "== $1 =="; }
# hit は表示のみ。found の加算は各セクションで行う
# (パイプ先の while はサブシェルで動き、内部での加算は失われるため)
hit() { printf '  ⚠ %s\n' "$1"; }
none() { printf '  なし\n'; }

section "1. 実行中の claude プロセス"
procs=$(ps -eo pid,etime,args 2>/dev/null | grep -E '[c]laude([[:space:]]|$)' | grep -vE 'scan_background|grep' | cut -c1-160 || true)
if [ -n "$procs" ]; then
  echo "$procs" | while IFS= read -r line; do hit "$line"; done
  echo "  → 見覚えのないもの・長時間(etime)放置されたものは kill する。"
  echo "    対話セッションの放置はプロンプト待ちなら消費しないが、"
  echo "    ヘッドレス(-p/--print)や自動リトライ中のものは消費し続ける可能性がある。"
  found=$((found + 1))
else
  none
fi

section "2. cron / タイマーからの自動起動"
c=$(crontab -l 2>/dev/null | grep -iE 'claude|anthropic' || true)
[ -n "$c" ] && { echo "$c" | while IFS= read -r l; do hit "crontab: $l"; done; found=$((found + 1)); } || echo "  crontab: なし"
if command -v systemctl >/dev/null 2>&1; then
  t=$(systemctl --user list-units --type=service,timer 2>/dev/null | grep -iE 'claude|anthropic' || true)
  [ -n "$t" ] && { echo "$t" | while IFS= read -r l; do hit "systemd: $l"; done; found=$((found + 1)); } || echo "  systemd(user): なし"
fi
if command -v launchctl >/dev/null 2>&1; then
  l=$(launchctl list 2>/dev/null | grep -iE 'claude|anthropic' | grep -vi 'com.anthropic.claude$' || true)
  [ -n "$l" ] && { echo "$l" | while IFS= read -r x; do hit "launchd: $x"; done; found=$((found + 1)); } || echo "  launchd: なし"
fi

section "3. フック・スクリプト内からのモデル呼び出し"
echo "  (フックから claude -p を呼ぶと、そのイベントが起きる度にモデル課金が発生する)"
echo "  ※テストコードやドキュメント内の文字列は誤検知。実際に実行される経路かで判断すること。"
scan_dirs=("$HOME/.claude" "$@")
pat='claude[[:space:]]+(-p|--print|--continue|-c)([[:space:]]|$)'
hits=$(grep -rnE "$pat" "${scan_dirs[@]}" 2>/dev/null \
       | grep -vE '/(backup-[0-9-]+|projects|todos|statsig|shell-snapshots)/' \
       | grep -v 'scan_background.sh' || true)
if [ -n "$hits" ]; then
  echo "$hits" | while IFS= read -r h; do hit "$h"; done
  echo "  → 本当に毎イベントのモデル呼び出しが必要か確認。決定論的スクリプト(jq/grep)で"
  echo "    代替できるなら置き換える。必要なら呼び出しモデルを haiku 系にする。"
  found=$((found + 1))
else
  none
fi

section "4. settings 内のフック定義に埋め込まれたコマンド"
s4=0
for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" .claude/settings.json .claude/settings.local.json; do
  [ -f "$f" ] || continue
  if command -v jq >/dev/null 2>&1; then
    cmds=$(jq -r '.hooks // {} | to_entries[] | .value[]?.hooks[]?.command // empty' "$f" 2>/dev/null | grep -E "$pat" || true)
    if [ -n "$cmds" ]; then
      s4=1
      echo "$cmds" | while IFS= read -r c2; do hit "$f: $c2"; done
      found=$((found + 1))
    fi
  fi
done
[ "$s4" -eq 0 ] && none

echo ""
if [ "$found" -eq 0 ]; then
  echo "結果: バックグラウンドのトークン消費源は検出されませんでした。"
else
  echo "結果: ${found} 件の要確認項目。上記の → の指示に従って対処してください。"
fi
