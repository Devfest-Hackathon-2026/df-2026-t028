#!/usr/bin/env bash
# Google Cloud / Firebase の初期構築。11/5 に実施した内容の記録を兼ねる。
# 何度実行しても同じ状態になる（作成済みのものは確認して飛ばす。それ以外の失敗ではその場で止まる）。
#
# 実行：bash infra/setup.sh
#
# 前提：gcloud と firebase CLI でログイン済みで、プロジェクトのオーナー権限があること。課金アカウントがリンク済みであること
# 手作業で行ったもの（API では元に戻せない／規約同意が必要なため）：
#   - Firebase コンソールでの規約同意と、既存プロジェクトへの Firebase 追加
#   - Authentication の初期化と「匿名」ログインの有効化
#   - 予算アラート（月 ¥1,500、50/90/100/150%）。通知だけで、課金は止まらない
set -euo pipefail

PROJECT=devfest-hackathon-holders
REGION=asia-northeast1
BUCKET="${PROJECT}.firebasestorage.app"
SA_NAME=api-runner
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Cloud Run の API が読むシークレット。作ったらここに名前を足して再実行する（そのシークレットにだけ読み取り権限が付く）
API_SECRETS=()

log() { echo "== $*"; }

# 1. 使う API を有効化（有効化済みでもエラーにならない）
log "API を有効化"
gcloud services enable --project "$PROJECT" \
  run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com iam.googleapis.com aiplatform.googleapis.com \
  firestore.googleapis.com places.googleapis.com billingbudgets.googleapis.com \
  firebasestorage.googleapis.com firebasehosting.googleapis.com \
  identitytoolkit.googleapis.com apikeys.googleapis.com

# 2. Firestore（Native モード、東京）
if gcloud firestore databases describe --project "$PROJECT" --database="(default)" >/dev/null 2>&1; then
  log "Firestore は作成済み"
else
  log "Firestore を作成"
  gcloud firestore databases create --project "$PROJECT" \
    --database="(default)" --location="$REGION" --type=firestore-native
fi

# 3. Firebase Storage のデフォルトバケット（東京）と、審査前の写真を 1 日で消すライフサイクル
if gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  log "Storage バケットは作成済み"
else
  log "Storage バケットを作成"
  curl -sSf -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "x-goog-user-project: $PROJECT" -H "Content-Type: application/json" \
    "https://firebasestorage.googleapis.com/v1alpha/projects/$PROJECT/defaultBucket" \
    -d "{\"location\":\"$(echo "$REGION" | tr '[:lower:]' '[:upper:]')\",\"storageClass\":\"STANDARD\"}"
fi
log "uploads/ を 1 日で削除するライフサイクルを設定"
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file="$ROOT/infra/storage-lifecycle.json"

# 4. Cloud Run（API）専用のサービスアカウント
if gcloud iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1; then
  log "サービスアカウントは作成済み"
else
  log "サービスアカウントを作成"
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT" \
    --display-name="Cloud Run API runtime"
fi

# 5. 権限。リソース単位で付けられるものは、そのリソースにだけ付ける
#    - プロジェクト単位：Vertex AI の呼び出し、Firestore の読み書き、ログ書き込み
#    - バケット単位：Storage（uploads/ の読み取りと public/ へのコピー）
#    - シークレット単位：API_SECRETS に挙げたものだけ
log "プロジェクト単位の権限"
for role in roles/aiplatform.user roles/datastore.user roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" --role="$role" --condition=None --quiet --format=none
done

log "バケット単位の権限"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$SA" --role=roles/storage.objectAdmin --format=none

for secret in ${API_SECRETS[@]+"${API_SECRETS[@]}"}; do
  log "シークレット $secret の読み取り権限"
  gcloud secrets add-iam-policy-binding "$secret" --project "$PROJECT" \
    --member="serviceAccount:$SA" --role=roles/secretmanager.secretAccessor --format=none
done

# 以前プロジェクト単位で付けていた権限が残っていれば外す
project_roles="$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten="bindings[].members" \
  --filter="bindings.members=serviceAccount:$SA" \
  --format="value(bindings.role)")"
for role in roles/storage.objectAdmin roles/secretmanager.secretAccessor; do
  if grep -qx "$role" <<<"$project_roles"; then
    log "プロジェクト単位の $role を削除"
    gcloud projects remove-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:$SA" --role="$role" --condition=None --quiet --format=none
  fi
done

# 6. Firestore のルール・ベクトルインデックス、Storage のルール
log "ルールとインデックスを反映"
(cd "$ROOT" && firebase deploy --project "$PROJECT" --only firestore,storage --non-interactive)

log "完了"
