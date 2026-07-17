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

# ---- プラン(dry-run)モード ---------------------------------------------------
# 変更を一切行わず、settings.json の項目単位の分析だけを JSON で標準出力する:
#   conflicts: 既存とテンプレで値が食い違うキー(= 都度確認が必要)
#   additions: テンプレのみが持つキー(= 追加してよい。permissions/hooks を除く)
#   same:      既存とテンプレで同値のキー(= スキップ)
# Claude(/settings-merge スキル)がこれを読み、conflicts を AskUserQuestion で
# 都度確認したうえで、決定を CLAUDE_INSTALL_DECISIONS 経由で適用する。
# permissions/hooks は常に和集合(コンフリクトなし)なので分析対象外。
if [ "${CLAUDE_INSTALL_PLAN:-0}" = "1" ]; then
  command -v jq >/dev/null 2>&1 || { echo '{"error":"jq_required"}'; exit 0; }
  TPL="$SRC/settings.json"
  if [ -z "$OLD_JSON" ]; then
    jq -n --slurpfile t "$TPL" '{fresh:true, conflicts:[], additions:($t[0]|[paths(type!="object" and type!="array")|select(.[0]!="permissions" and .[0]!="hooks")|join(".")]), same:[]}'
  else
    printf '%s' "$OLD_JSON" | jq -s --slurpfile t "$TPL" '
      .[0] as $o | $t[0] as $n |
      def leaves(x): [ x | paths(type != "object" and type != "array") | select(.[0] != "permissions" and .[0] != "hooks") ];
      ((leaves($o) + leaves($n)) | unique) as $ps |
      reduce $ps[] as $p ({fresh:false, conflicts:[], additions:[], same:[]};
        ($o | getpath($p)) as $ov | ($n | getpath($p)) as $nv | ($p | join(".")) as $k |
        if   $nv == null then .                       # テンプレに無い(ユーザー独自)→ 触れない
        elif $ov == null then .additions += [$k]      # テンプレのみ → 追加
        elif $ov == $nv then .same += [$k]            # 同値 → スキップ
        else .conflicts += [{key:$k, existing:$ov, template:$nv}]
        end)
    '
  fi
  exit 0
fi
# -----------------------------------------------------------------------------

# ファイル配置は「マニフェスト方式」で、あなたが編集したファイルを上書きしない。
# ~/.claude/.claude-settings-manifest に、前回インストールした各ファイルのハッシュを記録する。
#   - 既存が無い            → 配置(記録)
#   - 既存 == テンプレ       → スキップ(記録)
#   - 既存 != テンプレ:
#       ・記録ハッシュと一致(=前回入れた版のまま=未編集) → 更新(退避して上書き・記録)
#       ・不一致/記録なし(=あなたが編集 or 由来不明)      → 上書きせず保持し、
#         テンプレ新版を <file>.claude-settings-new に置く(あなたの版を壊さない)
#   - CLAUDE_INSTALL_FORCE=1 で従来どおり一括上書き(退避あり)
# settings.json・CLAUDE.md はそれぞれ専用のマージで扱うのでここでは対象外。
MANIFEST="$DST/.claude-settings-manifest"
NEWMANIFEST="$(mktemp)"
FORCE="${CLAUDE_INSTALL_FORCE:-0}"
hashof() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else cksum "$1" | awk '{print $1"-"$2}'; fi
}
lookup_hash() { awk -F'\t' -v p="$1" '$2==p{print $1; exit}' "$MANIFEST" 2>/dev/null; }

