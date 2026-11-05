#!/usr/bin/env bash
# デプロイ用スクリプト。提出用リポジトリでは GitHub Actions が使えないため、手元から実行する。
#
#   ./infra/deploy.sh api     … api/ を Cloud Run にデプロイ
#   ./infra/deploy.sh web     … web/ をビルドして Firebase Hosting にデプロイ
#   ./infra/deploy.sh rules   … Firestore / Storage のルールとインデックス
#   ./infra/deploy.sh all     … 上の 3 つすべて
#
# デモ当日（11/14・11/27）はコールドスタートを避けるため、常時 1 台起動しておく：
#   MIN_INSTANCES=1 ./infra/deploy.sh api    （終わったら MIN_INSTANCES なしで再デプロイして 0 に戻す）
set -euo pipefail

PROJECT=devfest-hackathon-holders
REGION=asia-northeast1
SA="api-runner@${PROJECT}.iam.gserviceaccount.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

deploy_api() {
  # api/ に Dockerfile か、Buildpacks が認識できる構成（package.json / requirements.txt など）を置く
  # 秘密情報は環境変数ではなく Secret Manager から渡す（--set-secrets）
  gcloud run deploy api \
    --project "$PROJECT" --region "$REGION" \
    --source "$ROOT/api" \
    --service-account "$SA" \
    --allow-unauthenticated \
    --min-instances "${MIN_INSTANCES:-0}" --max-instances 3 \
    --cpu-boost \
    --memory 512Mi --cpu 1 \
    --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT},GOOGLE_CLOUD_LOCATION=${REGION}"
}

deploy_web() {
  # web/ は Next.js の静的書き出し（next.config の output: 'export'）で out/ を作る
  (cd "$ROOT/web" && npm ci && npm run build)
  (cd "$ROOT" && firebase deploy --project "$PROJECT" --only hosting)
}

deploy_rules() {
  (cd "$ROOT" && firebase deploy --project "$PROJECT" --only firestore,storage)
}

case "${1:-}" in
  api)   deploy_api ;;
  web)   deploy_web ;;
  rules) deploy_rules ;;
  all)   deploy_rules; deploy_api; deploy_web ;;
  *) echo "usage: $0 {api|web|rules|all}" >&2; exit 1 ;;
esac
