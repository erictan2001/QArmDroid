import sys, re, urllib.request, gzip, io
from bs4 import BeautifulSoup

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

def fetch(url, timeout=25):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
        "Accept-Encoding": "gzip",
    })
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
    soup = BeautifulSoup(html, "html.parser")
    for t in soup(["script","style","noscript"]): t.decompose()
    text = soup.get_text("\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text

if __name__ == "__main__":
    url = sys.argv[1]
    raw = fetch(url)
    if raw.startswith("__ERROR__"):
        print(raw); sys.exit(0)
    print(clean(raw))