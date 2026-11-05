#!/usr/bin/env bash
# Google Cloud / Firebase の初期構築（11/5 に実施済み）。
# 何をどう作ったかの記録を兼ねる。作り直すときもこのまま実行できる（作成済みのものはエラーになるだけ）。
#
# 前提：gcloud と firebase CLI でログイン済み、プロジェクトに課金アカウントがリンク済み
# 手作業で行ったもの（API では元に戻せない／規約同意が必要なため）：
#   - Firebase コンソールでの規約同意と、既存プロジェクトへの Firebase 追加
#   - Authentication の初期化と「匿名」ログインの有効化
#   - 予算アラート（月 ¥1,500、50/90/100/150%）
set -euo pipefail

PROJECT=devfest-hackathon-holders
REGION=asia-northeast1
SA_NAME=api-runner
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

# 1. 使う API を有効化
gcloud services enable --project "$PROJECT" \
  run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com iam.googleapis.com aiplatform.googleapis.com \
  firestore.googleapis.com places.googleapis.com billingbudgets.googleapis.com \
  firebasestorage.googleapis.com firebasehosting.googleapis.com \
  identitytoolkit.googleapis.com apikeys.googleapis.com

# 2. Firestore（Native モード、東京）
gcloud firestore databases create --project "$PROJECT" \
  --database="(default)" --location="$REGION" --type=firestore-native || true

# 3. Firebase Storage のデフォルトバケット（東京）
curl -sf -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: $PROJECT" -H "Content-Type: application/json" \
  "https://firebasestorage.googleapis.com/v1alpha/projects/$PROJECT/defaultBucket" \
  -d "{\"location\":\"${REGION^^}\",\"storageClass\":\"STANDARD\"}" || true

# 4. Cloud Run（API）専用のサービスアカウント。必要な権限だけを付ける
gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT" \
  --display-name="Cloud Run API runtime" || true
for role in roles/aiplatform.user roles/datastore.user roles/storage.objectAdmin \
            roles/secretmanager.secretAccessor roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" --role="$role" --condition=None --quiet --format=none
done

# 5. Firestore のルール・ベクトルインデックス、Storage のルール
firebase deploy --project "$PROJECT" --only firestore,storage
