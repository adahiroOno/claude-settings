#!/usr/bin/env bash
# 予算ガードの自己診断(カナリア)
#
# Claude Code の更新で仕様(フック入力・トランスクリプト形式)が変わると、
# ガードはフェイルオープン設計のため静かに無効化されうる。このスクリプトは
#   1. 既知の合成データでコスト集計が期待値と一致するか
#   2. 上限ブロックが実際に作動するか
#   3. 実環境のトランスクリプトを現行ロジックで解釈できるか(ドリフトの直接検査)
# を検証する。/cost-audit 実行時と Claude Code 更新後に必ず実行すること。
#
# 使い方: bash selftest_guard.sh [ガードスクリプトのパス]
set -u

GUARD="${1:-}"
if [ -z "$GUARD" ]; then
  for cand in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/session-budget-guard.sh" \
              "$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/session-budget-guard.sh"; do
    [ -f "$cand" ] && GUARD="$cand" && break
  done
fi
[ -n "${GUARD:-}" ] && [ -f "$GUARD" ] || { echo "NG: ガードスクリプトが見つかりません"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "NG: jq がありません(ガードは現在フェイルオープンで無効)"; exit 1; }

SID="selftest-$$"
TR=$(mktemp)
cleanup() {
  rm -f "$TR" \
    "${TMPDIR:-/tmp}/claude-budget-state-$SID" \
    "${TMPDIR:-/tmp}/claude-budget-warn-$SID" \
    "${TMPDIR:-/tmp}/claude-budget-pace-$SID" \
    "${TMPDIR:-/tmp}/claude-budget-sanity-$SID" 2>/dev/null
}
trap cleanup EXIT
fail=0

# 1) 既知データでコスト集計が一致するか(sonnet: in10k*3 + out14k*15 = raw 240000)
printf '{"uuid":"u1","type":"user","message":{"role":"user","content":"p"}}\n' > "$TR"
printf '{"uuid":"a1","type":"assistant","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":10000,"output_tokens":14000}}}\n' >> "$TR"
printf '{"hook_event_name":"PreToolUse","transcript_path":"%s","session_id":"%s","tool_name":"Read","tool_input":{"file_path":"x"}}' "$TR" "$SID" \
  | bash "$GUARD" >/dev/null 2>&1
st=$(cat "${TMPDIR:-/tmp}/claude-budget-state-$SID" 2>/dev/null || echo "")
case "$st" in
  *" 240000.0000 1 10000") echo "ok: コスト集計(既知データと一致)";;
  *) echo "NG: コスト集計が不一致 [$st] — ガードロジックのドリフトの可能性"; fail=1;;
esac

# 2) 上限ブロックが作動するか
printf '{"uuid":"a2","type":"assistant","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":10000,"output_tokens":400000}}}\n' >> "$TR"
printf '{"hook_event_name":"PreToolUse","transcript_path":"%s","session_id":"%s","tool_name":"Bash","tool_input":{}}' "$TR" "$SID" \
  | bash "$GUARD" >/dev/null 2>&1
if [ $? -eq 2 ]; then echo "ok: 上限ブロック作動"; else echo "NG: 上限ブロックが作動しない"; fail=1; fi

# 3) 実環境のトランスクリプトを解釈できるか(仕様ドリフトの直接検査)
latest=$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/*.jsonl 2>/dev/null | head -1 || true)
if [ -n "$latest" ]; then
  n=$(head -c 2000000 "$latest" | jq -Rn '[inputs | fromjson? // empty | select(.message.usage != null)] | length' 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ]; then
    echo "ok: 実トランスクリプトの usage を解釈可能(${n}件検出: $(basename "$latest"))"
  else
    echo "NG: 実トランスクリプト($latest)から usage を1件も読めません — Claude Code のスキーマ変更の可能性大"
    fail=1
  fi
else
  echo "skip: 実トランスクリプトが見つからないため合成データのみで検証"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "自己診断: すべて正常(コスト保護は機能しています)"
else
  echo "自己診断: 異常あり — コスト保護が機能していない可能性があります。"
  echo "  claude-settings リポジトリの更新を確認・適用し、/cost-audit で報告してください。"
fi
exit "$fail"
