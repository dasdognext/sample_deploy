#!/bin/bash

# *****************************************************************
# * Copyright (C) 2025 gNext Labs LLC - All Rights Reserved
# *
# * Unauthorized copying of this code, via any medium is strictly prohibited
# * Proprietary and confidential
# * Version: 1.0.0
# * Written by Daniel Sanchez <daniel.sanchez@gnextlabs.com>, 2025
# ******************************************************************

set -euo pipefail  # Exit on error, undefined vars, pipe failures

echo "=========================================="
echo "Lambda Layer Manager"
echo "=========================================="

# Get environment variables
LAMBDA_FUNCTION_ARN="${LAMBDA}"
LAMBDA_REGION="${LAMBDA_REGION}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PYTHON_VERSION="3.13"
REQUIREMENTS_FILE="${CODEBUILD_SRC_DIR}/cicd/requirements.txt"
LAYER_DIR="${CODEBUILD_SRC_DIR}/layer"
SSM_PARAM_BASE="/gnextlabs/lambda/${ENVIRONMENT}"

# Validate required environment variables
if [ -z "${LAMBDA_FUNCTION_ARN:-}" ]; then
    echo "ERROR: LAMBDA environment variable is not set"
    exit 1
fi

if [ -z "${LAMBDA_REGION:-}" ]; then
    echo "ERROR: LAMBDA_REGION environment variable is not set"
    exit 1
fi

if [ -z "${CODEBUILD_SRC_DIR:-}" ]; then
    echo "ERROR: CODEBUILD_SRC_DIR environment variable is not set"
    exit 1
fi

# Validate requirements file exists
if [ ! -f "${REQUIREMENTS_FILE}" ]; then
    echo "ERROR: requirements.txt not found at ${REQUIREMENTS_FILE}"
    exit 1
fi

# Function to extract function name from ARN
extract_function_name() {
    local arn=$1
    # If it's an ARN, extract the function name (part after function:)
    if [[ "${arn}" =~ ^arn:aws:lambda: ]]; then
        echo "${arn}" | sed 's/.*function:\([^:]*\).*/\1/'
    else
        # If it's already just a name, return as is
        echo "${arn}"
    fi
}

# LAMBDA_FUNCTION_ARN is already set from environment variable (loaded from SSM parameter-store)
echo "Lambda function ARN: ${LAMBDA_FUNCTION_ARN}"

# Extract function name from ARN
LAMBDA_FUNCTION_NAME=$(extract_function_name "${LAMBDA_FUNCTION_ARN}")
echo "Lambda function name: ${LAMBDA_FUNCTION_NAME}"

# Derive layer name from lambda function name
LAYER_NAME="${LAMBDA_FUNCTION_NAME}-LAYER"
echo "Layer name: ${LAYER_NAME}"

# SSM parameter to store layer ARN (using layer name to make it specific)
LAYER_SSM_PARAM="${SSM_PARAM_BASE}/${LAYER_NAME}_ARN"

# Function to check if layer exists
check_layer_exists() {
    local layer_name=$1
    local region=$2
    
    # Check if any version of the layer exists
    local versions=$(aws lambda list-layer-versions --layer-name "${layer_name}" --region "${region}" --query LayerVersions[0].Version --output text 2>/dev/null || echo "")
    
    if [ -n "${versions}" ] && [ "${versions}" != "None" ] && [ "${versions}" != "" ]; then
        return 0  # Layer exists
    else
        return 1  # Layer does not exist
    fi
}

# Function to get latest layer version
get_latest_layer_version() {
    local layer_name=$1
    local region=$2
    
    aws lambda list-layer-versions --layer-name "${layer_name}" --region "${region}" --query LayerVersions[0].Version --output text 2>/dev/null || echo "0"
}

