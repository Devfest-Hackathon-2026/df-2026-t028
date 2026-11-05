# インフラ構成

## 全体

```
ブラウザ（Next.js 静的書き出し）
   │  https://devfest-hackathon-holders.web.app
   ▼
Firebase Hosting ── /api/** を転送 ──▶ Cloud Run「api」（asia-northeast1）
   │                                         │  サービスアカウント api-runner
   │ 匿名ログイン・写真アップロード            ├─▶ Vertex AI（Gemini / Gemini Embedding）
   ▼                                         ├─▶ Firestore（spots / posts、ベクトル検索）
Firebase Auth / Cloud Storage                └─▶ Secret Manager（Places API キーなど）
```

| リソース | 値 |
|---|---|
| プロジェクト | `devfest-hackathon-holders` |
| リージョン | `asia-northeast1`（東京）に統一 |
| Firestore | `(default)`、Native モード |
| ベクトルインデックス | `spots.embedding`、768 次元（flat）。検索時は COSINE を指定 |
| Storage バケット | `devfest-hackathon-holders.firebasestorage.app` |
| Cloud Run のサービスアカウント | `api-runner@devfest-hackathon-holders.iam.gserviceaccount.com` |
| 予算アラート | 月 ¥1,500（50 / 90 / 100 / 150%） |

## データの置き場所

| パス | 中身 | クライアントから |
|---|---|---|
| パス | 中身 | クライアントから |
|---|---|---|
| Firestore `spots/{spotId}` | スポット情報、`embedding`（768 次元）、知名度 `fame`（0〜1） | **不可**（API 経由のみ） |
| Firestore `posts/{postId}` | 地元民の投稿 | **不可**（API 経由のみ） |
| Firestore `users/{uid}/likes/{spotId}` | いいね。`created_at` だけ | 本人だけ読み取り・作成・削除 |
| Storage `uploads/{uid}/*` | 審査前の投稿写真（JPEG/PNG/WebP、10MB まで）。**1 日で自動削除** | 本人だけアップロード・読み取り |
| Storage `public/**` | 承認済みの投稿写真（API がコピー） | 読み取りのみ |
| Hosting `/media/**` | 初期データの写真・動画（`web/public/media/`） | 読み取りのみ（CDN） |

Firestore でクライアントが直接扱えるのは、自分のいいねだけ。`spots` には埋め込みなど内部用の値があり、Firestore のルールではドキュメント内の項目単位で隠せないため、読み取りも API に統一した。

投稿写真は審査前に公開しない。「`uploads/` にアップロード → API が Gemini でチェック → 通ったら API が `public/posts/` にコピー」の流れで、却下・未送信の写真は `uploads/` に残ったまま 1 日後に消える。

## 選定理由

**Firebase Hosting ＋ Cloud Run（API）に分ける**
- 理由：画面は静的ファイルで足り、推薦と投稿処理だけサーバーが要る。Hosting の rewrite で `/api/**` を Cloud Run に流すので、URL が 1 つになり CORS の設定が要らない
- 捨てた案：Firebase App Hosting（Next.js の SSR が使えるが、GitHub 連携が前提で、提出用リポジトリは外部連携が制限されている。SSR も今回は不要）
- デメリット：Next.js のサーバー機能（SSR、API Routes）は使えない。API はすべて Cloud Run 側に書く

**Cloud Run は min-instances 0、max-instances 3**
- 理由：クレジットが $20 しかない。アクセスがない間は課金されない
- デメリット：最初のリクエストで数秒のコールドスタートがある。デモ直前に一度アクセスして温めておく

**書き込みを API に集約し、クライアントは読み取り中心**
- 理由：投稿は Gemini の不適切チェックを通してから公開したい。クライアントが直接書けると、チェックを飛ばせてしまう
- デメリット：書き込みのたびに API を経由するので、実装がやや増える

**専用サービスアカウント（既定の Compute SA を使わない）**
- 理由：既定の SA は「編集者」相当の広い権限を持つ。api-runner には必要な権限だけを、**付けられる最小の範囲**に付けた
  - プロジェクト単位：Vertex AI ユーザー、Cloud Datastore ユーザー、ログ書き込み（リソース単位で付けられないもの）
  - バケット単位：Storage オブジェクト管理者（投稿写真のバケットだけ）
  - シークレット単位：Secret Manager のシークレット アクセサー（API が使うシークレットだけ。プロジェクト単位にすると全シークレットを読めてしまう）

**秘密情報は Secret Manager**
- 理由：提出用リポジトリは公開。Places API キーなどはリポジトリに書かず、Cloud Run にも平文の環境変数としては設定しない。Secret Manager に置き、`--set-secrets` で参照して渡す（`infra/deploy.sh` の `SECRETS`）

**費用は「通知」と「上限」の 2 段で抑える**
- 予算アラートは通知だけで課金は止まらない。そのため API 側で投稿回数・Gemini 呼び出し回数に日ごとの上限を設け、超えたら `429` / `503` を返す（`docs/api.md` の「利用量の上限」）
- アラートが来たらインフラ担当が内訳を確認し、必要なら `POSTS_ENABLED=false` で投稿と AI 処理だけを止める。フィードの閲覧は動いたままにする

**CI/CD は作らず、`infra/deploy.sh` で手元からデプロイ**
- 理由：提出用リポジトリでは GitHub Actions が使えない。6 日間の開発でパイプラインを組む手間に見合わない
- デメリット：デプロイする人の手元に gcloud / firebase CLI とログインが必要

## 補足

- Firebase の Web 用設定（`apiKey` など）は秘密情報ではない。ブラウザに配る前提の値で、アクセス制御はルールで行う
- デプロイ URL は **11/14（Regional Day）まで必ず**動かし続ける。決勝に進んだら **11/27（Demo Day）・11/29（DevFest Tokyo 展示）まで**延長する。その間、インフラ担当が毎日、クレジット残額と URL の動作を確認する
- スクリプトの実行は `bash infra/setup.sh` / `bash infra/deploy.sh ...`（実行権限も付けてあるので `./infra/...` でも可）

## 未決事項

| 内容 | 担当 | 期限 |
|---|---|---|
| Places API の利用規約の確認：取得したデータのうち何を保存してよいか（`place_id` は保存できるが、レビュー件数など他の項目は同じ扱いではない）。レビュー件数から作った知名度 `fame` を保存してよいか。表示しない場合も帰属表示が要るか | インフラ担当 | 11/6 |
| Trip.com など外部の予約サイトへのリンクを置いてよいか（運営に Discord で確認） | インフラ担当 | 11/6 |
