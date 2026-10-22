# Corpus attribution

The bundled knowledge index (`App/Resources/corpus.sqlite`) is built from plain-text
extracts of English Wikipedia articles, retrieved once at build time by
`Scripts/fetch_corpus.py` and committed so the shipped app needs no network.

- License: **CC BY-SA 4.0** — https://creativecommons.org/licenses/by-sa/4.0/
- Source: `https://en.wikipedia.org/w/api.php` (`action=query&prop=extracts&explaintext=1`)
- Retrieved: see `Corpus/raw/manifest.json` → `retrieved`
- Articles: see `Corpus/raw/manifest.json` → `articles`
- Topic list: `Corpus/topics.txt`
- Exact per-article URL and page id: `Corpus/raw/wiki.jsonl` (one JSON object per line)

Because the corpus is CC BY-SA 4.0, any redistribution of `corpus.sqlite` or of a
modified corpus must keep this attribution and the same license for the text.

## How to see the attribution in the app

Every answer cites retrieved passages by number; tapping the citation row opens a sheet
that shows the article title, the exact source URL, and the excerpt used.

## Rebuilding with a different corpus

Point `Scripts/fetch_corpus.py` at another topic list, or replace
`Corpus/raw/wiki.jsonl` with your own JSONL of `{"title", "url", "extract", "license"}`
records and run `make index`. Nothing else in the app assumes Wikipedia.
