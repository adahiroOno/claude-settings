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
│   ├── statusline.sh            # モデル名とセッションコストを常時表示
│   ├── hooks/
│   │   ├── guard-heavy-read.sh       # Bash経由の巨大ファイル全文読みをブロック
│   │   ├── session-budget-guard.sh   # 予算・ペースのサーキットブレーカー
│   │   └── handoff-notice.sh         # /clear後の作業再開(ハンドオフ検知・低コスト)
│   ├── agents/
│   │   └── explore.md           # Haiku で動く読み取り専用の探索サブエージェント
│   ├── output-styles/
│   │   └── terse.md             # 定型作業フェーズ用の電報調スタイル(/output-style terse)
│   └── skills/
│       └── cost-audit/          # ★ 既存設定を監査・見直すスキル(/cost-audit で起動)
│           ├── SKILL.md
│           ├── references/checklist.md
│           └── scripts/estimate_tokens.sh
├── project-template/            # 各プロジェクトの .claude/ に置くテンプレート
│   ├── settings.json
│   ├── CLAUDE.md
│   └── .gitignore               # handoff.md 等の一時ファイルを除外
├── docs/
│   └── cost-optimization.md     # なぜ効くのか(価格構造・キャッシュ経済・アンチパターン)
└── scripts/
    └── install.sh               # ~/.claude へ導入(既存設定は保持マージ+バックアップ)
```

## 導入手順

```bash
git clone https://github.com/adahiroOno/claude-settings.git
cd claude-settings
bash scripts/install.sh
```

1. `install.sh` が `home/` の内容を `~/.claude/` に導入します(既存ファイルは `~/.claude/backup-<日時>/` に退避)。
2. 既存の `settings.json` がある場合は**保持マージ**します — あなたの環境固有の設定(`env` の各種変数、認証まわり、permissions 等)はそのまま残し、本テンプレートの推奨値を上書き・追加します。
3. Claude Code を起動し、`/cost-audit` を実行して現状の監査レポートを確認します。

各プロジェクトには `project-template/` の内容を `.claude/` にコピーし、プロジェクトに合わせて調整します。

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
- チェックリスト(`references/checklist.md`、A〜G の7カテゴリ)との照合 — キャッシュを壊す設定、常時読み込まれる不要コンテキスト、モデル設定の誤り等を検出
- 重要度・推定インパクト付きのレポートと、承認後の修正適用

## テストと実タスクシミュレーション

```bash
bash tests/run-tests.sh          # 回帰テスト(フック・statusline・インストールの全挙動)
bash tests/simulate-profiles.sh  # 実用タスク3種の合成セッションで「10ターン≒$1」達成を検証
```

シミュレーションは「軽微な修正」「探索の多い調査(explore 委譲あり/なし比較)」「アンチパターン」の3プロファイルをフックパイプラインに通し、目標内での完走・委譲の削減率・ガードの検知遮断を assert する。設定を変更したら両方を回すこと。

## 運用のリズム

- **毎セッション**: ステータスラインでコストとペース(`10T≈$X`)を目視。タスクが変わったら `/clear`(未完了があれば `.claude/handoff.md` に書き残してから — 新セッションが自動検知して再開できる)
- **週次**: `/cost-audit` で設定ドリフトを検査(CLAUDE.md の肥大化、MCP サーバーの増殖は自然に起きる)

※ `.claude/handoff.md` などの一時ファイルは、project-template 同梱の `.gitignore` が除外します。