count=0; updated=0; skipped=0; preserved=0; preserved_list=""
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$DST/$rel"
  { [ "$rel" = "settings.json" ] || [ "$rel" = "CLAUDE.md" ]; } && continue
  count=$((count + 1))
  newhash="$(hashof "$f")"
  if [ ! -e "$dest" ]; then
    mkdir -p "$(dirname "$dest")"; cp -p "$f" "$dest"
    updated=$((updated + 1)); printf '%s\t%s\n' "$newhash" "$rel" >> "$NEWMANIFEST"
  elif cmp -s "$f" "$dest"; then
    skipped=$((skipped + 1)); printf '%s\t%s\n' "$newhash" "$rel" >> "$NEWMANIFEST"
    rm -f "$dest.claude-settings-new"   # 追いついたので新版マーカーは掃除
  else
    desthash="$(hashof "$dest")"; rec="$(lookup_hash "$rel")"
    if [ "$FORCE" = "1" ] || { [ -n "$rec" ] && [ "$rec" = "$desthash" ]; }; then
      # あなたが編集していない(前回入れた版のまま)or 強制 → 安全に更新
      mkdir -p "$BK/$(dirname "$rel")"; cp -p "$dest" "$BK/$rel"
      cp -p "$f" "$dest"; updated=$((updated + 1))
      printf '%s\t%s\n' "$newhash" "$rel" >> "$NEWMANIFEST"
      rm -f "$dest.claude-settings-new"
    else
      # あなたが編集した/由来不明 → 上書きせず保持。新版は隣に置く。
      cp -p "$f" "$dest.claude-settings-new"
      preserved=$((preserved + 1)); preserved_list="$preserved_list $rel"
      [ -n "$rec" ] && printf '%s\t%s\n' "$rec" "$rel" >> "$NEWMANIFEST"
    fi
  fi
done < <(find "$SRC" -type f -print0)
mv "$NEWMANIFEST" "$MANIFEST" 2>/dev/null || rm -f "$NEWMANIFEST"

chmod +x "$DST/statusline.sh" 2>/dev/null || true
find "$DST/hooks" "$DST/skills" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

echo "導入完了: 更新 ${updated} / 変更なし ${skipped} / 保持 ${preserved}(settings.json・CLAUDE.md を除く計 ${count} files)→ $DST"
if [ "$preserved" -gt 0 ]; then
  echo "  あなたが編集した(と思われる)ファイルは上書きせず保持しました。テンプレ新版は各 <file>.claude-settings-new に置いています:"
  for p in $preserved_list; do echo "    - $p (新版: ${p}.claude-settings-new)"; done
  echo "  差分を確認して、更新したいものだけ new を反映してください(全部テンプレに合わせるなら CLAUDE_INSTALL_FORCE=1 で再実行)。"
fi

