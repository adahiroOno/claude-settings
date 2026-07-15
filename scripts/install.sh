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

count=0; updated=0; skipped=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$DST/$rel"
  # settings.json はマージ処理で個別に扱う(ここでは触れない)
  [ "$rel" = "settings.json" ] && continue
  count=$((count + 1))
  # 内容が同一なら丸ごとスキップ(コピーもバックアップもしない=不要な mtime 更新を避ける)
  if [ -e "$dest" ] && cmp -s "$f" "$dest"; then
    skipped=$((skipped + 1)); continue
  fi
  if [ -e "$dest" ]; then
    mkdir -p "$BK/$(dirname "$rel")"
    cp -p "$dest" "$BK/$rel"
  fi
  mkdir -p "$(dirname "$dest")"
  cp -p "$f" "$dest"
  updated=$((updated + 1))
done < <(find "$SRC" -type f -print0)

chmod +x "$DST/statusline.sh" 2>/dev/null || true
find "$DST/hooks" "$DST/skills" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

echo "導入完了: 更新 ${updated} / 変更なし ${skipped}(settings.json を除く計 ${count} files)→ $DST"

# ---- コスト影響設定の相違レビュー(テンプレートが既定に委ねるキー)---------------
# model/alwaysThinkingEnabled/budgets 等はテンプレートが推奨値で明示上書きする。
# 一方 outputStyle のように「テンプレートがあえて Claude 標準に委ねる」コスト影響キーは、
# 保持マージだと上書き対象が無いため既存の非既定値が“黙って”残る。黙認せず相違を明示し、
# どちらを優先するか解決する(対象ファイルを必要なら書き換え、案内文を stdout に返す):
#   - CLAUDE_INSTALL_PREFER=keep|template が指定されていればそれに従う(自動化・Claude 実行時)
#   - 未指定で TTY があれば対話質問(bash ネイティブの「どちらを優先?」)
#   - 未指定で非対話なら既定 keep(破壊しない)
review_outputstyle() {   # $1=対象JSONファイル(必要なら in-place 書き換え)
  local target="$1" pref_env old_ostyle pref ans t2
  pref_env="${CLAUDE_INSTALL_PREFER:-}"
  case "$pref_env" in
    keep|template|"") : ;;
    *) echo "  (CLAUDE_INSTALL_PREFER=\"$pref_env\" は不正。keep として扱います)"; pref_env=keep ;;
  esac
  old_ostyle=$(printf '%s' "$OLD_JSON" | jq -r '.outputStyle // empty')
  [ -n "$old_ostyle" ] && [ "$old_ostyle" != "default" ] || return 0
  pref="$pref_env"
  if [ -z "$pref" ]; then
    if [ -t 0 ]; then
      printf '  コスト影響設定の相違: outputStyle="%s"(既存)\n' "$old_ostyle" >&2
      printf '    冗長系スタイル(Explanatory/Learning 等)は出力トークンが増えます。意図した設定か確認を。\n' >&2
      printf '    [t] 標準スタイルに戻す(節約) / [k] 既存を維持 > ' >&2
      read -r ans || ans=k
      case "$ans" in t|T|template) pref=template ;; *) pref=keep ;; esac
    else
      pref=keep
    fi
  fi
  if [ "$pref" = "template" ]; then
    t2=$(mktemp)
    if jq 'del(.outputStyle)' "$target" > "$t2" 2>/dev/null && jq -e . "$t2" >/dev/null 2>&1; then
      mv "$t2" "$target"
      echo "  ✎ outputStyle: \"$old_ostyle\" を解除し標準スタイルに戻しました(出力トークン節約)。"
    else
      rm -f "$t2"
      echo "  ⚠ outputStyle の解除に失敗。既存値 \"$old_ostyle\" を維持します。"
    fi
  else
    echo "  ⚠ outputStyle: \"$old_ostyle\" を維持しました。冗長スタイルなら出力トークンが増えます —"
    echo "    /config か settings.json で見直せます(CLAUDE_INSTALL_PREFER=template で標準へ自動リセット)。"
  fi
  return 0
}

# ---- settings.json: マージ(既存あり)/ 新規配置(既存なし)/ 同一ならスキップ --------
# 結果が既存と意味的に同一なら、再書き込み・バックアップ・冗長メッセージを一切出さない
# (毎回の再実行を「変更のあった分だけ」に絞る)。
SETTINGS="$DST/settings.json"
TPL="$SRC/settings.json"
backup_old_settings() { mkdir -p "$BK"; cp -p "$SETTINGS" "$BK/settings.json" 2>/dev/null || true; }
if [ -z "$OLD_JSON" ]; then
  cp -p "$TPL" "$SETTINGS"
  echo ""
  echo "settings.json を新規配置しました(推奨値)。"
