# API 仕様

11/5 にフロント担当・API 担当と合意。フロント（`web/`）と API（`api/`）の約束ごと。**この形で合意したら、フロントは `docs/mocks/` の JSON で先に画面を作り、API は同じ形を返すように実装する。** 変えるときは、このファイルを先に直してから両方を直す。

- ベース URL：`/api`（Firebase Hosting が Cloud Run に転送する。同じドメインなので CORS 不要）
- 認証：匿名ログインの ID トークンを `Authorization: Bearer <idToken>` で送る。API はトークンから `uid` を取り出し、いいね履歴を読む
- 形式：JSON、文字コード UTF-8、日時は ISO 8601（`+09:00`）
- **月・時間帯は日本時間で扱う**

## 共通の約束

### 事実には必ず出典と更新日を付ける
営業時間・料金・アクセス・混みやすさなど、**事実の情報は `Fact` の形で返す**。画面では本文の下に出典と更新日を小さく出す。Gemini が作った文（投稿の要約・英訳）は事実として扱わない。

```jsonc
// Fact
{
  "text_ja": "9:00〜17:00（受付は16:30まで）",
  "text_en": "9:00–17:00 (last entry 16:30)",   // なければ null
  "source": { "label": "公式サイト", "url": "https://example.jp/" },
  "updated_at": "2026-11-04"
}
```

### 時間帯と混みやすさの段階
- 時間帯は 4 つ：`朝`（6〜10時）・`昼`（10〜15時）・`夕方`（15〜18時）・`夜`（18時〜）。投稿の構造化（PoC①）と同じ区切り
- 混みやすさは 5 段階の数値 `1`〜`5`。表示ラベルは次のとおり。分からないときは `null`（推測で埋めない）

| 値 | ラベル |
|---|---|
| 1 | とても空いている |
| 2 | 空いている |
| 3 | 普通 |
| 4 | 混んでいる |
| 5 | とても混んでいる |

---

## GET `/api/feed` — フィード

縦スワイプのフィードを 5 件ずつ返す。残り 2 件になったら `next_cursor` で次を取る。

**推薦に地域の絞り込みは付けない。** このアプリは旅行先を選ぶ段階で使うので、京都の名所を見ている人に島根の穴場を出してよい（行き先そのものを差し替える）。都道府県・距離での制限や並べ替えはしない。

| パラメータ | 必須 | 説明 |
|---|---|---|
| `lambda` | ○ | スライダーの値。`-1.0`（Famous 側）〜 `2.0`（Hidden Gems 側）。変えたら `cursor` を付けずに取り直す |
| `cursor` |  | 前回の `next_cursor`。中身は API だけが解釈する文字列 |
| `limit` |  | 件数。既定 5、最大 10 |
| `month` |  | 1〜12。混みやすさ・見頃をどの月で判定するか。省略時は今月（デモで季節を切り替えるため） |
| `time_of_day` |  | `朝`/`昼`/`夕方`/`夜`。省略時は今の時間帯 |
| `seed` |  | 起点にするスポットの id。いいね履歴がない最初の 1 回だけ使う |

### レスポンス

```jsonc
{
  "items": [ /* FeedItem の配列。下の 3 種類が混ざる */ ],
  "next_cursor": "eyJvIjo1fQ",      // もう無ければ null
  "context": { "lambda": 0.8, "month": 11, "time_of_day": "昼" }
}
```

### FeedItem（`type` で 3 種類）

**① 通常のスポット**
```jsonc
{ "type": "spot", "spot": SpotCard }
```

**② 「代わりにここ」カード**（有名スポットの直後に入る）
```jsonc
{
  "type": "alternative",
  "for_spot_id": "fushimi_inari",                 // 直前の有名スポット
  "reason": {
    "shared_tags": ["朱色", "鳥居", "山道"],       // 画面に「似ているところ」として出す
    "similarity": 0.83                            // 0〜1。画面には出さなくてよい
  },
  "spot": SpotCard
}
```

**③ 地元民の投稿**（Gemini のチェックを通ったものだけ）
```jsonc
{ "type": "post", "post": PostCard }
```

### SpotCard（フィードの 1 枚に必要な分だけ）

```jsonc
{
  "id": "takenaka_inari",
  "name": "竹中稲荷社",
  "kind": "hidden",                       // "famous" | "hidden"
  "pref": "京都府",
  "city": "京都市左京区",
  "media": [                               // 先頭が表紙。先読みはこの先頭だけ
    {
      "type": "image",                     // "image" | "video"
      "url": "/media/takenaka_inari.jpg",
      "poster": null,                      // 動画のときの静止画
      "width": 1080, "height": 1440,
      "credit": { "author": "Taro", "license": "CC BY-SA 4.0", "source_url": "https://commons.wikimedia.org/..." }
    }
  ],
  "mood_tags": ["朱色", "鳥居", "静か", "森"],
  "now": {                                 // 指定した月・時間帯での状態。カード上のバッジに使う
    "in_season": true,                     // その月が見頃か
    "season_label": "紅葉",                // 見頃のときだけ。なければ null
    "crowd_level": 1,                      // 1〜5 / null
    "crowd_source": "user_reports"         // "official_trend" | "user_reports" | null
  }
}
```

