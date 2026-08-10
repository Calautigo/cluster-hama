# SPDX-License-Identifier: AGPL-3.0-or-later
"""Serper.dev (Google Search API) engine for SearXNG.

The API key is read from the ``SERPER_API_KEY`` environment variable at
startup, so it never lands in a ConfigMap or in git.
"""

import os

from searx.exceptions import SearxEngineAPIException
from searx.result_types import EngineResults

about = {
    "website": "https://serper.dev",
    "use_official_api": True,
    "require_api_key": True,
    "results": "JSON",
}

api_key: str = os.environ.get("SERPER_API_KEY", "")
"""API key for Serper.dev (required)."""

categories = ["general", "web"]
paging = True
safesearch = False
time_range_support = False

results_per_page: int = 10


def init(_):
    """Fail fast at startup when the API key is missing."""
    if not api_key:
        raise SearxEngineAPIException("No API key provided")


def request(query: str, params):
    """Create the API request."""
    payload = {"q": query, "num": results_per_page}
    pageno = params.get("pageno", 1)
    if pageno > 1:
        payload["page"] = pageno
    params["url"] = "https://google.serper.dev/search"
    params["method"] = "POST"
    params["headers"]["X-API-KEY"] = api_key
    params["headers"]["Content-Type"] = "application/json"
    params["json"] = payload


def response(resp) -> EngineResults:
    """Process the API response and return results."""
    res = EngineResults()
    data = resp.json()
    for item in data.get("organic", []):
        res.add(
            res.types.MainResult(
                url=item.get("link", ""),
                title=item.get("title", ""),
                content=item.get("snippet", ""),
            )
        )
    return res
