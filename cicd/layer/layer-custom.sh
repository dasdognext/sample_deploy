#!/bin/bash

# *****************************************************************
# * Copyright (C) 2025 gNext Labs LLC - All Rights Reserved
# *
# * Unauthorized copying of this code, via any medium is strictly prohibited
# * Proprietary and confidential
# * Custom layer hook to add local lambdawarmer package
# ******************************************************************

set -euo pipefail  # Exit on error, undefined vars, pipe failures

echo "=========================================="
echo "Custom Layer Hook: Adding lambdawarmer"
echo "=========================================="

# Source directory for lambdawarmer
LAMBDWARMER_SOURCE="${CODEBUILD_SRC_DIR}/cicd/layer/lambdawarmer"
LAMBDWARMER_TARGET="${LAYER_DIR}/python/lib/python${PYTHON_VERSION}/site-packages/lambdawarmer"

# Check if lambdawarmer source exists
if [ ! -d "${LAMBDWARMER_SOURCE}" ]; then
    echo "ERROR: lambdawarmer directory not found at ${LAMBDWARMER_SOURCE}"
    exit 1
fi

# Check if target directory exists
if [ ! -d "${LAYER_DIR}/python/lib/python${PYTHON_VERSION}/site-packages" ]; then
    echo "ERROR: Target site-packages directory does not exist"
    exit 1
fi

# Copy lambdawarmer package to layer
echo "Copying lambdawarmer from ${LAMBDWARMER_SOURCE} to ${LAMBDWARMER_TARGET}..."
cp -r "${LAMBDWARMER_SOURCE}" "${LAMBDWARMER_TARGET}"

# Verify the copy was successful
if [ ! -f "${LAMBDWARMER_TARGET}/__init__.py" ]; then
    echo "ERROR: Failed to copy lambdawarmer package"
    exit 1
fi

echo "Successfully added lambdawarmer package to layer"
echo "=========================================="