- `embedding` と知名度の数値（`fame`）は**返さない**。推薦の内部でだけ使う
- `media.credit` は CC BY / BY-SA の写真で表示が必須。詳細画面だけでなく、カードの隅にも小さく出す

### PostCard

```jsonc
{
  "id": "p_01H...",
  "spot_id": "takenaka_inari",            // スポットに結び付かなければ null
  "photo_url": "https://firebasestorage.googleapis.com/...",
  "summary_ja": "11月の朝はほぼ誰もいなかった。鳥居の朱色と紅葉が重なってきれい。",
  "summary_en": "Almost empty on a November morning. The vermilion gates and autumn leaves look beautiful together.",
  "mood_tags": ["朱色", "紅葉", "静か"],
  "visited_month": 11,                    // 投稿に書かれていなければ null
  "visited_time_of_day": "朝",            // 同上
  "crowd_level": 1,                       // 同上
  "label": "投稿者の体験",                 // 公式情報と区別するための表示。固定文言
  "created_at": "2026-11-06T09:12:00+09:00"
}
```

---

## GET `/api/spots/{id}` — スポット詳細

カードをタップしたとき、または下から引き出すシートで使う。フィードより重い情報（混雑表・営業情報）はこちらだけで返す。

```jsonc
{
  "spot": {
    /* SpotCard の項目すべて ＋ 以下 */
    "description_ja": "小さな山の中腹にある稲荷社。…",
    "description_en": "A small Inari shrine halfway up a hill. …",

    "location": {
      "lat": 35.0262, "lng": 135.7887,
      "address": Fact,                      // 所在地
      "access": Fact,                       // 最寄り駅・バス停からの行き方
      "maps_url": "https://www.google.com/maps/search/?api=1&query=35.0262,135.7887"
    },

    "info": {
      "hours": Fact,                        // 営業・拝観時間。不明なら null
      "fee": Fact                           // 料金。不明なら null
    },

    "season": {
      "best_months": [4, 11],
      "highlights": [
        { "months": [4], "label_ja": "桜", "label_en": "Cherry blossoms" },
        { "months": [11], "label_ja": "紅葉", "label_en": "Autumn leaves" }
      ],
      "source": { "label": "公式サイト", "url": "https://example.jp/" },
      "updated_at": "2026-11-04"
    },

    "crowd": {
      "kind": "official_trend",             // 名所：公開情報を手で整理 / 穴場："user_reports"
      "time_bands": ["朝", "昼", "夕方", "夜"],
      "by_month": {                         // 月 → 時間帯ごとの 1〜5。分からない月・時間帯は null
        "11": [2, 5, 4, null],
        "12": [1, 3, 2, null]
      },
      "report_count": null,                 // user_reports のときの投稿件数
      "source": { "label": "京都観光快適度マップの傾向を整理", "url": "https://..." },
      "updated_at": "2026-11-04"
    },

    "recent_posts": [ PostCard ],           // 新しい順に最大 5 件
    "booking_url": null                     // Trip.com のリンク。運営の可否確認が済むまで null
  }
}
```

---

## POST `/api/posts` — 地元民の投稿

写真は先にクライアントが Storage の `posts/{uid}/{ファイル名}` に直接アップロードし、そのパスを送る。

```jsonc
// リクエスト
{ "text": "吉田山の竹中稲荷、11月の朝に行ったらほぼ誰もいなかった。", "photo_path": "posts/AbC123/1730790000.jpg" }

// レスポンス 201（チェックを通ったとき）
{ "status": "published", "post": PostCard }

// レスポンス 200（不適切と判定されたとき。フィードには出ない）
{ "status": "rejected", "reason": "宣伝・勧誘の内容が含まれています" }
```

Gemini の構造化に数秒かかるので、フロントは送信後に「確認中…」を出す。

---

## いいね

API を通さず、クライアントが Firestore に直接書く（押した瞬間に反映するため）。

- 追加：`users/{uid}/likes/{spotId}` に `{ "created_at": serverTimestamp() }`
- 取り消し：同じドキュメントを削除
- API はフィードを作るとき、新しい順に 10 件を読んで `u`（好みのベクトル）を作る

---

## エラー

```jsonc
// 4xx / 5xx 共通
{ "error": { "code": "INVALID_ARGUMENT", "message": "lambda は -1.0〜2.0 で指定してください" } }
```

| HTTP | code | 例 |
|---|---|---|
| 400 | `INVALID_ARGUMENT` | パラメータの範囲外 |
| 401 | `UNAUTHENTICATED` | ID トークンがない・期限切れ（フロントは取り直して 1 回だけ再送） |
| 404 | `NOT_FOUND` | スポットがない |
| 500 | `INTERNAL` | それ以外 |
