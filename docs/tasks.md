# 4人の分担

決め方：**API仕様（`docs/api.md`）とモック（`docs/mocks/`）を先に固定し、各自がそれだけを見て並行して作る。** 変えるときは `docs/api.md` を先に直し、全員に連絡する。

| 項目 | 決定 |
|---|---|
| 対象エリア | 全国（`data/spots_japan.json`、38件から増やす） |
| フロント | `web/`、Next.js の静的書き出し（TypeScript 推奨） |
| API | `api/`、Python（FastAPI）、Cloud Run |
| 言語 | 日本語が主、英語はサブ（`text_en` / `summary_en`） |
| 環境 | GCP `devfest-hackathon-holders`、東京。3人に「編集者」付与済み |
| ログイン | 各自 `gcloud auth application-default login`。鍵ファイルは作らない |

## 担当一覧

| 担当 | 範囲 | フォルダ |
|---|---|---|
| **インフラ・通信**（kentaro） | 環境、デプロイ、費用、API仕様の管理、提出 | `infra/` `docs/` |
| **A フロント** | 画面すべて | `web/` |
| **B 推薦API** | フィード・スポット詳細API、ベクトル検索 | `api/` |
| **C データ・投稿** | スポットデータ、知名度、投稿のAI処理 | `data/` `tools/` `api/`（投稿部分） |

B と C は同じ `api/` を触る。ファイルを分けて衝突を避ける（B：`feed.py` `spots.py`、C：`posts.py` `gemini.py`）。

---

## インフラ・通信（kentaro）

初日（最優先、他の3人を止めないため）
- [ ] `web/` と `api/` の空の雛形を置き、**「Hello」でも本番URLに出す**（`infra/deploy.sh web` / `api`）
- [ ] Firebaseの Web 用設定をAに渡す（秘密ではない）
- [ ] Hostingの `/api/**` → Cloud Run 転送の動作確認
- [ ] 3人が Firestore / Vertex AI / Storage を手元から触れることを確認

随時
- [ ] 他の3人のGitHub招待、ブランチの運用を決める（`main` 直push禁止、PRでレビュー）
- [ ] 秘密情報の扱い（Places APIキー等は Secret Manager。`API_SECRETS` と `SECRETS` に追記）
- [ ] 利用量の上限の実装確認（投稿10回/日、Gemini 500回/日。実装は B/C、確認は自分）
- [ ] 毎日：クレジット残額と本番URLの動作確認
- [ ] 11/6：Trip.com 等の予約リンクを置いてよいか、運営に確認
- [ ] 提出：開発用リポジトリから提出用リポジトリへ最終版を push（秘密情報を履歴に含めない）
- [ ] デモ前：`MIN_INSTANCES=1` で常時起動、終了後に戻す

## A フロント

モック（`docs/mocks/feed.json` `spot.json` `posts.json`）で先に作る。APIの完成を待たない。

- [ ] 縦スワイプのフィード（5件ずつ、残り2件で `next_cursor` を取得）
- [ ] 3種類のカード：`spot` / `alternative`（「代わりにここ」、`shared_tags` を表示）/ `post`
- [ ] Famous ↔ Hidden Gems のスライダー（`lambda` -1.0〜2.0。変えたら cursor なしで取り直す）
- [ ] 月・時間帯の切り替え（デモで季節を変える用）
- [ ] スポット詳細シート（営業時間・料金は `Fact` で出典と更新日を小さく表示、混雑表）
- [ ] 写真の `credit`（CC BY / BY-SA は表示必須）をカードの隅に表示
- [ ] 投稿画面：匿名ログイン → `uploads/{uid}/` に写真アップロード → `POST /api/posts`（`Idempotency-Key` はUUID）。`rejected`・`429`・`503` の表示
- [ ] いいね：Firestoreの `users/{uid}/likes/{spotId}` に直接書く（それ以外は直接読まない）
- [ ] 英語表示の切り替え（サブ）

## B 推薦API

- [ ] FastAPI の骨格、匿名ログインのIDトークン検証、共通エラー形式（`docs/api.md` の「エラー」）
- [ ] `GET /api/feed`：Firestoreのベクトル検索で20件 → `visitable != true` と近さ不足を除外 → `Score = 近さ − α×λ×F` で並べ替え。有名スポットの直後に `alternative` を挿入
- [ ] いいね10件から好みのベクトル `u` を作る（無いときは `seed`）
- [ ] `GET /api/spots/{id}`：SpotCard + 詳細（`Fact`、`season`、`crowd`、`recent_posts`）
- [ ] `embedding` と `fame` の数値は返さない、`fame_band` だけ返す
- [ ] 最初はモックと同じ形の固定JSONを返し、Aが動かせる状態にする → 順次本物に置き換え
- [ ] 確認：λを穴場側に動かすとFが下がるか、未判定が上位に出ないか

## C データ・投稿

- [ ] `data/spots_japan.json` を30〜50件に増やす（有名と穴場のペア、`visitable`、`season`、`crowd`、`Fact` の出典）
- [ ] 写真の収集と `credits.csv` の確認（`data/collect_commons.py`、「要確認」が yes のものは目で見る）
- [ ] 知名度 F：`tools/fetch_fame.py` を実行、スポットを足したら全件を再計算（順位値は集合で変わる）
- [ ] スポットの埋め込み（768次元）を作って Firestore の `spots` に投入するスクリプト
- [ ] `POST /api/posts`：Gemini で構造化・英訳・不適切チェック（20秒で打ち切り、全体30秒以内）。書かれていない月・混雑を推測で埋めない
- [ ] 通ったら `uploads/` から `public/posts/` に写真をコピーして保存。`Idempotency-Key` は24時間保持
- [ ] 利用量の上限：投稿 1人10回/日・1回/30秒、全体200回/日、Gemini全体500回/日
- [ ] PoCのコードは流用しない（本番は新規に書く）。作り直すこと

---

## 日程の目安

| 日 | インフラ | A | B | C |
|---|---|---|---|---|
| 11/5（今日） | 本番に Hello、環境共有 | モックで画面を作り始める | 骨格＋固定JSON | データ増やす、Fの再計算 |
| 11/6 | 予約リンク確認、上限の確認 | フィード＋スライダー | feed（ベクトル検索） | 埋め込み投入 |
| 11/7 | 結合確認 | 詳細シート | spots詳細 | POST /posts |
| 11/8 | 結合確認 | 投稿画面 | 調整 | 調整 |
| 11/9 | 全員で結合、バグ出し | | | |
| 11/10 | 提出準備、デモ練習 | | | |

提出期限と Regional Day（11/14）の時刻は運営の案内で確認し、上の表を直す。
