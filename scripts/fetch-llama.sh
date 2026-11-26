#!/bin/sh
# Fetches the pinned llama.cpp xcframework into Vendor/. Run lantern-smoke on each Gemma
# (--state, --think --stop, with --draft) before moving the pin.
set -eu
TAG=b12633
SHA=d0b199082096fc63c875ef55c4675de09b3d42fa25a0b8d2dba736938c9c9bc6
cd "$(dirname "$0")/.."
if [ -f Vendor/.tag ] && [ "$(cat Vendor/.tag)" = "$TAG" ]; then exit 0; fi
mkdir -p Vendor && cd Vendor && rm -rf build-apple  # leaves TailscaleKit
curl -sSfL -o llama.zip "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$SHA  llama.zip" | shasum -a 256 -c -
unzip -q llama.zip && rm llama.zip
echo "$TAG" > .tag
