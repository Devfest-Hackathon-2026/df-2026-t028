"""Wikipedia の閲覧数から知名度 F（0〜1）を作り、人が付けた有名／穴場の分類と比べて評価する。

使い方（標準ライブラリだけで動く）：
    python tools/fetch_fame.py --data data/spots_japan.json --out data/fame.json

記事が見つからない・曖昧さ回避ページに当たったスポットは、出力の evaluation.needs_review に
検索の候補が出る。正しい記事を選んで、スポットデータに "wiki_ja": "記事名" を足して再実行する。
スポットの一部だけを扱う記事しかない場合（例：境内の一部が寺全体の記事に含まれる）は、
寺全体の閲覧数で過大になるので、記事なし（閲覧数 0）のままにするか、チームで扱いを決める。

やること：
1. スポット名（または wikidata の ID）から、日本語版・英語版 Wikipedia の記事を特定する（Wikidata 経由）
2. 直近 12 か月の閲覧数（人による閲覧のみ、全デバイス）を記事ごとに取得し、日英を合計する
3. 判定できたスポットの中での閲覧数の順位値を知名度 F（0〜1）とし、有名／中間／穴場候補／未判定に分ける
   （最小・最大での正規化は、閲覧数 0 のスポットに引っ張られて境界値が意味を持たなくなるため使わない）
4. 評価：AUC（有名 > 穴場 になる確率）、仮の知名度 fame_dummy との順位相関、人の分類と区分の対応表

順位値は「比べる集合」で変わる。スポットを足したら再実行し、全件の F を入れ直す。

データの出典とライセンス：
- 閲覧数：Wikimedia Pageviews API（https://wikimedia.org/api/rest_v1/）。データは CC0
- 記事の対応：Wikidata（CC0）
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "df-2026-t028-fame/1.0 (https://github.com/Devfest-Hackathon-2026/df-2026-t028)"
WIKIDATA_API = "https://www.wikidata.org/w/api.php"
PAGEVIEWS = "https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article"
LANGS = ("ja", "en")


def get_json(url: str, params: dict | None = None) -> dict:
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                return json.load(res)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return {}
            if e.code == 429 and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise
    return {}


JAWIKI_API = "https://ja.wikipedia.org/w/api.php"


def resolve_ja(title: str) -> tuple[str | None, str | None, bool]:
    """日本語版の記事名を、転送（リダイレクト）をたどって正式名にする。(正式名, wikidata ID, 曖昧さ回避か)"""
    data = get_json(JAWIKI_API, {"action": "query", "titles": title, "redirects": 1,
                                 "prop": "pageprops", "ppprop": "wikibase_item|disambiguation",
                                 "format": "json", "formatversion": 2})
    for page in data.get("query", {}).get("pages", []):
        if page.get("missing"):
            return None, None, False
        props = page.get("pageprops", {})
        return page["title"], props.get("wikibase_item"), "disambiguation" in props
    return None, None, False


def search_candidates(name: str) -> list[str]:
    data = get_json(JAWIKI_API, {"action": "query", "list": "search", "srsearch": name,
                                 "srlimit": 3, "format": "json", "formatversion": 2})
    return [hit["title"] for hit in data.get("query", {}).get("search", [])]


def sitelinks(qid: str) -> dict[str, str]:
    data = get_json(WIKIDATA_API, {"action": "wbgetentities", "ids": qid, "props": "sitelinks",
                                   "sitefilter": "|".join(f"{lang}wiki" for lang in LANGS),
                                   "format": "json"})
    links = data.get("entities", {}).get(qid, {}).get("sitelinks", {})
    return {lang: links[f"{lang}wiki"]["title"] for lang in LANGS if f"{lang}wiki" in links}


def find_entity(spot: dict) -> tuple[str | None, dict[str, str], str | None, list[str]]:
    """(wikidata ID, 言語ごとの記事名, 要確認の理由, 候補の記事名) を返す。

    記事名は次の順で決める：
      1. スポットデータの wiki_ja（人が確認した日本語版の記事名）
      2. スポットデータの wikidata（collect_commons.py が付けた ID）
      3. スポット名そのもの
    見つからない・曖昧さ回避ページに当たった場合は「未判定」とし、検索の候補を返す（閲覧数 0 扱いにはしない）。
    wiki_ja を null または "" にしたスポットは「人が確認したうえで記事がない」とみなし、閲覧数 0 として扱う。
    """
    if "wiki_ja" in spot and not spot["wiki_ja"]:
        return None, {}, None, []
    if spot.get("wiki_ja"):
        title, qid, disamb = resolve_ja(spot["wiki_ja"])
    elif spot.get("wikidata"):
        qid, disamb = spot["wikidata"], False
        title = "(wikidata)"
    else:
        title, qid, disamb = resolve_ja(spot["name"])

    if title is None:
        return None, {}, "記事が見つからない", search_candidates(spot["name"])
    if disamb:
        return None, {}, f"曖昧さ回避ページ（{title}）", search_candidates(spot["name"])
    titles = sitelinks(qid) if qid else {"ja": title}
    return qid, titles, None, []


def monthly_views(lang: str, title: str, start: str, end: str) -> int:
    article = urllib.parse.quote(title.replace(" ", "_"), safe="")
    url = f"{PAGEVIEWS}/{lang}.wikipedia/all-access/user/{article}/monthly/{start}/{end}"
    return sum(item["views"] for item in get_json(url).get("items", []))


def last_12_months(today: dt.date) -> tuple[str, str, str]:
    first_of_this_month = today.replace(day=1)
    end = first_of_this_month - dt.timedelta(days=1)
    start = (end.replace(day=1) - dt.timedelta(days=330)).replace(day=1)
    label = f"{start:%Y-%m}〜{end:%Y-%m}"
    return start.strftime("%Y%m%d00"), end.strftime("%Y%m%d00"), label


def rank(values: list[float]) -> list[float]:
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return ranks


def spearman(a: list[float], b: list[float]) -> float:
    ra, rb = rank(a), rank(b)
    ma, mb = sum(ra) / len(ra), sum(rb) / len(rb)
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    sa = math.sqrt(sum((x - ma) ** 2 for x in ra))
    sb = math.sqrt(sum((y - mb) ** 2 for y in rb))
    return cov / (sa * sb) if sa and sb else float("nan")


BANDS = ("有名", "中間", "穴場候補", "未判定")


def band(fame: float | None) -> str:
    """境界値は 30〜50 件で試した仮の値。実データで見直す。"""
    if fame is None:
        return "未判定"
    if fame >= 0.7:
        return "有名"
    if fame <= 0.3:
        return "穴場候補"
    return "中間"


def auc(famous: list[float], hidden: list[float]) -> float:
    pairs = [(f > h) + 0.5 * (f == h) for f in famous for h in hidden]
    return sum(pairs) / len(pairs) if pairs else float("nan")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    spots = json.loads(args.data.read_text(encoding="utf-8"))["spots"]
    start, end, period = last_12_months(dt.date.today())
    print(f"期間：{period}（{len(spots)} 件）", file=sys.stderr)

    rows = []
    for spot in spots:
        qid, titles, review, candidates = find_entity(spot)
        views = {lang: monthly_views(lang, t, start, end) for lang, t in titles.items()}
        rows.append({"id": spot["id"], "name": spot["name"], "kind": spot.get("kind"),
                     "fame_dummy": spot.get("fame_dummy"), "wikidata": qid,
                     "titles": titles, "views": views, "views_total": sum(views.values()),
                     "needs_review": review, "candidates": candidates})
        print(f"  {spot['name']}: {review or qid} {views} {candidates or ''}", file=sys.stderr)
        time.sleep(0.1)

    # 知名度 F：判定できたスポットの中での順位値（0〜1）。同じ閲覧数は同じ順位（平均順位）
    # 未判定（記事を確定できない）のスポットは順位の計算に入れず、fame = null・band = "未判定" にする。
    # 未判定を 0 にすると、情報が足りないだけの場所が穴場として上位に出てしまうため。
    judged = [r for r in rows if not r["needs_review"]]
    ranks = rank([float(r["views_total"]) for r in judged])
    n = len(judged)
    for r, rk in zip(judged, ranks):
        r["fame"] = round((rk - 1) / (n - 1), 4) if n > 1 else 0.5
    for r in rows:
        r.setdefault("fame", None)
        r["band"] = band(r["fame"])

    famous = [r["fame"] for r in judged if r["kind"] == "famous"]
    hidden = [r["fame"] for r in judged if r["kind"] == "hidden"]
    with_dummy = [r for r in judged if r["fame_dummy"] is not None]
    evaluation = {
        "judged": f"{n}/{len(rows)}",
        "auc_famous_over_hidden": round(auc(famous, hidden), 4),
        "spearman_vs_fame_dummy": round(spearman([r["fame"] for r in with_dummy],
                                                 [r["fame_dummy"] for r in with_dummy]), 4),
        # 人の分類（kind）と、知名度の区分（band）の対応表
        "band_by_kind": {k: {b: sum(1 for r in rows if r["kind"] == k and r["band"] == b)
                             for b in BANDS} for k in ("famous", "hidden")},
        "hidden_but_famous_band": [r["name"] for r in rows
                                   if r["kind"] == "hidden" and r["band"] == "有名"],
        "famous_but_hidden_band": [r["name"] for r in rows
                                   if r["kind"] == "famous" and r["band"] == "穴場候補"],
        "needs_review": {r["name"]: {"reason": r["needs_review"], "candidates": r["candidates"]}
                         for r in rows if r["needs_review"]},
    }

    out = {
        "_source": {
            "metric": "日本語版・英語版 Wikipedia の閲覧数（人のみ、全デバイス）の合計",
            "period": period,
            "api": "Wikimedia Pageviews API / Wikidata",
            "license": "CC0",
            "retrieved_at": dt.date.today().isoformat(),
            "formula": "F = 判定できたスポットの中での閲覧数の順位値 (順位-1)/(件数-1)。未判定は null",
            "bands": "有名：F ≥ 0.7 / 中間：0.3 < F < 0.7 / 穴場候補：F ≤ 0.3 / 未判定：F = null",
        },
        "evaluation": evaluation,
        "spots": sorted(rows, key=lambda r: (r["fame"] is None, -(r["fame"] or 0))),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("\n== 評価", file=sys.stderr)
    print(json.dumps(evaluation, ensure_ascii=False, indent=2), file=sys.stderr)
    print(f"\n{args.out} に保存しました", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
