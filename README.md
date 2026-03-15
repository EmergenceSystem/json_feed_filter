# json_feed_filter
[![Hex.pm](https://img.shields.io/hexpm/v/json_feed_filter.svg)](https://hex.pm/packages/json_feed_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/json_feed_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

em_filter agent for JSON Feed (jsonfeed.org spec v1 and v1.1).

Reads a list of JSON Feed URLs from `json_feed_config.json`, fetches each feed,
and returns items whose title, url or summary matches the search query.

No XML parser needed — pure JSON, lighter than RSS or Atom.
Handles both `content_text` and `content_html` fields, preferring plain text.

## Setup

Rename `json_feed_config.json.sample` to `json_feed_config.json` and fill in your feed URLs:

```json
{
    "json_feeds": [
        "https://example.com/feed.json",
        "https://another.com/feed.json"
    ]
}
```

## Usage

Add `json_feed_filter` to your dependencies, then start it as an OTP application.
It registers itself with `em_disco` automatically on startup.

For a site-specific filter, create a wrapper application that copies its own
`priv/json_feed_config.json` to the working directory before starting `json_feed_filter`.
See `tech_blogs_json_feed_filter` for a concrete example.
