<img width="1282" height="1037" alt="20260716_18h23m22s_grim" src="https://github.com/user-attachments/assets/172afc1b-7955-4501-bd1d-2eb5f5a4ff39" />

<img width="1282" height="1038" alt="20260716_18h23m58s_grim" src="https://github.com/user-attachments/assets/3e600d50-382e-42b0-9849-5db8bee56932" />

# pod-search

A tiny bash + fzf script that finds a podcast's RSS feed and copies it to your clipboard. That's it, that's the whole app.

## Why this exists

I use a terminal podcast client (podliner, and similar tools work the same way) that just wants a raw RSS feed URL to subscribe to a show. Getting that URL normally means opening a browser, searching some podcast directory, finding the right show, digging out the actual feed link (sometimes it's not even obvious which one it is)... for something I do from a terminal anyway. Felt silly.

So this script does the whole thing without ever leaving the terminal: type a name (or browse by genre), pick from a list, feed URL lands in your clipboard, paste it into your podcast client. Done in like 5 seconds.

## What it does

Two modes, picked from an fzf menu when you launch it:

- **Search by name** – hits the iTunes Search API, shows you matches, you pick one, feed URL gets copied.
- **Browse by genre** – picks a category (Comedy, True Crime, Fiction, whatever — the full list is pulled live from Podcast Index, not hardcoded), shows you the trending podcasts in that genre via the Podcast Index API, complete with a preview pane showing description/episode count/language before you commit to a pick.

## The two APIs (and why both)

- **[iTunes Search API](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/)** — no API key needed, handles keyword search. This is what powers "Search by name."
- **[Podcast Index API](https://podcastindex-org.github.io/docs-api/)** — powers genre browsing. Apple doesn't really expose a working "show me the top podcasts in this category" endpoint anymore (the old chart RSS feeds are flaky/half-dead at this point), so this fills that gap. Also just has richer metadata (real descriptions, episode counts) which is why genre-browse mode gets the nice preview pane and keyword-search doesn't.

Podcast Index requires a free API key + secret. **Heads up:** their signup currently blocks generic free email providers (Gmail, Outlook) to cut down on scraping/spam signups — use non commerical/self-hosting email.

## Dependencies

- `bash`
- `curl`
- `jq`
- `fzf`
- `wl-copy` (Wayland) or `xclip` (X11) — script auto-detects which one to use based on `$XDG_SESSION_TYPE`
- `sha1sum` (part of coreutils, you already have it)

Nothing exotic, should already be sitting on most Linux boxes minus maybe `fzf` and `jq`.

## Setup

1. Grab the script, make it executable:
   ```
   chmod +x pod-search.sh
   ```

2. If you want genre browsing, sign up for a free key at [api.podcastindex.org](https://api.podcastindex.org/) and create a config file:
   ```
   ~/.config/pod-search/config
   ```
   with this in it (**use single quotes**, not double — some secrets contain `$` and double quotes will silently mangle them):
   ```bash
   PODCASTINDEX_API_KEY='your_key_here'
   PODCASTINDEX_API_SECRET='your_secret_here'
   PODCASTINDEX_USER_AGENT='your-app-name/1.0'
   ```
   `PODCASTINDEX_USER_AGENT` can be literally anything identifying — it just can't be blank or a generic default value, the API rejects those.

   Skip this whole step if you only want keyword search — that mode works with zero config.

3. Run it:
   ```
   ./pod-search.sh
   ```

## Caching

Genre-browse mode caches stuff locally so it's not hammering the API every time:

- Category list: cached 30 days (categories basically never change)
- Per-genre trending list: cached 24 hours

Cache lives at `~/.cache/pod-search/`. If a cached genre list is still fresh, you'll get an fzf prompt asking whether to use the cache or force a refresh.

## A couple of honest caveats

- Genre browsing only shows the **top ~200 trending podcasts per category**, not the entire catalog under that genre — Podcast Index has millions of feeds total, this is a curated/ranked slice, not an exhaustive directory dump.
- No image previews. Terminal image rendering (Sixel/Kitty protocol) is a whole separate mess that depends on your terminal emulator, and honestly the text preview (title/author/description/episode count) tells you what you need to know anyway.

## License

MIT — see [LICENSE](LICENSE). Do whatever you want with it.