elif command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  if printf '%s' "$OLD_JSON" | jq -s --slurpfile tpl "$TPL" '
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
    # outputStyle レビューは最終形へ反映してから差分判定する(reset を「変更あり」と認識させる)
    notes=$(review_outputstyle "$tmp")
    if jq -S . "$tmp" 2>/dev/null | cmp -s - <(jq -S . "$SETTINGS" 2>/dev/null); then
      rm -f "$tmp"
      echo ""
      echo "settings.json: 変更なし(既にマージ済み・推奨値と同一)。スキップしました。"
    else
      backup_old_settings
      mv "$tmp" "$SETTINGS"
      echo ""
      echo "settings.json を保持マージしました(項目単位):"
      echo "  - あなた独自の env・認証・キー、独自 permissions/hooks は維持"
      echo "  - permissions.allow / deny・hooks は新旧の和集合(既存フックは保持)"
      # 項目ごとの diff: 既存値がテンプレ推奨値で“上書き/解除”されたキー(=コンフリクト)を
      # old → new で1件ずつ明示する。permissions/hooks は上の和集合扱いなので除外。
      # 新規追加キー(既存に無かったもの)は上書きではないため件数のみ要約する。
      kdiff=$(jq -rn --argjson o "$OLD_JSON" --slurpfile bb "$SETTINGS" '
        $bb[0] as $n |
        def leaves(x): [ x | paths(scalars) | select(.[0] != "permissions" and .[0] != "hooks") ];
        ((leaves($o) + leaves($n)) | unique) as $ps |
        reduce $ps[] as $p ({changed:[], added:0};
          ($o | getpath($p)) as $ov | ($n | getpath($p)) as $nv |
          if $ov == $nv then .
          elif $ov == null then .added += 1
          else .changed += ["    ~ \($p | join(".")): \($ov|tojson) → \(if $nv==null then "(解除)" else ($nv|tojson) end)"]
          end)
        | (if (.changed | length) > 0 then (.changed | join("\n")) else "" end) as $c
        | $c + (if .added > 0 then (if $c == "" then "" else "\n" end) + "    + テンプレート項目を \(.added) 件 新規追加(上書きではない)" else "" end)
      ' 2>/dev/null || true)
      if [ -n "$kdiff" ]; then
        echo "  既存値を変更/解除した項目(既存 → 適用後):"
        printf '%s\n' "$kdiff"
        echo "  ※ 意図して維持したい値(予算 env・thinking・model 等)があれば、その項目を settings.json で再編集してください(次回以降は変更なしとして維持されます)。"
      fi
      # 旧テンプレートが配布していた廃止 env 変数の残存を通知(保持マージでは消えないため)
      if jq -e '.env | has("DISABLE_NON_ESSENTIAL_MODEL_CALLS")' "$SETTINGS" >/dev/null 2>&1; then
        echo "  ⚠ env.DISABLE_NON_ESSENTIAL_MODEL_CALLS は公式ドキュメントから削除された変数です。"
        echo "    現行の代替は CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1(適用済み)。旧変数は手動で削除して構いません。"
      fi
      [ -n "$notes" ] && printf '%s\n' "$notes"
    fi
  else
    rm -f "$tmp"
    backup_old_settings
    cp -p "$TPL" "$SETTINGS"
    echo "⚠ マージに失敗したためテンプレートをそのまま配置しました。"
    echo "  旧設定は $BK/settings.json にあります。/cost-audit で差分監査できます。"
  fi
else
  backup_old_settings
  cp -p "$TPL" "$SETTINGS"
  echo "⚠ jq が見つからないため settings.json の保持マージをスキップしました。"
  echo "  旧設定は $BK/settings.json にあります。必要な項目を手動で移してください。"
fi
[ -d "$BK" ] && echo "変更のあった既存ファイルを $BK に退避しました。"
# -----------------------------------------------------------------------------

echo ""
echo "次の手順:"
echo "  1. jq をインストール(statusline とフックが使用): brew install jq / apt install jq"
echo "  2. Claude Code を起動し /cost-audit を実行して監査レポートを確認"
echo "  3. 各プロジェクトに project-template/ の内容を .claude/ としてコピー"
