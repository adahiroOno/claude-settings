# claude-settings — Claude Code トークン・コスト最適化設定

Claude Code のトークン消費を構造的に抑えるための設定一式です。
従量課金ならコストの削減に、サブスクリプション利用ならレートリミット消費の節約に、同じ施策がそのまま効きます。
「設定を1回入れて終わり」ではなく、**計測 → 監査 → 改善** のループを回せるように設計しています。

## コスト削減の5つのレバー

| # | レバー | 効果の目安 | 本リポジトリでの実装 |
|---|--------|-----------|---------------------|
| 1 | **モデルミックス** — メインは Sonnet、探索・補助は Haiku | 単価ベースで 40〜80% 減 | `home/settings.json` の `model`、`agents/explore.md` |
| 2 | **プロンプトキャッシュの維持** — プレフィックスを壊さない | キャッシュヒット部は約 0.1 倍 | 設定の安定化ルール + `cost-audit` スキルの検査項目 |
| 3 | **コンテキスト最小化** — 読まなくていいものを読ませない | セッション毎の入力トークンを大幅削減 | `permissions.deny`、読み込みガードフック、CLAUDE.md ダイエット |
| 4 | **thinking / 出力の制御** | 出力トークン(最も高単価)を削減 | `alwaysThinkingEnabled: false`、出力簡潔化ルール |
| 5 | **予算・ペースガード** — 目標ペース(既定: 10ターン≒$1)からの逸脱を是正、上限超過で続行を強制ブロック | ペース維持 + 上限額の保証(±1リクエスト) | `hooks/session-budget-guard.sh`、statusline のペース表示 |
| 6 | **可視化と監査** — 測れないものは削減できない | 継続的改善の基盤 | ステータスライン、`/cost`、`cost-audit` スキル |

詳細な根拠と数値は [docs/cost-optimization.md](docs/cost-optimization.md) を参照してください。

## ディレクトリ構成

```
claude-settings/
├── home/                        # ~/.claude/ に配置(scripts/install.sh が実施)
│   ├── settings.json            # グローバル設定(モデル・permissions・hooks)
│   ├── CLAUDE.md                # グローバルメモリ: トークン倹約の行動規範(意図的に短い)
│   ├── statusline.sh            # 予算/ctx の使用率バー・キャッシュ率・ペースを絵文字+色で可視化
│   ├── hooks/
│   │   ├── guard-heavy-read.sh       # Bash経由の巨大ファイル全文読みをブロック
│   │   ├── session-budget-guard.sh   # 予算・ペースのサーキットブレーカー
│   │   └── handoff-notice.sh         # /clear後の作業再開(ハンドオフ検知・低コスト)
│   ├── agents/
│   │   └── explore.md           # Haiku で動く読み取り専用の探索サブエージェント
│   ├── output-styles/
│   │   └── terse.md             # 定型作業フェーズ用の電報調スタイル(/output-style terse)
│   └── skills/
│       └── cost-audit/          # ★ 既存設定・スキル・環境を監査するスキル(/cost-audit で起動)
│           ├── SKILL.md                      # 監査手順(フェーズ0: 完全列挙 → 分類 → 未分類ゼロ)
│           ├── references/checklist.md       # A〜G 7カテゴリのチェックリスト
│           ├── references/coverage-map.md    # 消費面の分類地図(見落とし防止の基盤)
│           ├── scripts/estimate_tokens.sh    # トークン量見積り
│           ├── scripts/scan_background.sh    # バックグラウンド消費の検出
│           └── scripts/export_thinking.sh    # thinkingの事後アーカイブ(モデル呼び出しなし)
├── project-template/            # 各プロジェクトの .claude/ に置くテンプレート
│   ├── settings.json
│   ├── CLAUDE.md
│   └── .gitignore               # handoff.md 等の一時ファイルを除外
├── docs/
│   └── cost-optimization.md     # なぜ効くのか(価格構造・キャッシュ経済・アンチパターン)
├── scripts/
│   └── install.sh               # ~/.claude へ導入(既存設定は保持マージ+バックアップ)
└── tests/
    ├── run-tests.sh             # 回帰テスト(50項目超)
    └── simulate-profiles.sh     # 実用タスク3種のシミュレーション(10T≒$1 検証)
```

## 導入手順

