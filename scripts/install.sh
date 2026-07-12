#!/usr/bin/env bash
# claude-settings を ~/.claude に導入する。
# - 既存ファイルと内容が異なる場合のみ ~/.claude/backup-<日時>/ に退避してから配置
# - 既存の settings.json は「保持マージ」する:
#     * 環境固有の設定(env の各種変数・認証設定・独自キー)はそのまま残す
#     * 本テンプレートが定義するキーは推奨値で上書き
#     * permissions.allow / deny は新旧の和集合
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/home"
DST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$DST/backup-$TS"

[ -d "$SRC" ] || { echo "error: $SRC が見つかりません" >&2; exit 1; }
mkdir -p "$DST"

# マージ元として既存 settings.json を先に読み込んでおく
OLD_JSON=""
if [ -f "$DST/settings.json" ]; then
  OLD_JSON="$(cat "$DST/settings.json")"
fi

count=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$DST/$rel"
  if [ -e "$dest" ] && ! cmp -s "$f" "$dest"; then
    mkdir -p "$BK/$(dirname "$rel")"
    cp -p "$dest" "$BK/$rel"
  fi
  mkdir -p "$(dirname "$dest")"
  cp -p "$f" "$dest"
  count=$((count + 1))
done < <(find "$SRC" -type f -print0)

chmod +x "$DST/statusline.sh" 2>/dev/null || true
find "$DST/hooks" "$DST/skills" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

echo "導入完了: $count files → $DST"
[ -d "$BK" ] && echo "既存ファイルをバックアップしました: $BK"

# ---- settings.json の保持マージ ---------------------------------------------
if [ -n "$OLD_JSON" ]; then
  if command -v jq >/dev/null 2>&1; then
    SETTINGS="$DST/settings.json"
    tmp=$(mktemp)
    if printf '%s' "$OLD_JSON" | jq -s --slurpfile tpl "$SETTINGS" '
        def uni(a; b): ((a // []) + (b // [])) | unique;
        .[0] as $old | $tpl[0] as $new |
        ($old * $new)
        | .permissions.deny  = uni($old.permissions.deny;  $new.permissions.deny)
        | .permissions.allow = uni($old.permissions.allow; $new.permissions.allow)
        # hooks: jq の * は配列を右辺で置換するため、素マージだとユーザーの既存フックが
        # 消える。イベント種別ごとに新旧を連結(完全重複のみ除去)して両方を残す。
        | .hooks = (
            (((($old.hooks // {}) | keys) + (($new.hooks // {}) | keys)) | unique) as $ks
            | reduce $ks[] as $k ({}; .[$k] = uni($old.hooks[$k]; $new.hooks[$k]))
          )
      ' > "$tmp" 2>/dev/null && jq -e . "$tmp" > /dev/null 2>&1; then
      mv "$tmp" "$SETTINGS"
      echo ""
      echo "settings.json を保持マージしました:"
      echo "  - 既存の env・認証設定・独自キーは維持"
      echo "  - model / alwaysThinkingEnabled / statusLine はテンプレートの推奨値を適用"
      echo "  - permissions.allow / deny と hooks は新旧の和集合(既存フックは保持)"
      old_model=$(printf '%s' "$OLD_JSON" | jq -r '.model // empty')
      new_model=$(jq -r '.model // empty' "$SETTINGS")
      if [ -n "$old_model" ] && [ "$old_model" != "$new_model" ]; then
        echo "  ⚠ model: \"$old_model\" → \"$new_model\" に変更しました(コスト最適化のため)。"
        echo "    戻す場合は ~/.claude/settings.json の model を編集してください。"
      fi
      # 旧テンプレートが配布していた廃止 env 変数の残存を通知(保持マージでは消えないため)
      if jq -e '.env | has("DISABLE_NON_ESSENTIAL_MODEL_CALLS")' "$SETTINGS" >/dev/null 2>&1; then
        echo "  ⚠ env.DISABLE_NON_ESSENTIAL_MODEL_CALLS は公式ドキュメントから削除された変数です。"
        echo "    現行の代替は CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1(適用済み)。旧変数は手動で削除して構いません。"
      fi
    else
      rm -f "$tmp"
      echo "⚠ マージに失敗したためテンプレートをそのまま配置しました。"
      echo "  旧設定は $BK/settings.json にあります。/cost-audit で差分監査できます。"
    fi
  else
    echo "⚠ jq が見つからないため settings.json の保持マージをスキップしました。"
    echo "  旧設定は $BK/settings.json にあります。必要な項目を手動で移してください。"
  fi
fi
# -----------------------------------------------------------------------------

echo ""
echo "次の手順:"
echo "  1. jq をインストール(statusline とフックが使用): brew install jq / apt install jq"
echo "  2. Claude Code を起動し /cost-audit を実行して監査レポートを確認"
echo "  3. 各プロジェクトに project-template/ の内容を .claude/ としてコピー"
