import urllib.request
import xml.etree.ElementTree as ET

urls = [
    "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml",
    "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml",
]

for u in urls:
    try:
        req = urllib.request.Request(u, headers={'User-Agent': 'Mozilla/5.0'})
        data = urllib.request.urlopen(req).read()
        root = ET.fromstring(data)
        for p in root.findall('.//{http://schemas.android.com/repository/android/common/02}remotePackage') + root.findall('.//remotePackage'):
            path = p.attrib.get('path', '')
            if 'arm64' in path:
                archive = p.find('.//url')
                if archive is not None:
                    print(f"{path} | https://dl.google.com/android/repository/sys-img/{path.split(';')[2]}/{archive.text}")
    except Exception as e:
        print(f"Error {u}: {e}")
