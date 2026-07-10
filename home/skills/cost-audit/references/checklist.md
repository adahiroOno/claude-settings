# コスト監査チェックリスト

各項目: **確認方法 → 問題パターン → 推奨修正 → 期待効果**。
重要度の目安: Critical = 恒常的に数十%規模の無駄 / High = 明確な無駄 / Medium = 積み上げ・予防。

---

## A. モデル選択

### A-1. メインモデルが Opus のまま [Critical]
- 確認: `ANTHROPIC_MODEL` / settings の `model`
- 問題: Opus は Sonnet の約 1.7 倍(入力 $5 vs $3 / 1M)、出力も $25 vs $15。日常のコーディングは Sonnet で十分な品質。
- 修正: メインを Sonnet 系に。Opus は難タスク時に `/model` で一時切替する運用に。
- 効果: 単価ベースで約 40% 減。

### A-2. バックグラウンドモデル未指定 [High]
- 確認: `ANTHROPIC_DEFAULT_HAIKU_MODEL`(旧 `ANTHROPIC_SMALL_FAST_MODEL`)
- 問題: 会話タイトル生成などの補助呼び出しが高価なモデルで動くよう上書きされている、または利用環境によっては明示指定しないと解決されない。
- 修正: Haiku 系のモデルを指定する。利用環境固有のモデル ID 形式が必要な場合は、動作中のメインモデル ID と同形式・同プレフィックスの Haiku ID を使う。未確認のまま仮の ID を設定してはいけない(モデル解決エラーになる)。ID が確認できない間は未設定のままにする(他の削減策は機能する)。
- 効果: 補助呼び出しが 1/3〜1/5 の単価に。

### A-3. サブエージェントのモデル未指定 [High]
- 確認: `~/.claude/agents/*.md`, `.claude/agents/*.md` の frontmatter `model`、`CLAUDE_CODE_SUBAGENT_MODEL`
- 問題: 探索・調査系サブエージェントがメインモデルを継承している。探索はトークン量が多く、Haiku で品質がほぼ落ちない代表例。
- 修正: 読み取り専用エージェントに `model: haiku` を明示。
- 効果: 探索コスト約 1/3。

### A-4. `DISABLE_NON_ESSENTIAL_MODEL_CALLS` 未設定 [Medium]
- 確認: env
- 修正: `"DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1"` — 装飾的なモデル呼び出しを止める。

---

## B. プロンプトキャッシュ

キャッシュは**プレフィックス一致**。先頭側の1バイトの変化で以降すべてが無効化される。ヒット部は約 0.1 倍、書き込みは約 1.25 倍。TTL は 5 分。

### B-1. キャッシュ無効化フラグ [Critical]
- 確認: env に `DISABLE_PROMPT_CACHING` / `CLAUDE_CODE_DISABLE_PROMPT_CACHING` 類が入っていないか
- 問題: 過去のトラブルシュートの残骸で無効化されたまま、というのが典型。全リクエストがフルプライスになる。
- 修正: 削除。

### B-2. 動的コンテンツがプレフィックスに混入 [Critical]
- 確認: CLAUDE.md や SessionStart/UserPromptSubmit フックが、日時・ブランチ名・`git status` 出力などの**毎回変わる文字列**をコンテキスト先頭側に注入していないか
- 問題: 毎ターン、キャッシュが先頭から無効化される。「設定は正しいのにキャッシュヒットしない」場合の筆頭原因。
- 修正: 動的情報の注入をやめる。必要ならユーザーが都度プロンプトで渡す。
- 効果: キャッシュヒット率の回復(実効入力単価が最大 10 倍変わる)。

### B-3. セッション途中の MCP / モデル切替の常態化 [Medium]
- 問題: ツール定義とモデルはプレフィックス最先頭。途中で変えるとキャッシュ全滅。
- 修正: MCP 構成はセッション開始前に確定させる運用を CLAUDE.md 等に明記。

### B-4. 5分以上の放置が多い作業スタイル [Medium]
- 問題: キャッシュ TTL(5分)切れで再ウォーム(1.25倍書き込み)が頻発。
- 修正: 運用の話としてレポートに記載(長時間離席するならセッションを畳む)。

---

## C. コンテキスト最小化

### C-1. CLAUDE.md の肥大化 [High]
- 確認: `estimate_tokens.sh` で計測。目安: グローバル+プロジェクト合計で **2,000 トークン以下**を推奨、5,000 超は要ダイエット。
- 問題: CLAUDE.md は**全リクエストの入力**に乗る固定費。キャッシュが効いても 0.1 倍 × 毎回は積み上がる。
- 修正: 「常に必要な規範」だけ残し、手順書・仕様・稀にしか使わない知識は**スキル(オンデマンド読み込み)へ移す**。@import の常用も同罪(import 先も毎回読み込まれる)。