# ---- CLAUDE.md: 管理ブロック方式で更新(あなたの記述を絶対に消さない)---------------
# CLAUDE.md はユーザーのグローバルメモリ(自由記述)。**いかなる場合も既存の記述を
# 削除・全置換しない。** テンプレのコスト方針を BEGIN/END マーカーで囲んだ管理ブロック
# として扱い、次のいずれかだけを行う:
#   - 既存にマーカーあり            → マーカー間だけ最新テンプレへ差し替え(ブロック外は不変)
#   - マーカー無し & 現行テンプレと完全一致(=追記ゼロ) → マーカーで囲むだけ(内容不変)
#   - それ以外(マーカー無しで内容が違う=あなたの追記/独自記述あり)
#                                   → 1行も消さず、管理ブロックを末尾に追加するだけ
# ※ かつて存在した「見出しが一致したら全置換して移行」する分岐は、追記を消す不具合の
#    原因だったため撤去した。全置換は「現行テンプレと完全一致」のときのみ(=情報損失ゼロ)。
# 同一結果ならスキップ。差分があるときだけ退避してから書き込む。
CLAUDE_MD_BEGIN='<!-- >>> claude-settings managed (トークン倹約グローバル方針・自動更新) >>> -->'
CLAUDE_MD_END='<!-- <<< claude-settings managed <<< -->'
merge_claude_md() {
  local tpl="$SRC/CLAUDE.md" dst="$DST/CLAUDE.md" newf mode
  [ -f "$tpl" ] || return 0
  if [ ! -f "$dst" ]; then
    { printf '%s\n' "$CLAUDE_MD_BEGIN"; cat "$tpl"; printf '%s\n' "$CLAUDE_MD_END"; } > "$dst"
    echo "CLAUDE.md を新規配置しました(コスト方針を管理ブロックとして)。"
    return 0
  fi
  # update は BEGIN と END の**両方**が揃っているときだけ。片方だけ(マーカー破損)なら
  # ブロック範囲が確定できず awk が末尾を巻き込んで消しかねないので、安全側の append にする。
  if grep -qF "$CLAUDE_MD_BEGIN" "$dst" && grep -qF "$CLAUDE_MD_END" "$dst"; then mode=update
  elif cmp -s "$tpl" "$dst"; then mode=wrap         # 現行テンプレと完全一致 → 追記ゼロなので安全に囲む
  else mode=append; fi                              # 追記/独自記述あり・マーカー破損 → 消さずに末尾追加のみ
  newf=$(mktemp)
  case "$mode" in
    update)
      awk -v b="$CLAUDE_MD_BEGIN" -v e="$CLAUDE_MD_END" -v tf="$tpl" '
        $0==b { print; while((getline l < tf) > 0) print l; close(tf); skip=1; next }
        $0==e { skip=0; print; next }
        skip==1 { next }
        { print }
      ' "$dst" > "$newf" ;;
    wrap)
      { printf '%s\n' "$CLAUDE_MD_BEGIN"; cat "$tpl"; printf '%s\n' "$CLAUDE_MD_END"; } > "$newf" ;;
    append)
      { cat "$dst"; printf '\n%s\n' "$CLAUDE_MD_BEGIN"; cat "$tpl"; printf '%s\n' "$CLAUDE_MD_END"; } > "$newf" ;;
  esac
  if cmp -s "$newf" "$dst"; then
    rm -f "$newf"
    echo "CLAUDE.md: 変更なし。スキップしました。"
  else
    mkdir -p "$BK"; cp -p "$dst" "$BK/CLAUDE.md" 2>/dev/null || true
    mv "$newf" "$dst"
    case "$mode" in
      update)  echo "CLAUDE.md: 管理ブロックのみ最新化しました(ブロック外のあなたの記述は保持)。" ;;
      wrap)    echo "CLAUDE.md: コスト方針を管理ブロックで囲みました(内容は不変)。" ;;
      append)  echo "CLAUDE.md: あなたの既存内容は1行も消さず、コスト方針を管理ブロックとして末尾に追加しました(重複する旧記述があれば手動で削除できます)。" ;;
    esac
  fi
}
merge_claude_md
# -----------------------------------------------------------------------------

# ---- マージ方針(コンフリクトの勝敗)------------------------------------------
# 既定は「あなたの既存値を優先(keep)」。テンプレートは“守り”(hooks・deny リスト・
# 予算/上限 env・statusline)を追加し、未設定キーを埋めるだけで、あなたが明示した
# 値(model・outputStyle・予算など)は勝手に書き換えない。理由:
#   - model を一律 sonnet に強制すると、あなたが選んだ上位/最新モデルを黙って
#     下位・古い参照へ差し替えてしまう(ユーザー報告の不具合)。
#   - outputStyle=terse のような“簡潔=節約”スタイルを標準へ戻すのは逆効果。
# 積極的にテンプレ推奨へ寄せたいときだけ CLAUDE_INSTALL_PREFER=template を使う。
PREFER_MODE="${CLAUDE_INSTALL_PREFER:-}"
case "$PREFER_MODE" in
  keep|template|"") : ;;
  *) echo "  (CLAUDE_INSTALL_PREFER=\"$PREFER_MODE\" は不正。keep として扱います)"; PREFER_MODE=keep ;;
esac

