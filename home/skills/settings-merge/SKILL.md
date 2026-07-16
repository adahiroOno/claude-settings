---
name: settings-merge
description: このコスト最適化テンプレートの settings.json を、既存の ~/.claude/settings.json へ項目単位で対話マージする。重複しないキーは追加、同値はスキップ、競合したキーだけ AskUserQuestion で都度確認して決める。ユーザーが install の設定衝突を対話で解決したい・outputStyle など特定項目を選んで適用したいときに使う。Use when the user wants to interactively merge/apply the template settings, or resolve settings.json conflicts one item at a time.
argument-hint: [対象の CLAUDE_CONFIG_DIR(省略時 ~/.claude)]
---

# settings-merge — 項目単位の対話マージ(競合は都度確認)

`install.sh` は非対話スクリプトなので `AskUserQuestion` を呼べない。このスキルは
Claude が仲介して、**競合キーだけをあなたに都度確認**してから適用する。方針:

- **重複しない項目(テンプレのみ)** → 追加(確認しない)
- **同値の項目** → スキップ(確認しない)
- **競合(値が違う)項目** → `AskUserQuestion` で「既存を維持 / テンプレ推奨を適用」を確認
- **outputStyle**(コスト直結・排他)→ 現在の設定に関わらず希望を確認(既定は維持。
  節約したいなら terse 等の簡潔スタイル、冗長系 Explanatory/Learning は避ける)

## 手順

1. 対象ディレクトリを決める。引数があればそれを `CLAUDE_CONFIG_DIR` に、無ければ `~/.claude`。
   スクリプトのパスはこのリポジトリの `scripts/install.sh`(無ければ導入済みの
   `~/.claude` から辿らず、ユーザーにリポジトリの場所を聞く)。

2. **プランを取得**(副作用なし・JSON):
   ```bash
   CLAUDE_INSTALL_PLAN=1 CLAUDE_CONFIG_DIR="<dir>" bash scripts/install.sh
   ```
   返り値の `conflicts`(`{key,existing,template}` の配列)・`additions`・`same`・`fresh` を読む。

3. **競合の確認**: `conflicts` が空でなければ、各キーを `AskUserQuestion` で確認する
   (1回の呼び出しに最大4問まとめてよい。5件以上は複数回)。各問の選択肢は
   「既存を維持(`existing` 値)」「テンプレ推奨を適用(`template` 値)」の2つ。
   コスト観点の一言(例: model=sonnet は opus より安価、予算 env は上限)を description に添える。

4. **outputStyle の希望確認**: `outputStyle` が conflicts に無くても、コストに直結する
   ので1問確認する。選択肢は「terse など簡潔スタイル(出力トークン節約)」「今のまま/既定」
   「Explanatory 等の冗長スタイル」等、ユーザーの状況に合わせて提示する。terse を希望
   されたらそれを採用。

5. **決定を適用**: 確認結果から決定 JSON を組み立てる。**「テンプレ推奨を適用」または
   明示値を選んだキーだけ**を入れる(「既存を維持」を選んだキーは入れない=既定の
   keep マージがそのまま維持する)。例:
   ```bash
   printf '%s' '{"model":"sonnet","outputStyle":"terse"}' > /tmp/decisions.json
   CLAUDE_INSTALL_DECISIONS=/tmp/decisions.json CLAUDE_CONFIG_DIR="<dir>" bash scripts/install.sh
   ```
   これで、重複しないキーの追加・守り(hooks/deny/statusline)の追加・既存値の維持・
   決定した値の上書き、が一括で適用される(同値・既存維持でファイルが変わらなければ
   自動でスキップ表示になる)。適用後の変更点はスクリプトが項目単位で表示する。

6. **報告**: 確認した競合と決定、追加された項目数、維持した項目を1〜2行で要約する。

## 注意

- `conflicts` が空(`fresh:true` 含む)なら確認は outputStyle の希望のみでよい。何も
  希望が無ければ `install.sh` をそのまま(決定なしで)実行すればよい。
- permissions/hooks はスクリプトが常に和集合でマージするため確認対象にしない。
- 破壊防止: スクリプトは適用前に既存 settings.json を `~/.claude/backup-<日時>/` に退避する。