# Function to get latest layer description
get_latest_layer_description() {
    local layer_name=$1
    local region=$2

    local latest_version
    latest_version=$(get_latest_layer_version "${layer_name}" "${region}")

    if [ "${latest_version}" == "0" ] || [ "${latest_version}" == "None" ] || [ -z "${latest_version}" ]; then
        echo ""
        return
    fi

    # The correct JMESPath for the value is just Description (capital D, no quotes)
    local desc
    desc=$(aws lambda get-layer-version \
        --layer-name "${layer_name}" \
        --version-number "${latest_version}" \
        --region "${region}" \
        --query Description \
        --output text 2>/dev/null)

    # If the value is literally "None" or empty, treat as missing
    if [ "${desc}" == "None" ] || [ -z "${desc}" ]; then
        echo ""
    else
        # Trim any leading/trailing whitespace
        desc=$(echo "${desc}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "${desc}"
    fi
}

# Function to generate package description from requirements
# Installs packages and uses pip freeze to get exact versions
# AWS Lambda description has a max length of 256 characters
# Also generates packages.txt file in src directory
generate_package_description() {
    local requirements_file=$1
    
    # Get package names from requirements.txt (without version specifiers)
    local package_names=$(grep -v "^#" "${requirements_file}" | grep -v "^[[:space:]]*$" | sed 's/[<>=!].*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' | sort | uniq)
    
    # Create a temporary virtual environment to get exact versions
    local temp_venv=$(mktemp -d)
    python3 -m venv "${temp_venv}" 2>/dev/null
    source "${temp_venv}/bin/activate" 2>/dev/null
    
    # Install packages silently
    python3 -m pip install --upgrade pip > /dev/null 2>&1
    python3 -m pip install -r "${requirements_file}" > /dev/null 2>&1
    
    # Get installed versions for only the packages in requirements.txt
    local package_list=""
    for pkg in ${package_names}; do
        local version=$(python3 -m pip show "${pkg}" 2>/dev/null | grep "^Version:" | cut -d' ' -f2)
        # Trim any whitespace from version
        version=$(echo "${version}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "${version}" ]; then
            if [ -n "${package_list}" ]; then
                package_list="${package_list}
${pkg}==${version}"
            else
                package_list="${pkg}==${version}"
            fi
        fi
    done
    
    deactivate 2>/dev/null
    rm -rf "${temp_venv}"
    
    # Sort the package list for consistency
    package_list=$(echo "${package_list}" | sort)
    
    # Generate packages.txt file in src directory
    local packages_file="${CODEBUILD_SRC_DIR}/src/packages.txt"
    echo "# Lambda Layer Packages" > "${packages_file}"
    echo "# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "${packages_file}"
    echo "# Environment: ${ENVIRONMENT}" >> "${packages_file}"
    echo "" >> "${packages_file}"
    echo "${package_list}" >> "${packages_file}"
    
    # Generate a SHA256 hash using printf to avoid echo newline issues
    local package_hash=$(printf '%s' "${package_list}" | sha256sum | cut -d' ' -f1)
    package_hash="${package_hash:0:16}"
    
    # Create description: hash + package list
    # Format: [hash16chars]|package1==v1|package2==v2|...
    local package_string=$(echo "${package_list}" | tr '\n' '|' | sed 's/|$//')
    
    # AWS Lambda description max is 256 chars
    # Reserve space for hash (16) + separator (1) = 17 chars
    local max_pkg_length=239
    
    if [ ${#package_string} -gt ${max_pkg_length} ]; then
        package_string="${package_string:0:${max_pkg_length}}"
        # Truncate at last complete package (at last |)
        package_string=$(echo "${package_string}" | sed 's/|[^|]*$//')
        package_string="${package_string}|..."
    fi
    
    # echo "${package_hash}|${package_string}"
    echo "${package_hash}"
}

# Function to compare package descriptions
# Returns 0 if descriptions match (no changes), 1 if different (changes detected)
# Compares the hash prefix (first 16 chars) for reliable comparison
compare_package_descriptions() {
    local current_desc=$1
    local latest_desc=$2
    
    echo "Comparing package descriptions..."
    echo "  Current: '${current_desc}'"
    echo "  Latest:  '${latest_desc}'"
    
    # Check if latest description is empty or None
    if [ -z "${latest_desc}" ] || [ "${latest_desc}" == "None" ] || [ "${latest_desc}" == "null" ]; then
        echo "No previous layer description found. Will create new layer."
        return 1
    fi
    
    # Extract hash (first 16 characters before the first |)
    local current_hash="${current_desc%%|*}"
    local latest_hash="${latest_desc%%|*}"
    
    echo "  Current hash: '${current_hash}'"
    echo "  Latest hash:  '${latest_hash}'"
    
    # Compare hashes
    if [ "${current_hash}" == "${latest_hash}" ]; then
        echo "Package hashes match. No changes detected."
        return 0
    else
        echo "Package hashes differ. Changes detected."
        echo ""
        echo "Current packages:"
        echo "${current_desc#*|}" | tr '|' '\n' | sed 's/^/  /'
        echo ""
        echo "Previous packages:"
        echo "${latest_desc#*|}" | tr '|' '\n' | sed 's/^/  /'
        return 1
    fi
}

# Function to build and publish layer
# Accepts an optional description parameter
build_and_publish_layer() {
    local layer_description="${1:-}"
    
    echo "Building Lambda Layer from requirements.txt"
    
    # Clean up any existing layer directory
    rm -rf "${LAYER_DIR}"
    
    # Create layer structure
    mkdir -p "${LAYER_DIR}/python/lib/python${PYTHON_VERSION}/site-packages"
    mkdir -p "${LAYER_DIR}/lib"
    
    # Install packages
    echo "Installing packages from requirements.txt..."
    python3 -m pip install -r "${REQUIREMENTS_FILE}" -t "${LAYER_DIR}/python/lib/python${PYTHON_VERSION}/site-packages/" --upgrade
    
    # Execute custom layer post-install hook if it exists
    # This allows lambda-specific customizations without modifying the main script
    CUSTOM_HOOK="${CODEBUILD_SRC_DIR}/cicd/layer/layer-custom.sh"
    if [ -f "${CUSTOM_HOOK}" ] && [ -x "${CUSTOM_HOOK}" ]; then
        echo "Executing custom layer hook: ${CUSTOM_HOOK}"
        # Export variables that the hook might need
        export LAYER_DIR
        export PYTHON_VERSION
        export CODEBUILD_SRC_DIR
        export REQUIREMENTS_FILE
        "${CUSTOM_HOOK}" || {
            echo "ERROR: Custom hook ${CUSTOM_HOOK} failed"
            exit 1
        }
    else
        echo "No custom layer hook found (${CUSTOM_HOOK}), skipping customizations"
    fi
    
    # Create zip file
    echo "Creating layer zip file..."
    cd "${LAYER_DIR}"
    zip -r "${CODEBUILD_SRC_DIR}/layer.zip" . > /dev/null
    cd "${CODEBUILD_SRC_DIR}"
    
    # Publish layer with optional description
    echo "Publishing Lambda Layer: ${LAYER_NAME}"
    
    if [ -n "${layer_description}" ]; then
        echo "Layer description: ${layer_description}"
        LAYER_VERSION=$(aws lambda publish-layer-version \
            --layer-name "${LAYER_NAME}" \
            --zip-file "fileb://layer.zip" \
            --compatible-runtimes "python${PYTHON_VERSION}" \
            --region "${LAMBDA_REGION}" \
            --description "${layer_description}" \
            --query Version \
            --output text)
    else
        LAYER_VERSION=$(aws lambda publish-layer-version \
            --layer-name "${LAYER_NAME}" \
            --zip-file "fileb://layer.zip" \
            --compatible-runtimes "python${PYTHON_VERSION}" \
            --region "${LAMBDA_REGION}" \
            --query Version \
            --output text)
    fi
    
    if [ -z "${LAYER_VERSION}" ] || [ "${LAYER_VERSION}" == "None" ]; then
        echo "ERROR: Failed to publish layer"
        exit 1
    fi
    
    echo "Layer published with version: ${LAYER_VERSION}"
    
    # Get layer ARN
    LAYER_ARN=$(aws lambda get-layer-version \
        --layer-name "${LAYER_NAME}" \
        --version-number "${LAYER_VERSION}" \
        --region "${LAMBDA_REGION}" \
        --query LayerVersionArn \
        --output text)
    
    echo "Layer ARN: ${LAYER_ARN}"
    
    # Store ARN in SSM parameter
    echo "Storing layer ARN in SSM parameter: ${LAYER_SSM_PARAM}"
    aws ssm put-parameter \
        --name "${LAYER_SSM_PARAM}" \
        --value "${LAYER_ARN}" \
        --type "String" \
        --overwrite \
        --region "${LAMBDA_REGION}"
    
    echo "Layer ARN stored successfully"
    
    # Cleanup
    rm -f "${CODEBUILD_SRC_DIR}/layer.zip"
    rm -rf "${LAYER_DIR}"
}

# Main execution
echo ""
echo "Step 1: Generating current package description..."
CURRENT_DESCRIPTION=$(generate_package_description "${REQUIREMENTS_FILE}")
echo "Current packages: ${CURRENT_DESCRIPTION}"

echo ""
echo "Step 2: Checking if layer exists..."
if check_layer_exists "${LAYER_NAME}" "${LAMBDA_REGION}"; then
    echo "Layer ${LAYER_NAME} already exists"
    
    echo ""
    echo "Step 3: Getting latest layer description..."
    LATEST_DESCRIPTION=$(get_latest_layer_description "${LAYER_NAME}" "${LAMBDA_REGION}")
    echo "Latest layer description: ${LATEST_DESCRIPTION:-'(none)'}"
    
    echo ""
    echo "Step 4: Comparing package descriptions..."
    if compare_package_descriptions "${CURRENT_DESCRIPTION}" "${LATEST_DESCRIPTION}"; then
        echo ""
        echo "No changes detected in packages. Skipping layer creation."
        
        # Ensure SSM parameter has the latest layer ARN
        EXISTING_ARN=$(aws ssm get-parameter --name "${LAYER_SSM_PARAM}" --region "${LAMBDA_REGION}" --query Parameter.Value --output text 2>/dev/null || echo "")
        
        if [ -z "${EXISTING_ARN}" ]; then
            echo "No SSM parameter found. Getting latest layer version..."
            LATEST_VERSION=$(get_latest_layer_version "${LAYER_NAME}" "${LAMBDA_REGION}")
            if [ "${LATEST_VERSION}" != "0" ]; then
                LAYER_ARN=$(aws lambda get-layer-version \
                    --layer-name "${LAYER_NAME}" \
                    --version-number "${LATEST_VERSION}" \
                    --region "${LAMBDA_REGION}" \
                    --query LayerVersionArn \
                    --output text)
                
                aws ssm put-parameter \
                    --name "${LAYER_SSM_PARAM}" \
                    --value "${LAYER_ARN}" \
                    --type "String" \
                    --overwrite \
                    --region "${LAMBDA_REGION}"
                
                echo "Layer ARN stored in SSM parameter"
            fi
        else
            echo "Using existing layer ARN from SSM parameter: ${EXISTING_ARN}"
        fi
    else
        echo ""
        echo "Step 5: Changes detected! Building and publishing new layer version..."
        build_and_publish_layer "${CURRENT_DESCRIPTION}"
    fi
else
    echo "Layer ${LAYER_NAME} does not exist"
    
    echo ""
    echo "Step 3: Building and publishing new layer..."
    build_and_publish_layer "${CURRENT_DESCRIPTION}"
fi

echo ""
echo "=========================================="
echo "Lambda Layer Manager completed successfully"
echo "=========================================="

