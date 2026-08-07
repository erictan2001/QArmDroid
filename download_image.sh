#!/bin/bash
# Script to download AOSP ARM64 Cuttlefish images for use with the emulator

echo "Downloading fetch_cvd tool..."
curl https://ci.android.com/projects/android/repository/android-mainline/latest/artifacts/fetch_cvd > fetch_cvd
chmod +x fetch_cvd

echo "Fetching AOSP ARM64 Phone image..."
# Using the standard aosp_cf_arm64_phone target
./fetch_cvd -target=aosp_cf_arm64_phone -branch=aosp-main

echo "Extraction complete. You can now point the emulator to the 'system.img' or the 'composite.img' found in the current directory."
