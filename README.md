# claude-settings — Claude Code トークン・コスト最適化設定

Claude Code のトークン消費を構造的に抑えるための設定一式です。
従量課金ならコストの削減に、サブスクリプション利用ならレートリミット消費の節約に、同じ施策がそのまま効きます。
「設定を1回入れて終わり」ではなく、**計測 → 監査 → 改善** のループを回せるように設計しています。

## コスト削減の7つのレバー

| # | レバー | 効果の目安 | 本リポジトリでの実装 |
|---|--------|-----------|---------------------|
| 1 | **モデルミックス** — メインは Sonnet、探索・補助は Haiku | 単価ベースで 40〜80% 減 | `home/settings.json` の `model`、`agents/explore.md` |
| 2 | **プロンプトキャッシュの維持** — プレフィックスを壊さない | キャッシュヒット部は約 0.1 倍 | 設定の安定化ルール + `cost-audit` スキルの検査項目 |
| 3 | **コンテキスト最小化** — 読まなくていいものを読ませない | セッション毎の入力トークンを大幅削減 | `permissions.deny`、読み込みガードフック、CLAUDE.md ダイエット |
| 4 | **thinking / 出力の制御** | 出力トークン(最も高単価)を削減 | `alwaysThinkingEnabled: false`、出力簡潔化ルール |
| 5 | **予算・ペースガード** — 目標ペース(既定: 10ターン≒$1)からの逸脱を是正、上限超過で続行を強制ブロック | ペース維持 + 上限額の保証(±1リクエスト) | `hooks/session-budget-guard.sh`、statusline のペース表示 |
| 6 | **可視化と監査** — 測れないものは削減できない | 継続的改善の基盤 | ステータスライン、`/cost`、`cost-audit` スキル |
| 7 | **手戻りの削減(プロンプト品質)** — 曖昧な依頼による投機的探索・やり直しを防ぐ | 1回の手戻り回避で数千〜数万トークン | CLAUDE.md の確認ファーストの規範(自動)、`/refine` スキル(半自動) |

詳細な根拠と数値は [docs/cost-optimization.md](docs/cost-optimization.md) を参照してください。

## 制御の仕組み(アーキテクチャ)

トークン消費を抑える仕組みは、**強制力の異なる4層**で構成されています。「設定したのに効かない」を防ぐため、どの層が実際にブロックする力を持つかを区別しておくことが重要です。

| 層 | 主体 | 強制力 | 役割 |
|---|---|---|---|
| **強制** | hooks(決定論的スクリプト) | **あり** — 条件を満たすと `exit 2` でツール実行/プロンプト送信を実際にブロックする | 予算・ペース・コンテキスト肥大の逸脱を止める、巨大ファイルの読込を防ぐ |
| **予防** | `settings.json` の静的設定 | **あり** — そもそも発生させない | モデル単価(`model: sonnet`)、thinking無効化(`alwaysThinkingEnabled: false`)、読込禁止(`permissions.deny`) |
| **誘導** | `CLAUDE.md` の行動規範 | **なし** — モデルへの指示。フックはモデルの挙動を直接変更できない(仕様上の制約)ため、これが唯一の誘導経路 | explore委譲・簡潔な出力・handoff更新をモデルに促す |
| **事後監査** | `/cost-audit` スキル | **なし** — 自動実行されず、呼び出したときだけ動く | 設定・スキル・バックグラウンド消費の棚卸しと改善提案 |

**実際に強制力を持つのは上2層(hooks・静的設定)だけ**です。CLAUDE.md はモデルへのお願いであり、モデルが無視すれば効きません。

### hooks が発火する条件

`session-budget-guard.sh` はセッションのトランスクリプトを差分解析し、次の閾値を超えると `exit 2` でブロックします(threshold は `~/.claude/settings.json` の `env` で調整可能):

| フック | 発火イベント | 監視する対象 | 超過時の動作 |
|---|---|---|---|
| `session-budget-guard.sh` | `PreToolUse`(全ツール)+ `UserPromptSubmit` | セッション予算(既定 $5)、**ターン数上限(既定 10ターン、コストと独立の第2軸)**、10ターン換算ペース(既定 $1/10T)、コンテキストサイズ(既定 12万トークン) | **PreToolUse**: ツール実行をブロックし、是正指示(効率化・`/clear`提案)をモデルに返す(仕様上 exit 2 の stderr はモデルに渡る)。**UserPromptSubmit**: 上限超過時のみブロックし、案内はユーザーに表示(仕様上プロンプトは消去され stderr はユーザーのみ — このためペース・肥大の「警告」はここでは発火させない)。`.claude/handoff.md` への書き込みは上限超過中も常に許可(グレースレーン=作業状態を失わせない) |
| `guard-heavy-read.sh` | `PreToolUse`(`Bash`) | ロックファイル・生成物(`node_modules`・`dist`等)への全文読み込みコマンド | ブロックし、`rg`/`jq` での部分抽出を提案 |
| `handoff-notice.sh` | `SessionStart` | 前回セッションの `.claude/handoff.md`(cwd → git ルートの順で探索)、Claude Code 本体の更新有無 | ブロックはしない。48時間以内の handoff があれば**本文を先頭に注入**(上限3000バイト)— 1ターン目から Read なしで再開できる。`CLAUDE_HANDOFF_NOTICE=min` で従来の3行通知に切替可 |
| `handoff-autostub.sh` | `SessionEnd`(`/clear` 時のみ) | handoff の書き忘れ | モデル未関与の決定論的スタブ(日時・ディレクトリ・直近の依頼・元トランスクリプトへのポインタ)を `.claude/handoff.md` に自動保存。48時間以内の既存 handoff は上書きしない。`CLAUDE_HANDOFF_AUTOSTUB=0` で無効化 |