```bash
git clone https://github.com/adahiroOno/claude-settings.git
cd claude-settings
bash scripts/install.sh
```

1. `install.sh` が `home/` の内容を `~/.claude/` に導入します(既存ファイルは `~/.claude/backup-<日時>/` に退避)。
2. 既存の `settings.json` がある場合は**保持マージ**します — あなたの環境固有の設定(`env` の各種変数、認証まわり、permissions、hooks)はそのまま残し、本テンプレートの推奨値を上書き・追加します。
3. Claude Code を起動し、`/cost-audit` を実行して現状の監査レポートを確認します。

各プロジェクトには `project-template/` の内容を `.claude/` にコピーし、プロジェクトに合わせて調整します。

> **シェルについて**: フック・statusline・スクリプトはすべて `#!/usr/bin/env bash` で実行されます。**ログインシェルが zsh でも fish でも影響ありません**(スクリプトは bash で動きます)。bash 4+ 専用機能は使っていないため、macOS 標準の bash 3.2 でも動作します。必要なのは `jq` と `bash` のみです。

## 更新の取り込み(導入済みユーザー向け)

リポジトリの更新を反映するには、`git pull` してから `install.sh` を**再実行**するだけです:

```bash
cd claude-settings   # クローンしたディレクトリ
git pull
bash scripts/install.sh
```

`install.sh` は冪等(何度実行しても安全)です。再実行時:
- 更新された `home/` のファイル(フック・スキル・statusline 等)を `~/.claude/` へ反映します。
- 変更のあった既存ファイルは `~/.claude/backup-<日時>/` に退避してから上書きします。
- `settings.json` は**保持マージ**され、あなたが加えた設定(env・認証・独自 permissions/hooks)は保たれます。

更新後、Claude Code のセッションを開き直すと(設定はセッション起動時に読み込まれるため)反映されます。`/cost-audit` の自己診断(H-1)で、更新後もコスト保護が正常に機能していることを確認できます。

## 既存設定の見直し(cost-audit スキル)

導入後、任意のセッションで:

```
/cost-audit
```

以下を自動で実施します:

- **完全列挙プロトコル(フェーズ0)** — チェックリストの前に、環境に存在するすべての構成物・設定キー・プロセスを列挙し、消費面の分類地図(`references/coverage-map.md`)に対応付ける。**どの面にも分類できないものは「未分類(要判断)」として必ずレポートに載せる**ため、未知の機能・新しい消費源が黙って見落とされることが構造的にない
- `settings.json`(user / project / local)、`CLAUDE.md`、`.mcp.json`、agents、hooks、**既存スキル資産**の棚卸し
- CLAUDE.md・各スキルのトークン量見積り(同梱スクリプト)。スキルは「常駐する description」と「発火時に読まれる本文」を分けて計測
- **既存スキルの構造最適化** — 目的と出力品質は維持したまま、肥大化した本文の references/ 分離、決定論的処理の scripts/ 化、誤発火しやすい description の改善を提案(削除・統合は必ずユーザー承認)
- **バックグラウンド消費のスキャン**(`scan_background.sh`)— 放置された claude プロセス、cron/タイマーからのヘッドレス実行、フック内からのモデル呼び出し(イベント毎に課金される最悪パターン)を機械的に検出
- **仕様ドリフトの三重検知** — Claude Code 本体の更新で前提が変わっても静かに壊れない: ①ガード自身が「解釈できない入力・集計ゼロのセッション」を検知して警告、②カナリア自己診断(`selftest_guard.sh`: 既知データの集計一致・ブロック作動・実トランスクリプトの解釈可否)、③SessionStart フックが本体更新を検知して再監査を提案
- チェックリスト(`references/checklist.md`、A〜I の9カテゴリ)との照合 — キャッシュを壊す設定、常時読み込まれる不要コンテキスト、モデル設定の誤り、設定競合等を検出
- 重要度・推定インパクト付きのレポートと、承認後の修正適用

## ステータスラインの見方

表示例:
```
🤖 Opus 4.8 │ ⚡ high │ 💰 $2.50/$5 █████░░░░░ 50% │ 🧠 60k/120k █████░░░░░ 50% │ 🎯 10T:$0.65 │ 🔄 7 │ 💾 90% │ 📊 5h:24% 7d:41% │ ✍️ terse │ 💭 │ 📝 +12/-3
```

