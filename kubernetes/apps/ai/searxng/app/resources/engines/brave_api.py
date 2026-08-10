# SPDX-License-Identifier: AGPL-3.0-or-later
"""Brave Search API engine for SearXNG.

The API key is read from the ``BRAVE_API_KEY`` environment variable at
startup, so it never lands in a ConfigMap or in git.
"""

import os
from urllib.parse import urlencode

from searx.exceptions import SearxEngineAPIException
from searx.result_types import EngineResults

about = {
    "website": "https://api.search.brave.com/",
    "use_official_api": True,
    "require_api_key": True,
    "results": "JSON",
}

api_key: str = os.environ.get("BRAVE_API_KEY", "")
"""API key for Brave Search API (required)."""

categories = ["general", "web"]
paging = True
safesearch = True
time_range_support = True

results_per_page: int = 20

time_range_map = {"day": "past_day", "week": "past_week", "month": "past_month", "year": "past_year"}


def init(_):
    """Fail fast at startup when the API key is missing."""
    if not api_key:
        raise SearxEngineAPIException("No API key provided")


def request(query: str, params):
    """Create the API request."""
    search_args = {
        "q": query,
        "count": results_per_page,
        "offset": (params.get("pageno", 1) - 1) * results_per_page,
    }
    if params.get("time_range"):
        search_args["time_range"] = time_range_map.get(params["time_range"])
    if params.get("safesearch"):
        search_args["safesearch"] = "strict"
    search_args = {k: v for k, v in search_args.items() if v is not None}
    params["url"] = f"https://api.search.brave.com/res/v1/web/search?{urlencode(search_args)}"
    params["headers"]["X-Subscription-Token"] = api_key


def response(resp) -> EngineResults:
    """Process the API response and return results."""
    res = EngineResults()
    data = resp.json()
    for item in data.get("web", {}).get("results", []):
        res.add(
            res.types.MainResult(
                url=item.get("url", ""),
                title=item.get("title", ""),
                content=item.get("description", ""),
            )
        )
    return res