# outputStyle レビュー: 出力トークンを“増やす”ことが分かっている公式スタイル
# (Explanatory / Learning)だけを対象にする。terse・concise 等の簡潔スタイルや
# ユーザー独自スタイルはむしろ節約になり得るため、絶対に触らない(既存を尊重)。
# 既定は維持。標準へ戻すのは PREFER=template か対話での明示 opt-in のときだけ。
review_outputstyle() {   # $1=対象JSONファイル(必要なら in-place 書き換え)
  local target="$1" old_ostyle pref ans t2
  old_ostyle=$(printf '%s' "$OLD_JSON" | jq -r '.outputStyle // empty')
  [ -n "$old_ostyle" ] || return 0
  case "$old_ostyle" in
    Explanatory|Learning) : ;;   # 冗長化が既知の公式スタイルのみ対象
    *) return 0 ;;               # default・terse・独自スタイル → 触らない
  esac
  pref="$PREFER_MODE"
  if [ -z "$pref" ]; then
    if [ -t 0 ]; then
      printf '  outputStyle="%s" は応答が冗長化し出力トークンが増えます。\n' "$old_ostyle" >&2
      printf '    [t] 標準スタイルに戻す(節約) / [k] 維持 > ' >&2
      read -r ans || ans=k
      case "$ans" in t|T) pref=template ;; *) pref=keep ;; esac
    else
      pref=keep
    fi
  fi
  if [ "$pref" = "template" ]; then
    t2=$(mktemp)
    if jq 'del(.outputStyle)' "$target" > "$t2" 2>/dev/null && jq -e . "$t2" >/dev/null 2>&1; then
      mv "$t2" "$target"
      echo "  ✎ outputStyle: \"$old_ostyle\"(冗長系)を解除し標準スタイルに戻しました(出力トークン節約)。"
    else
      rm -f "$t2"
      echo "  ⚠ outputStyle の解除に失敗。既存値 \"$old_ostyle\" を維持します。"
    fi
  else
    echo "  ⚠ outputStyle=\"$old_ostyle\"(冗長系)を維持しました。標準へ戻すと出力トークンを節約できます(CLAUDE_INSTALL_PREFER=template)。"
  fi
  return 0
}

# ---- settings.json: マージ(既存あり)/ 新規配置(既存なし)/ 同一ならスキップ --------
# 結果が既存と意味的に同一なら、再書き込み・バックアップ・冗長メッセージを一切出さない。
SETTINGS="$DST/settings.json"
TPL="$SRC/settings.json"
backup_old_settings() { mkdir -p "$BK"; cp -p "$SETTINGS" "$BK/settings.json" 2>/dev/null || true; }
if [ -z "$OLD_JSON" ]; then
  cp -p "$TPL" "$SETTINGS"
  echo ""
  echo "settings.json を新規配置しました(推奨値)。"
