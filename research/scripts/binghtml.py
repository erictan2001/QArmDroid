import sys, urllib.parse, re
from fetchtext import fetch

def bing_html(query, mkt="en-US", n=20):
    q = urllib.parse.quote(query)
    raw = fetch(f"https://www.bing.com/search?q={q}&mkt={mkt}&setlang=en")
    if raw.startswith("__ERROR__"):
        return [("__ERR__", raw, "")]
    res = []
    seen = set()
    pat = re.compile(r'<li class="b_algo".*?<h2><a href="([^"]+)"[^>]*>(.*?)</a></h2>(.*?)</li>', re.S)
    for m in pat.finditer(raw):
        url = re.sub(r"&amp;", "&", m.group(1))
        if url in seen or not url.startswith("http"):
            continue
        seen.add(url)
        title = re.sub(r"<[^>]+>", "", m.group(2)).strip()
        body = re.sub(r"<[^>]+>", " ", m.group(3))
        body = re.sub(r"\s+", " ", body).strip()
        res.append((title, url, body[:320]))
    return res

def main():
    q = sys.argv[2]
    mkt = sys.argv[3] if len(sys.argv) > 3 else "en-US"
    for t, u, b in bing_html(q, mkt):
        print(f"- {t}\n    {u}\n    {b}")

if __name__ == "__main__":
    main()