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
# settings.json は専用マージで扱うのでここでは対象外。CLAUDE.md は**一切触らない**
# (グローバル方針は home/rules/cost-optimization.md = ~/.claude/rules/ に置き、
#  マニフェスト方式で管理する。あなたの CLAUDE.md は自由記述領域として不干渉)。
MANIFEST="$DST/.claude-settings-manifest"
NEWMANIFEST="$(mktemp)"
FORCE="${CLAUDE_INSTALL_FORCE:-0}"
# マニフェストが元から在ったか(初回=ブートストラップ判定)。無い場合、既存の差分は
# 「マニフェスト以前からの導入物」とみなして退避のうえ更新し、マニフェストを作る
# (以後は編集検知で保護)。※ 過去は初回に lookup_hash が存在しないマニフェストへ
#  awk して set -e で無言終了していた(= install が何も出力しない不具合)。ここで解消。
MANIFEST_EXISTED=0; [ -f "$MANIFEST" ] && MANIFEST_EXISTED=1
hashof() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else cksum "$1" | awk '{print $1"-"$2}'; fi
}
# マニフェスト未作成でも失敗しない(空を返す)。set -e 下での無言終了を防ぐ。
lookup_hash() {
  [ -f "$MANIFEST" ] || return 0
  awk -F'\t' -v p="$1" '$2==p{print $1; exit}' "$MANIFEST" 2>/dev/null || true
}

count=0; updated=0; skipped=0; preserved=0; preserved_list=""
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$DST/$rel"
  [ "$rel" = "settings.json" ] && continue
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
    if [ "$FORCE" = "1" ] || [ "$MANIFEST_EXISTED" = "0" ] || { [ -n "$rec" ] && [ "$rec" = "$desthash" ]; }; then
      # 未編集(前回入れた版のまま)/ 初回ブートストラップ / 強制 → 退避して更新
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

echo "導入完了: 更新 ${updated} / 変更なし ${skipped} / 保持 ${preserved}(settings.json を除く計 ${count} files)→ $DST"
if [ "$preserved" -gt 0 ]; then
  echo "  あなたが編集した(と思われる)ファイルは上書きせず保持しました。テンプレ新版は各 <file>.claude-settings-new に置いています:"
  for p in $preserved_list; do echo "    - $p (新版: ${p}.claude-settings-new)"; done
  echo "  差分を確認して、更新したいものだけ new を反映してください(全部テンプレに合わせるなら CLAUDE_INSTALL_FORCE=1 で再実行)。"
fi

# ---- CLAUDE.md からの移行: グローバル方針を rules/ へ移し、CLAUDE.md は触らない --------
# 方針は ~/.claude/rules/cost-optimization.md(上のマニフェスト方式で管理)に置くように
# なった。CLAUDE.md はもう一切書き込まない(あなたの自由記述領域)。
# 旧版が CLAUDE.md へ埋め込んだ「管理ブロック」が残っている場合だけ、それを除去して
# 二重ロード(=方針が rules と CLAUDE.md の両方に載って常駐トークンが二重)を解消する。
# 除去はブロック内(BEGIN〜END)だけで、ブロック外のあなたの記述は1行も消さない。
# 両マーカーが揃っているときのみ実施(破損時は触らない=安全側)。
CLAUDE_MD_BEGIN='<!-- >>> claude-settings managed (トークン倹約グローバル方針・自動更新) >>> -->'
CLAUDE_MD_END='<!-- <<< claude-settings managed <<< -->'
strip_old_managed_block() {
  local dst="$DST/CLAUDE.md" newf
  [ -f "$dst" ] || return 0
  grep -qF "$CLAUDE_MD_BEGIN" "$dst" && grep -qF "$CLAUDE_MD_END" "$dst" || return 0
  newf=$(mktemp)
  awk -v b="$CLAUDE_MD_BEGIN" -v e="$CLAUDE_MD_END" '
    $0==b { skip=1; next }
    $0==e { skip=0; next }
    skip==1 { next }
    { print }
  ' "$dst" > "$newf"
  if cmp -s "$newf" "$dst"; then rm -f "$newf"; return 0; fi
  mkdir -p "$BK"; cp -p "$dst" "$BK/CLAUDE.md" 2>/dev/null || true
  mv "$newf" "$dst"
  echo "CLAUDE.md: 旧・埋め込み管理ブロックを除去しました(コスト方針は ~/.claude/rules/cost-optimization.md へ移行済み。ブロック外のあなたの記述は保持)。"
}
strip_old_managed_block