elif command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  # keep(既定): $new * $old = テンプレで不足キーを埋め、競合は既存(あなた)が勝つ。
  # template:   $old * $new = 競合はテンプレ推奨値が勝つ(積極的コスト最適化)。
  # permissions/hooks はどちらでも新旧の和集合(守りは常に足し込む)。
  if printf '%s' "$OLD_JSON" | jq -s --slurpfile tpl "$TPL" --arg mode "$PREFER_MODE" '
      def uni(a; b): ((a // []) + (b // [])) | unique;
      .[0] as $old | $tpl[0] as $new |
      (if $mode == "template" then ($old * $new) else ($new * $old) end)
      | .permissions.deny  = uni($old.permissions.deny;  $new.permissions.deny)
      | .permissions.allow = uni($old.permissions.allow; $new.permissions.allow)
      # hooks: jq の * は配列を右辺で置換するため、素マージだとユーザーの既存フックが
      # 消える。イベント種別ごとに新旧を連結(完全重複のみ除去)して両方を残す。
      | .hooks = (
          (((($old.hooks // {}) | keys) + (($new.hooks // {}) | keys)) | unique) as $ks
          | reduce $ks[] as $k ({}; .[$k] = uni($old.hooks[$k]; $new.hooks[$k]))
        )
    ' > "$tmp" 2>/dev/null && jq -e . "$tmp" > /dev/null 2>&1; then
    # outputStyle レビュー(冗長系のみ)を最終形へ反映してから差分判定する。
    notes=$(review_outputstyle "$tmp")
    # 決定オーバーレイ: /settings-merge スキルが AskUserQuestion で確定した値を
    # CLAUDE_INSTALL_DECISIONS(JSON ファイル)で渡すと、それを最終形に上書き適用する。
    # 例: {"model":"sonnet","outputStyle":"terse"}。競合の都度確認の結果をそのまま反映。
    if [ -n "${CLAUDE_INSTALL_DECISIONS:-}" ] && [ -f "$CLAUDE_INSTALL_DECISIONS" ]; then
      td=$(mktemp)
      if jq -s '.[0] * .[1]' "$tmp" "$CLAUDE_INSTALL_DECISIONS" > "$td" 2>/dev/null && jq -e . "$td" >/dev/null 2>&1; then
        mv "$td" "$tmp"
      else
        rm -f "$td"; echo "  ⚠ CLAUDE_INSTALL_DECISIONS の適用に失敗(不正な JSON?)。決定は無視しました。"
      fi
    fi
    if jq -S . "$tmp" 2>/dev/null | cmp -s - <(jq -S . "$SETTINGS" 2>/dev/null); then
      rm -f "$tmp"
      echo ""
      echo "settings.json: 変更なし(既に統合済み)。スキップしました。"
    else
      backup_old_settings
      mv "$tmp" "$SETTINGS"
      echo ""
      if [ "$PREFER_MODE" = "template" ]; then
        echo "settings.json をマージしました(テンプレ推奨を優先 / PREFER=template):"
      else
        echo "settings.json をマージしました(あなたの既存値を優先):"
      fi
      echo "  - あなたが設定済みの値(model・outputStyle・env・認証等)は維持。テンプレは不足キーを補い、守り(hooks・deny・予算 env・statusline)を追加"
      echo "  - permissions.allow / deny・hooks は新旧の和集合(既存フックは保持)"
      # 項目ごとの diff: old と テンプレ推奨が食い違うキーを列挙する。
      #  keep 既定 → 既存を維持したことと推奨値を併記(黙って書き換えない透明性)。
      #  template → old → new(適用)を明示。permissions/hooks は和集合扱いで除外。
      kdiff=$(jq -rn --argjson o "$OLD_JSON" --slurpfile bb "$SETTINGS" --slurpfile tt "$TPL" '
        $bb[0] as $final | $tt[0] as $tpl |
        def leaves(x): [ x | paths(type != "object" and type != "array") | select(.[0] != "permissions" and .[0] != "hooks") ];
        ((leaves($o) + leaves($tpl)) | unique) as $ps |
        reduce $ps[] as $p ({conflict:[], added:0};
          ($o | getpath($p)) as $ov | ($tpl | getpath($p)) as $tv | ($final | getpath($p)) as $fv |
          if ($ov == null and $tv != null) then .added += 1
          elif ($ov != null and $tv != null and $ov != $tv) then
            .conflict += ["    ・\($p | join(".")): " +
              (if $fv == $ov then "既存 \($ov|tojson) を維持(テンプレ推奨: \($tv|tojson))"
               else "\($ov|tojson) → \($fv|tojson)(推奨を適用)" end)]
          else . end)
        | (if (.conflict | length) > 0 then (.conflict | join("\n")) else "" end) as $c
        | $c + (if .added > 0 then (if $c == "" then "" else "\n" end) + "    + テンプレート項目を \(.added) 件 追加(不足分の補完)" else "" end)
      ' 2>/dev/null || true)
      if [ -n "$kdiff" ]; then
        echo "  推奨値と食い違う項目・追加項目:"
        printf '%s\n' "$kdiff"
        if [ "$PREFER_MODE" != "template" ]; then
          echo "  → 既存値はそのまま維持しています。テンプレ推奨(例: model=sonnet)に寄せたい場合のみ CLAUDE_INSTALL_PREFER=template で再実行してください。"
        fi
      fi
      # 旧テンプレートが配布していた廃止 env 変数の残存を通知(保持マージでは消えないため)
      if jq -e '.env | has("DISABLE_NON_ESSENTIAL_MODEL_CALLS")' "$SETTINGS" >/dev/null 2>&1; then
        echo "  ⚠ env.DISABLE_NON_ESSENTIAL_MODEL_CALLS は公式ドキュメントから削除された変数です。"
        echo "    現行の代替は CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1。旧変数は手動で削除して構いません。"
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
