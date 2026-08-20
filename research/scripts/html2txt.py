import re, sys
from html.parser import HTMLParser

class T(HTMLParser):
    def __init__(self):
        super().__init__()
        self.out = []
        self.skip = 0
    def handle_starttag(self, tag, attrs):
        if tag in ("script","style","noscript"): self.skip += 1
        if tag in ("p","div","br","li","tr","h1","h2","h3","h4","pre","table"): self.out.append("\n")
        if tag in ("td","th"): self.out.append(" | ")
    def handle_endtag(self, tag):
        if tag in ("script","style","noscript") and self.skip: self.skip -= 1
    def handle_data(self, d):
        if not self.skip: self.out.append(d)

def html2text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        p = T(); p.feed(f.read())
    t = "".join(p.out)
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\n\s*\n+", "\n\n", t)
    return t

for name in sys.argv[1:]:
    txt = html2text(name)
    out = name.rsplit(".",1)[0] + ".txt"
    with open(out, "w", encoding="utf-8") as f:
        f.write(txt)
    print(f"{name} -> {out} ({len(txt)} chars)")
