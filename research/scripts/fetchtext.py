import sys, re, urllib.request, gzip
from html.parser import HTMLParser

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

SKIP_TAGS = {"script","style","noscript","head","svg","path"}

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0
    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS: self.skip += 1
        if tag in ("p","div","br","li","h1","h2","h3","h4","tr","section","article") and not self.skip:
            self.parts.append("\n")
    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self.skip: self.skip -= 1
        if tag in ("p","div","li","h1","h2","h3","h4","tr") and not self.skip:
            self.parts.append("\n")
    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)

def fetch(url, timeout=25, cookies=True):
    headers = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
        "Accept-Encoding": "gzip",
    }
    if cookies:
        headers["Cookie"] = "CONSENT=YES+cb.20240101-01-p0.en+FX+000; SOCS=CAESHAgBEhJnd3NfMjAyNDAxMDEtMF9SQzIaAmVuIAEaBgiA_LyaBg"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
            if r.headers.get("Content-Encoding") == "gzip":
                data = gzip.decompress(data)
            ct = r.headers.get("Content-Type","")
            enc = "utf-8"
            m = re.search(r"charset=([\w-]+)", ct)
            if m: enc = m.group(1)
            return data.decode(enc, errors="replace")
    except Exception as e:
        return f"__ERROR__:{e}"

def clean(html):
    p = TextExtractor()
    p.feed(html)
    text = "".join(p.parts)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text

if __name__ == "__main__":
    url = sys.argv[1]
    raw = fetch(url)
    if raw.startswith("__ERROR__"):
        print(raw); sys.exit(0)
    print(clean(raw))