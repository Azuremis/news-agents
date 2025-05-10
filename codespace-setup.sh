#!/usr/bin/env bash
set -euo pipefail

# 1. Download Q
echo "==> Downloading Q client..."
curl --proto '=https' --tlsv1.2 -sSf "https://desktop-release.q.us-east-1.amazonaws.com/latest/q-x86_64-linux-musl.zip" -o "q.zip"

# 2. Unzip
echo "==> Extracting Q..."
unzip -o q.zip -d q

# 3. Install Q
echo "==> Installing Q..."
bash q/install.sh

# 4. Verify installation
echo "==> Q version:"
q --version

# 5. Sync dependencies
echo "==> Running uv sync..."
uv sync

# 6. Show dependency tree
echo "==> Running uv tree..."
uv tree

echo "✅ Setup complete!"
