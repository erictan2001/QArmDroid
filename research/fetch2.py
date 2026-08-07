import base64, urllib.request

UA = {'User-Agent': 'Mozilla/5.0'}
def fetch(url, timeout=90):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def gs(path):
    url = "https://android.googlesource.com/" + path + "?format=TEXT"
    raw = fetch(url)
    try:
        return base64.b64decode(raw).decode('utf-8', 'replace')
    except Exception as e:
        return f"ERR {e}"

import os
os.makedirs("research", exist_ok=True)

def save(name, content):
    with open(f"research/{name}", "w", encoding="utf-8") as f:
        f.write(content)
    print(f"SAVED {name} len={len(content)}")

# 1. Cuttlefish README from googlesource
save("cf_readme.md", gs("https://android.googlesource.com/device/google/cuttlefish/+/HEAD/README.md"))

# 2. Cuttlefish docs on source.android.com
for slug in ["cuttlefish/", "cuttlefish/fetch",
             "cuttlefish/use", "cuttlefish/known-issues"]:
    try:
        content = fetch("https://source.android.com/docs/setup/create/" + slug).decode("utf-8", "replace")
        save("cf_" + slug.replace("/","_").replace("create_","").replace("cuttlefish","").strip() or "landing" + ".html", content)
    except Exception as e:
        print("ERR", slug, e)

# 2. ci.android.com build status for a target (via androidbuildpia)
# https://ci.android.com/builds/latest/branches/aosp-main-throttled/status/grid
for b in ["aosp-main", "aosp-main-throttled", "android15-qpr3-release", "android15-release"]:
    try:
        content = fetch(f"https://ci.android.com/builds/latest/branch/{b}/status/grid").decode("utf-8","replace")
        save("grid_" + b + ".html", content)
        print("grid", b, len(content))
    except Exception as e:
        print("ERR_grid", b, e)