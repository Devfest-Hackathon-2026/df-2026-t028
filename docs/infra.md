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
| `spots/{spotId}` | スポット情報、`embedding`（768 次元）、知名度 `fame`（0〜1） | 読み取りのみ |
| `posts/{postId}` | 地元民の投稿。`status: 'published'` のものだけ公開 | 公開済みのみ読み取り |
| `users/{uid}/...` | いいね履歴など | 本人だけ読み書き |
| Storage `spots/**` | スポットの写真・動画 | 読み取りのみ |
| Storage `posts/{uid}/*` | 投稿写真（画像のみ・10MB まで） | 本人だけアップロード、読み取りは公開 |

書き込みは原則 Cloud Run の API が行う。投稿は「アップロード → API が Gemini で構造化・チェック → `published` にする」の流れで、チェック前の投稿はクライアントから見えない。

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
- 理由：既定の SA は「編集者」相当の広い権限を持つ。api-runner には Vertex AI・Firestore・Storage・Secret Manager・ログ書き込みの 5 つだけを付けた

**秘密情報は Secret Manager**
- 理由：提出用リポジトリは公開。Places API キーなどはリポジトリにも Cloud Run の環境変数にも直接書かない

**CI/CD は作らず、`infra/deploy.sh` で手元からデプロイ**
- 理由：提出用リポジトリでは GitHub Actions が使えない。6 日間の開発でパイプラインを組む手間に見合わない
- デメリット：デプロイする人の手元に gcloud / firebase CLI とログインが必要

## 補足

- Firebase の Web 用設定（`apiKey` など）は秘密情報ではない。ブラウザに配る前提の値で、アクセス制御はルールで行う
- デプロイ URL は 11/14（Regional Day）まで動かし続ける。クレジット残額をこまめに確認する
