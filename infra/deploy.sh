#!/usr/bin/env bash
# デプロイ用スクリプト。提出用リポジトリでは GitHub Actions が使えないため、手元から実行する。
#
#   bash infra/deploy.sh api     … api/ を Cloud Run にデプロイ
#   bash infra/deploy.sh web     … web/ をビルドして Firebase Hosting にデプロイ
#   bash infra/deploy.sh rules   … Firestore / Storage のルールとインデックス
#   bash infra/deploy.sh all     … 上の 3 つすべて
#
# リポジトリの直下で実行する。Windows の PowerShell では WSL の bash ではなく Git Bash を使う：
#   & "C:\Program Files\Git\bin\bash.exe" infra/deploy.sh api
#
# デモ当日（11/14・11/27）はコールドスタートを避けるため、常時 1 台起動しておく：
#   MIN_INSTANCES=1 bash infra/deploy.sh api    （終わったら MIN_INSTANCES なしで再デプロイして 0 に戻す）
#
# 費用が想定を超えたときに投稿・AI 処理を止める（フィードの閲覧は動いたまま）：
#   POSTS_ENABLED=false bash infra/deploy.sh api
set -euo pipefail

PROJECT=devfest-hackathon-holders
REGION=asia-northeast1
SA="api-runner@${PROJECT}.iam.gserviceaccount.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Secret Manager から環境変数として渡すもの。「環境変数名=シークレット名:latest」をカンマ区切りで書く
# 値そのものはリポジトリにも gcloud の引数にも書かない。シークレットを足したら infra/setup.sh の API_SECRETS にも足す
SECRETS=""

deploy_api() {
  # api/ に Dockerfile か、Buildpacks が認識できる構成（package.json / requirements.txt など）を置く
  local secret_args=()
  [[ -n "$SECRETS" ]] && secret_args=(--set-secrets "$SECRETS")

  # --timeout 60：Firebase Hosting 経由のリクエストは 60 秒で打ち切られるため、それ以上待たない
  gcloud run deploy api \
    --project "$PROJECT" --region "$REGION" \
    --source "$ROOT/api" \
    --service-account "$SA" \
    --allow-unauthenticated \
    --min-instances "${MIN_INSTANCES:-0}" --max-instances 3 \
    --concurrency 20 --timeout 60 \
    --cpu-boost --memory 512Mi --cpu 1 \
    --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT},GOOGLE_CLOUD_LOCATION=${REGION},POSTS_ENABLED=${POSTS_ENABLED:-true}" \
    ${secret_args[@]+"${secret_args[@]}"}
}

deploy_web() {
  # web/ は Next.js の静的書き出し（next.config の output: 'export'）で out/ を作る
  (cd "$ROOT/web" && npm ci && npm run build)
  (cd "$ROOT" && firebase deploy --project "$PROJECT" --only hosting --non-interactive)
}

deploy_rules() {
  (cd "$ROOT" && firebase deploy --project "$PROJECT" --only firestore,storage --non-interactive)
}

case "${1:-}" in
  api)   deploy_api ;;
  web)   deploy_web ;;
  rules) deploy_rules ;;
  all)   deploy_rules; deploy_api; deploy_web ;;
  *) echo "usage: bash $0 {api|web|rules|all}" >&2; exit 1 ;;
esac
