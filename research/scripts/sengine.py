"""Direct-HTTP search helper (web_search unavailable). Bing RSS + DDG Lite."""
import re, sys, gzip, urllib.request, urllib.parse

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
CONSENT = "CONSENT=YES+cb; SOCS=CAESHAgBEhJnd3NfMjAyNDAxMDEtMF9sbzIaAmVuIAEA"

def fetch(url, timeout=25):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA, "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip", "Cookie": CONSENT,
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            data = gzip.decompress(data)
        return data.decode("utf-8", errors="replace")

def bing_rss(query, count=10):
    url = ("https://www.bing.com/search?format=rss&mkt=en-US&q=" +
           urllib.parse.quote(query))
    try:
        xml = fetch(url)
    except Exception as e:
        print(f"BING FAIL: {e}")
        return
    items = re.findall(r"<item>(.*?)</item>", xml, re.S)
    for it in items[:count]:
        t = re.search(r"<title>(.*?)</title>", it, re.S)
        l = re.search(r"<link>(.*?)</link>", it, re.S)
        d = re.search(r"<description>(.*?)</description>", it, re.S)
        title = t.group(1).strip() if t else "?"
        link = l.group(1).strip() if l else "?"
        desc = d.group(1).strip() if d else ""
        desc = re.sub(r"<[^>]+>", "", desc)[:220]
        print(f"- {title}\n  {link}\n  {desc}\n")
    if not items:
        print("BING RSS: 0 items (shell page?)")

def ddg_lite(query, count=10):
    url = "https://lite.duckduckgo.com/lite/?q=" + urllib.parse.quote(query)
    try:
        html = fetch(url)
    except Exception as e:
        print(f"DDG FAIL: {e}")
        return
    # results are <a rel="nofollow" href="...">title</a> followed by snippets
    links = re.findall(r'<a rel="nofollow" href="([^"]+)"[^>]*>(.*?)</a>', html, re.S)
    shown = 0
    for href, title in links:
        title = re.sub(r"<[^>]+>", "", title).strip()
        if not title or href.startswith("https://lite.duckduckgo.com"):
            continue
        if href.startswith("//duckduckgo.com") or "duckduckgo.com/l" in href:
            continue
        print(f"- {title}\n  {href}\n")
        shown += 1
        if shown >= count:
            break
    if shown == 0:
        print("DDG Lite: 0 results (rate-limited?)")

if __name__ == "__main__":
    q = sys.argv[1] if len(sys.argv) > 1 else "cuttlefish qemu"
    engine = sys.argv[2] if len(sys.argv) > 2 else "ddg"
    if engine == "bing":
        print(f"=== BING RSS: {q} ===")
        bing_rss(q)
    else:
        print(f"=== DDG Lite: {q} ===")
        ddg_lite(q)
