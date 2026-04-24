#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# RUNE Airgapped Bundle Generator
# IEC 62443 SM-10: Artifact packaging for restricted environments.

set -e

BUNDLE_DIR="rune-bundle-$(date +%Y%m%d)"
REGISTRY=${1:-"ghcr.io/lpasquali"}
VERSION=${2:-"v0.0.0a5"}

echo "--- Generating RUNE Airgapped Bundle ($VERSION) ---"
mkdir -p "$BUNDLE_DIR/images"
mkdir -p "$BUNDLE_DIR/charts"

# 1. Pull and Save OCI Images
IMAGES=(
    "rune:$VERSION"
    "rune-operator:$VERSION"
    "rune-ui:$VERSION"
    "rune-registry:latest"
)

for img in "${IMAGES[@]}"; do
    full_img="$REGISTRY/$img"
    tar_name=$(echo "$img" | tr ':' '-' | tr '/' '-').tar
    echo "Processing image: $full_img -> $tar_name"
    docker pull "$full_img"
    docker save "$full_img" -o "$BUNDLE_DIR/images/$tar_name"
done

# 2. Export Helm Charts
CHARTS=(
    "rune-operator"
    "rune"
    "rune-ui"
)

for chart in "${CHARTS[@]}"; do
    echo "Exporting chart: $chart"
    # Note: Requires lpasquali/rune-charts to be cloned sibling-style
    if [ -d "../rune-charts/charts/$chart" ]; then
        helm package "../rune-charts/charts/$chart" -d "$BUNDLE_DIR/charts"
    else
        echo "Warning: Chart directory ../rune-charts/charts/$chart not found. Skipping."
    fi
done

# 3. Copy deployment logic
echo "Copying deployment logic..."
cp helmfile.yaml "$BUNDLE_DIR/"
cp -r values "$BUNDLE_DIR/"
cp -r ansible "$BUNDLE_DIR/"

# 4. Finalize
echo "Finalizing bundle: $BUNDLE_DIR.tar.gz"
tar -czf "$BUNDLE_DIR.tar.gz" "$BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"

echo "Done! Bundle ready for transfer."