各ガードの詳しい閾値・グレースレーン・仕様ドリフト対策は [docs/cost-optimization.md](docs/cost-optimization.md) を参照してください。

## ディレクトリ構成

```
claude-settings/
├── home/                        # ~/.claude/ に配置(scripts/install.sh が実施)
│   ├── settings.json            # グローバル設定(モデル・permissions・hooks)
│   ├── CLAUDE.md                # グローバルメモリ: トークン倹約の行動規範(意図的に短い)
│   ├── statusline.sh            # 予算/ctx の使用率バー・キャッシュ率・ペースを絵文字+色で可視化
│   ├── hooks/
│   │   ├── guard-heavy-read.sh       # Bash経由の巨大ファイル全文読みをブロック
│   │   ├── session-budget-guard.sh   # 予算・ペース・ターン数のサーキットブレーカー
│   │   ├── handoff-notice.sh         # /clear後の作業再開(SessionStartで本文を注入・低コスト)
│   │   ├── handoff-autostub.sh       # /clear時に引き継ぎスタブを自動生成(SessionEnd・モデル未関与)
│   │   └── handoff-archive.sh        # handoffを .claude/notes/ に日時付きで退避(履歴・並行タスク)
│   ├── agents/
│   │   └── explore.md           # Haiku で動く読み取り専用の探索サブエージェント
│   ├── output-styles/
│   │   └── terse.md             # 定型作業フェーズ用の電報調スタイル(/output-style terse)
│   └── skills/
│       ├── cost-audit/          # ★ 既存設定・スキル・環境を監査するスキル(/cost-audit で起動)
│       │   ├── SKILL.md                      # 監査手順(フェーズ0: 完全列挙 → 分類 → 未分類ゼロ)
│       │   ├── references/checklist.md       # A〜I 9カテゴリのチェックリスト
│       │   ├── references/coverage-map.md    # 消費面の分類地図(見落とし防止の基盤)
│       │   ├── scripts/estimate_tokens.sh    # トークン量見積り
│       │   ├── scripts/scan_background.sh    # バックグラウンド消費の検出
│       │   ├── scripts/selftest_guard.sh     # ガードのカナリア自己診断(仕様ドリフト検知②)
│       │   └── scripts/export_thinking.sh    # thinkingの事後アーカイブ(モデル呼び出しなし)
│       ├── refine/
│       │   └── SKILL.md         # 曖昧な依頼を実行前に仕様へ整形(/refine で起動・手戻り防止)
│       └── handoff/
│           └── SKILL.md         # 引き継ぎメモをモデル品質で保存(/handoff で起動 → /clear)
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

## プロンプト品質による手戻り削減(refine スキル)

トークンの浪費で最も高くつくのは、モデルの無駄遣いではなく**依頼の曖昧さ**です。曖昧な依頼は (1) 投機的なファイル探索(数千〜数万トークン)、(2) 誤解に基づく実装のやり直し、(3) 誤った文脈の残骸が以降の全ターンで再送され続ける、という三重のコストを生みます。対策は自動・半自動の2段構えです:

- **自動(CLAUDE.md 規範)** — 大きな作業の依頼が曖昧なとき、モデルは推測で探索を始める前に**確認質問を1つだけ**してから着手します。軽微な依頼は質問せず即実行します。ユーザーの操作は不要です。
- **半自動(`/refine` スキル)** — 大きめの作業を頼むとき `/refine <依頼内容>` と打つと、実行前に依頼を「目的 / 範囲 / 制約 / 完了条件 / 想定外」の仕様に整形し、不明点だけを選択肢つきで質問(最大3つ・1往復)してから着手します。整形の段階ではファイル探索をしないため、この工程自体は数百トークンで済みます。

使い分けの目安: 依頼内容が自分でも固まっていないときは `/refine`、固まっているならそのまま依頼(曖昧ならモデル側が1問だけ確認)。

## ステータスラインの見方

既定は**2行表示**です(1行目=環境・コンテキスト、2行目=コスト・進捗)。表示例:
```
🤖 Opus 4.8 │ ⚡ high │ 🧠 60k/120k █████░░░░░ 50% │ 💾 90% │ 📊 5h:24% 7d:41% │ ✍️ terse │ 💭
💰 $2.50/$5 █████░░░░░ 50% │ 🎯 10T:$0.65 │ 🔄 7/10 │ 📝 +12/-3 │ 🎫 in:3k rd:55k wr:2k out:500
```

Claude Code が [公式に stdin へ渡す JSON](https://code.claude.com/docs/ja/statusline)(`context_window`・`effort`・`rate_limits` 等)を利用しています。行数は `CLAUDE_STATUSLINE_LINES` で切替可能(既定 `2`。`1` で従来の単一行)。狭い端末や1行に収めたい場合は `1` を指定してください。

| 行 | 項目 | 意味 | 色・絵文字の変化 |
|---|---|---|---|
| 1 | 🤖 モデル名 | 現在のモデル | — |
| 1 | ⚡ effort | 推論努力レベル(low/medium/high/xhigh/max)。**モデルが対応する場合のみ** | — |
| 1 | 🧠 ctxバー | 現在のコンテキスト / 肥大ガード閾値。`現在/上限 バー 使用率%`。公式 `context_window.current_usage` 由来 | 90%超・200k超で 🔴。「あと何%で肥大ガードが介入するか」の目安 |
| 1 | 💾 キャッシュ率 | 直近リクエストのキャッシュ読出率(高いほど安い) | 50%未満で赤(キャッシュが壊れている兆候) |
| 1 | 📊 レート制限 | 5時間 / 7日のレート制限使用率。**Claude.ai サブスク(Pro/Max)のみ** | 使用率で緑→黄→赤 |
| 1 | ✍️ 出力スタイル | 既定以外のとき表示(例 `terse`) | — |
| 1 | 💭 thinking | 拡張思考が有効なときのみ表示 | — |
| 2 | 💰 予算バー | セッションコスト / 上限。`$使用額/$上限 バー 使用率%` | 80%で ⚠️ → 超過で 🛑(バーは満杯・%は実値で超過分がわかる)。バー色 緑→黄→赤 |
| 2 | 🎯 / 🔥 ペース | 10ターン換算コスト。目標(既定 $1/10T)内なら 🎯 緑、超過なら 🔥 赤 | — |
| 2 | 🔄 ターン数 | このセッションのユーザープロンプト数。ターン上限(`CLAUDE_TURN_HARD_LIMIT`)設定時は `現在/上限` | 上限設定時は使用率で緑→黄→赤 |
| 2 | 📝 変更行数 | セッションの追加/削除行 | +緑 / -赤 |
| 2 | 🎫 トークン内訳 | 直近リクエストの `in:`新規入力(×1.0) `rd:`キャッシュ読出(×0.1) `wr:`**キャッシュ書込**(×1.25〜2) `out:`出力(×5)。既定で表示、`CLAUDE_STATUSLINE_TOKENS=0` で非表示 | — |

(「行」列は既定の2行表示での配置。`CLAUDE_STATUSLINE_LINES=1` では全項目が1行に並びます)

予算・肥大・ターンの閾値は `~/.claude/settings.json` の env(`CLAUDE_SESSION_BUDGET_USD` / `CLAUDE_CTX_LIMIT_TOKENS` / `CLAUDE_TURN_BUDGET_USD` / `CLAUDE_TURN_HARD_LIMIT`)に連動します。

> **表示が切り替わるタイミング**: statusline は Claude Code の仕様上、**新しいアシスタントメッセージの後・`/compact` 完了後・パーミッションモード変更時・vim モード切替時**にのみ再実行されます(イベント駆動)。`/model` でのモデル切替はこれらのどれにも該当しないため、**次にプロンプトを送って応答が返るまで表示が更新されません**(statusline.sh自体の不具合ではなく、Claude Code本体の仕様)。この設定では `statusLine.refreshInterval: 5`(5秒ごとの強制再実行)を有効にしており、イベントを待たずに数秒以内に反映されます。statusline はローカル実行でAPIトークンを一切消費しないため、この設定にコスト面のデメリットはありません。

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

- **毎セッション**: ステータスラインで予算バー(💰)・ctxバー(🧠)の使用率を目視。大きめの作業を頼むときは `/refine` で仕様化してから。タスクが変わったら `/handoff` → `/clear`(`/handoff` がモデル品質の引き継ぎメモを保存し、新セッションが自動検知して再開できる。書き忘れても `/clear` 時に自動スタブが保存される)
- **週次**: `/cost-audit` で設定ドリフトを検査(CLAUDE.md の肥大化、MCP サーバーの増殖は自然に起きる)

※ `.claude/handoff.md` などの一時ファイルは、project-template 同梱の `.gitignore` が除外します。