# 初期の install はマーカー無しで CLAUDE.md へ方針を素コピーしていた。その残骸(探索・
# 出力などの節)は rules/ と二重ロードになるので除去したい。ただし誤削除は厳禁なので、
# **現行テンプレ本文と完全一致する連続ブロックのときだけ**除去する(=自分が書いた方針の
# 逐語コピーだけにマッチ。あなたの独自記述は1文字でも違えばマッチせず絶対に消えない)。
# 完全一致しない(=版ズレ or 手編集あり)ときは案内だけ出して手動削除に委ねる。
strip_inline_policy_exact() {
  local dst="$DST/CLAUDE.md" tpl="$SRC/rules/cost-optimization.md" newf
  [ -f "$dst" ] && [ -f "$tpl" ] || return 1
  grep -qF "$CLAUDE_MD_BEGIN" "$dst" && return 1       # マーカー版は strip 済み
  grep -q '^# グローバル方針(トークン倹約)' "$dst" || return 1
  newf=$(mktemp)
  # tpl の全行が dst 内に連続一致する箇所を探し、そこだけ落とす(他は不変)。
  awk '
    NR==FNR { tpl[FNR]=$0; tn=FNR; next }
    { line[FNR]=$0; ln=FNR }
    END {
      ms=0
      if (tn>0) for (i=1; i<=ln-tn+1; i++) {
        ok=1
        for (j=1; j<=tn; j++) if (line[i+j-1] != tpl[j]) { ok=0; break }
        if (ok) { ms=i; break }
      }
      for (i=1; i<=ln; i++) { if (ms>0 && i>=ms && i<ms+tn) continue; print line[i] }
    }
  ' "$tpl" "$dst" > "$newf"
  if cmp -s "$newf" "$dst"; then rm -f "$newf"; return 1; fi   # 完全一致なし → 変更せず
  mkdir -p "$BK"; cp -p "$dst" "$BK/CLAUDE.md" 2>/dev/null || true
  mv "$newf" "$dst"
  echo "CLAUDE.md: 旧バージョンのコスト方針(テンプレ本文と完全一致する箇所)を除去しました(方針は ~/.claude/rules/cost-optimization.md へ移行済み。あなたの記述は1文字も変更していません)。"
  return 0
}
# 完全一致しなかった(版ズレ/手編集)場合の案内(自動削除しない=誤削除防止)。
notice_inline_policy_leftover() {
  local dst="$DST/CLAUDE.md"
  [ -f "$dst" ] || return 0
  grep -qF "$CLAUDE_MD_BEGIN" "$dst" && return 0
  grep -q '^# グローバル方針(トークン倹約)' "$dst" || return 0
  echo "CLAUDE.md に旧バージョンのコスト方針(テンプレと少し異なる=手編集あり?)が残っているようです。"
  echo "  方針は ~/.claude/rules/cost-optimization.md へ移行済みです。二重ロードを避けるには、"
  echo "  CLAUDE.md 側の「# グローバル方針(トークン倹約)」以下の該当部分を手動で削除してください。"
  echo "  完全一致しない=あなたの手が入っている可能性があるため、自動削除はしていません(誤削除防止)。"
}
strip_inline_policy_exact || notice_inline_policy_leftover
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
    # 変更判定は配列順に依存しない正規形で比較する。uni()=unique が配列をソートするため、
    # 新規配置直後(テンプレの並び)と2回目のマージ結果(ソート済み)が“同じ集合なのに順序
    # 違い”で誤って「変更あり」判定され、無駄な再書き込み・退避が起きていた。これを解消。
    canon() { jq -S 'def s: if type=="array" then map(s)|sort elif type=="object" then map_values(s) else . end; s' "$1" 2>/dev/null; }
    if canon "$tmp" | cmp -s - <(canon "$SETTINGS"); then
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
