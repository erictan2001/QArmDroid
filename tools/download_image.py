import urllib.request
import zipfile
import os
import sys

URL = "https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-34_r14.zip"
LOCALAPPDATA = os.environ.get("LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local"))
DEST_DIR = os.environ.get("ANDROID_IMAGE_DIR", os.path.join(LOCALAPPDATA, r"Android\Sdk\system-images\android-34\google_apis\arm64-v8a"))
ZIP_PATH = os.environ.get("ANDROID_IMAGE_ZIP", os.path.join(LOCALAPPDATA, r"Android\Sdk\arm64-v8a-34_r14.zip"))

os.makedirs(os.path.dirname(DEST_DIR), exist_ok=True)

if not os.path.exists(ZIP_PATH):
    print(f"Downloading {URL}...")
    def reporthook(blocknum, blocksize, totalsize):
        read = blocknum * blocksize
        if totalsize > 0:
            percent = read * 100 / totalsize
            sys.stdout.write(f"\rDownloading: {read / (1024*1024):.1f} MB / {totalsize / (1024*1024):.1f} MB ({percent:.1f}%)")
            sys.stdout.flush()
    urllib.request.urlretrieve(URL, ZIP_PATH, reporthook)
    print("\nDownload finished.")

print(f"Extracting to {DEST_DIR}...")
os.makedirs(DEST_DIR, exist_ok=True)
with zipfile.ZipFile(ZIP_PATH, 'r') as zip_ref:
    # Most zips have a top-level dir arm64-v8a/
    for member in zip_ref.infolist():
        # strip top-level dir if present
        parts = member.filename.split('/')
        if len(parts) > 1 and parts[0] == 'arm64-v8a':
            target_path = os.path.join(DEST_DIR, *parts[1:])
        else:
            target_path = os.path.join(DEST_DIR, *parts)
        if member.is_dir():
            os.makedirs(target_path, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(target_path), exist_ok=True)
            with zip_ref.open(member) as source, open(target_path, "wb") as target:
                target.write(source.read())
print("Extraction complete!")