Claude Code が [公式に stdin へ渡す JSON](https://code.claude.com/docs/ja/statusline)(`context_window`・`effort`・`rate_limits` 等)を利用しています。

| 項目 | 意味 | 色・絵文字の変化 |
|---|---|---|
| 🤖 モデル名 | 現在のモデル | — |
| ⚡ effort | 推論努力レベル(low/medium/high/xhigh/max)。**モデルが対応する場合のみ** | — |
| 💰 予算バー | セッションコスト / 上限。`$使用額/$上限 バー 使用率%` | 80%で ⚠️ → 超過で 🛑(バーは満杯・%は実値で超過分がわかる)。バー色 緑→黄→赤 |
| 🧠 ctxバー | 現在のコンテキスト / 肥大ガード閾値。`現在/上限 バー 使用率%`。公式 `context_window.current_usage` 由来 | 90%超・200k超で 🔴。「あと何%で肥大ガードが介入するか」の目安 |
| 🎯 / 🔥 ペース | 10ターン換算コスト。目標(既定 $1/10T)内なら 🎯 緑、超過なら 🔥 赤 | — |
| 🔄 ターン数 | このセッションのユーザープロンプト数 | — |
| 💾 キャッシュ率 | 直近リクエストのキャッシュ読出率(高いほど安い) | 50%未満で赤(キャッシュが壊れている兆候) |
| 📊 レート制限 | 5時間 / 7日のレート制限使用率。**Claude.ai サブスク(Pro/Max)のみ** | 使用率で緑→黄→赤 |
| ✍️ 出力スタイル | 既定以外のとき表示(例 `terse`) | — |
| 💭 thinking | 拡張思考が有効なときのみ表示 | — |
| 📝 変更行数 | セッションの追加/削除行 | +緑 / -赤 |
| 🎫 トークン内訳 | **`CLAUDE_STATUSLINE_TOKENS=1` のときのみ**。直近リクエストの `in:`新規入力 `rd:`キャッシュ読出 `wr:`キャッシュ書込 `out:`出力 | — |

予算・肥大の閾値は `~/.claude/settings.json` の env(`CLAUDE_SESSION_BUDGET_USD` / `CLAUDE_CTX_LIMIT_TOKENS` / `CLAUDE_TURN_BUDGET_USD`)に連動します。

## thinking(判断根拠)のアーカイブ

thinking は生成された時点で出力トークンとして課金される(display設定に関わらず不可避)。
そのコストを削減する手段ではなく、**既に発生したコストの記録を、追加コストゼロで残す**ためのツールです:

```bash
bash home/skills/cost-audit/scripts/export_thinking.sh [transcript.jsonl] [出力先.md]
```

jq のみで動作しモデル呼び出しは一切ないため、実行自体のコストはゼロです。トランスクリプトの
`thinking` ブロックを時系列で Markdown に抽出します。ただし `thinking.display` が既定の
`"omitted"` の場合、API はブロックの中身を空文字列で返すため**抽出しても空になります**
(生成コストは発生済み)。判断根拠を残したい場合は `"summarized"` に切り替える必要があります —
これは可視性の設定でありコストは増えません。

## テストと実タスクシミュレーション

```bash
bash tests/run-tests.sh          # 回帰テスト(フック・statusline・インストールの全挙動)
bash tests/simulate-profiles.sh  # 実用タスク3種の合成セッションで「10ターン≒$1」達成を検証
```

シミュレーションは「軽微な修正」「探索の多い調査(explore 委譲あり/なし比較)」「アンチパターン」の3プロファイルをフックパイプラインに通し、目標内での完走・委譲の削減率・ガードの検知遮断を assert する。設定を変更したら両方を回すこと。

## 運用のリズム

- **毎セッション**: ステータスラインで予算バー(💰)・ctxバー(🧠)の使用率を目視。タスクが変わったら `/clear`(未完了があれば `.claude/handoff.md` に書き残してから — 新セッションが自動検知して再開できる)
- **週次**: `/cost-audit` で設定ドリフトを検査(CLAUDE.md の肥大化、MCP サーバーの増殖は自然に起きる)

※ `.claude/handoff.md` などの一時ファイルは、project-template 同梱の `.gitignore` が除外します。