### C-2. MCP サーバーの過剰接続 [High]
- 確認: `claude mcp list`、`.mcp.json`、`~/.claude.json`
- 問題: 接続中の全サーバーの全ツール定義が毎リクエストの入力になる。使っていないサーバーが最悪。
- 修正: 使うプロジェクトだけ `.mcp.json` で有効化。グローバル常時接続をやめ、`disabledMcpjsonServers` で絞る。
- 効果: 1サーバーあたり数百〜数千トークン × 毎リクエスト。

### C-3. permissions.deny の不足 [High]
- 確認: deny に node_modules / dist / ロックファイル / *.min.js / .env 系があるか
- 問題: 誤って読むと1ファイルで数万トークン消費し、さらに**以降の全ターンでその内容がコンテキストに残り続ける**。
- 修正: 本リポジトリ `home/settings.json` の deny リストを適用。Bash 経由(`cat` 等)は `guard-heavy-read.sh` フックで補完。

### C-4. /clear・/compact の運用不在 [Medium]
- 確認: CLAUDE.md にセッション運用ルールがあるか
- 問題: 無関係な前タスクの文脈を引きずると、以降の全ターンでその分を(キャッシュ済みでも 0.1 倍で)払い続ける。
- 修正: 「タスクが変わったら /clear」をグローバル CLAUDE.md に明記。

### C-5. 探索をメインコンテキストでやっている [High]
- 確認: 読み取り専用の探索エージェント(例: `explore`)が定義され、CLAUDE.md から委譲が指示されているか
- 問題: 横断調査の中間結果(大量のファイル内容)がメインの文脈に堆積し、以降ずっと課金される。
- 修正: `agents/explore.md` を導入し、委譲ルールを CLAUDE.md に記載。

---

## D. thinking / 出力

### D-1. 常時 thinking [High]
- 確認: settings の `alwaysThinkingEnabled`、env の `MAX_THINKING_TOKENS`
- 問題: 出力トークンは入力の5倍単価。全ターン thinking は簡単なタスクで純粋な無駄。
- 修正: `alwaysThinkingEnabled: false`。難タスクのみプロンプトで思考を要求する運用。

### D-2. 出力の冗長性を抑えるルールがない [Medium]
- 確認: CLAUDE.md に「結論先行・変更箇所のみ提示・全文再掲禁止」があるか
- 修正: グローバル CLAUDE.md に3行で記載(本リポジトリの `home/CLAUDE.md` 参照)。

### D-3. `CLAUDE_CODE_MAX_OUTPUT_TOKENS` の極端な値 [Medium]
- 問題: 大きすぎは暴走時の上限がない、小さすぎは途中切断→リトライで逆に高くつく。
- 修正: 基本は未設定(デフォルト)。設定するなら 16000〜32000。

---

## E. 可視化・運用

### E-1. コストの可視化がない [Medium]
- 確認: `statusLine` 設定、OTEL テレメトリ
- 修正: `statusline.sh` 導入。チーム運用なら `CLAUDE_CODE_ENABLE_TELEMETRY=1` + OTLP エクスポート(docs/cost-optimization.md §6)。

### E-1b. セッション予算ガードの不在・閾値の形骸化 [High]
- 確認: hooks に `session-budget-guard.sh`(PreToolUse `*` + UserPromptSubmit)が配線されているか。env の `CLAUDE_SESSION_BUDGET_USD` が実態に合っているか(平均セッションコストの2〜3倍が目安。高すぎると発火せず形骸化、低すぎると日常作業が中断される)。`CLAUDE_TURN_BUDGET_USD`(目標ペース、既定 $0.10/ターン = 10ターン≒$1)も直近の実績ペース(statusline の `10T≈` 表示)と照合して較正する。
- 問題: ガードがないと「気づいたら高額セッション」を止める手段がモデルの自制しかない。
- 修正: フックを配線し、直近の `/cost` 実績から閾値を較正する。

### E-2. 設定の二重定義 [Medium]
- 確認: 同じ変数が シェル環境 / settings.json(user, project, local) / managed に重複していないか
- 問題: 優先順位(managed > CLI > local > project > user)を誤解し、「設定したのに効かない」→ 誤った方向のチューニングへ。
- 修正: 定義箇所を一本化(推奨: ユーザー共通は `~/.claude/settings.json`、プロジェクト固有は `.claude/settings.json`)。

### E-2b. 常駐メモリによる再開運用 [Medium]
- 確認: CLAUDE.md やメモリファイルに「前回作業の続き」系の内容が恒常的に追記されていないか。SessionStart 系フックが大きなコンテキストを毎セッション注入していないか。
- 問題: 再開用メモの常駐化は毎リクエストの固定費になり、肥大化も進む。
- 修正: ハンドオフ方式へ移行(`.claude/handoff.md` + `handoff-notice.sh`。docs/cost-optimization.md §6)。CLAUDE.md に溜まった作業メモは削除する。

### E-3. autocompact を無効化している [Medium]
- 問題: コンテキスト溢れ間際の劣化・やり直しの方が高くつく。
- 修正: 有効のまま。長いタスクの区切りで手動 `/compact` も可。
