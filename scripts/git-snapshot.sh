#!/bin/bash
# Tag the current git state before MeticaSDK integration, for one-command rollback.
# Usage: bash git-snapshot.sh [tag-name]

set -e

TAG="${1:-pre-metica-integration}"

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "WARN: not a git repo — skipping snapshot."
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree is dirty. Commit or stash before integration."
    git status --short
    exit 1
fi

git tag -f "$TAG"
echo "Snapshot tagged: $TAG (at $(git rev-parse --short HEAD))"
echo "Rollback with: git reset --hard $TAG"
