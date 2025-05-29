#!/bin/bash

#########################################################################
# JupyterHub Environment and Kernel Deployment Script
#
# Purpose:
#   Deploy a github repo to a new conda environment and JupyterHub kernel
#   - Implements verification and logging capabilities
#
# Usage:
# bash  ./deploy.sh <repo_name> <tag_name> [kernel_prefix] [--dry-run]
##########################################################################

# -e = exit on error unless in a conditional expression
# -u = treat unset variables as an error
# -o pipefail = exit with error if any command in a pipeline fails--
# ensures error codes from upstream calls are passed through pipes
set -euo pipefail

# Configuration
LOG_FILE="deployment_$(date +%Y%m%d_%H%M%S).log"

# Function to show usage instructions
show_usage() {
  cat << EOF
Usage: $0 -r <repo_name> -t <tag_name> [-c <conda_prefix>] [-j <jupyter_prefix>] [--dry-run] [--help]

Deploy a GitHub repo to a new Conda environment and JupyterHub kernel.

Required options:
  -r, --repo <repo_name>              GitHub repository name (e.g., MyUser/my-repo)
  -t, --tag <tag_name>                Git tag or branch to deploy (e.g., 2025.05.1+testdeploy)

Optional options:
  -c, --conda-prefix <conda_dir>      Directory in which to install the conda environment
                                      (e.g., /bin/envs). Necessary for installing
                                      environments to a system-wide shared location.
  -j, --jupyter-prefix <jupyter_dir>  Directory in which to install the Jupyter kernel spec
                                      (e.g., /shared/local). Necessary for installing
                                      kernels to a system-wide shared location.
  -d, --dry-run                        Show what would happen without making changes
  -h, --help                          Show this help message and exit

Examples:
  $0 -r MyUser/my-repo -t 2025.05.1+testdeploy
  $0 -r MyUser/my-repo -c /bin/envs -j /shared/local -t 2025.05.1+testdeploy --dry-run
EOF
  exit 1
}

parse_args() {
  # Default values
  GITHUB_REPO=""
  DEPLOY_TAG=""
  KERNEL_PREFIX=""
  CONDA_PREFIX=""
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--repo)
        GITHUB_REPO="$2"
        shift 2
        ;;
      -j|--jupyter-prefix)
        KERNEL_PREFIX="$2"
        KERNEL_PREFIX=$(echo "$KERNEL_PREFIX" | sed 's:/*$::') # Remove trailing slashes
        shift 2
        ;;
      -c|--conda-prefix)
        CONDA_PREFIX="$2"
        CONDA_PREFIX=$(echo "$CONDA_PREFIX" | sed 's:/*$::') # Remove trailing slashes
        shift 2
        ;;
      -t|--tag)
        DEPLOY_TAG="$2"
        shift 2
        ;;
      -d|--dry-run)
        DRY_RUN=true
        log "INFO" "Dry run mode enabled - no changes will be made"
        shift
        ;;
      -h|--help)
        show_usage
        ;;
      *)
        echo "Unrecognized input: $1"
        show_usage
        ;;
    esac
  done

  # Validate required arguments
  if [[ -z "$GITHUB_REPO" || -z "$DEPLOY_TAG" ]]; then
    echo "Error: --repo and --tag are required."
    show_usage
  fi
}

# Log message with level
log() {
  local level=$1
  local message=$2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Initialize logging
setup_logging() {
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "INFO" "Starting deployment script..."
}

# Exit with error message
error_exit() {
  log "ERROR" "$1"
  exit 1
}

# Check dependencies
check_dependencies() {
  log "INFO" "Checking dependencies..."
  
  # NB: these are just the dependencies to run this script, not
  # the dependencies for the lab notebooks
  for cmd in conda git python; do
    if ! command -v $cmd &> /dev/null; then
      error_exit "Required command not found: $cmd"
    fi
  done
  
  log "INFO" "All dependencies are available"
}

# Format kernels directory path
format_kernels_dir() {
  local a_kernel_prefix="$1"
  local kernels_dir=""
  if [[ -n "$a_kernel_prefix" ]]; then
    kernels_dir="$a_kernel_prefix/share/jupyter/kernels"
  fi
  echo "$kernels_dir"
}


# Check if kernel exists
kernel_exists() {
  local kernel_name=$1

  # if jupyter is available, use it to check for kernel existence since it
  # will look in all the relevant places
  if command -v jupyter &> /dev/null; then
    local kernel_names
    # Extract kernel names
    kernel_names=$(jupyter kernelspec list | tail -n +2 | awk '{print $1}')

    # Check if kernel_name exists in the list;
    # -F = fixed string, not regex
    # -x = matches whole line (exact match)
    # -q = quiet mode, no output, just exit status
    if echo "$kernel_names" | grep -Fxq "$kernel_name"; then
        echo 1 # Kernel exists
        return 0  # Function succeeded
    fi
  else
    # Check just in the specified kernel location, if one was provided
    local formatted_kernel_dir=""
    formatted_kernel_dir=$(format_kernels_dir "$KERNEL_PREFIX")
    if [[ -n "$formatted_kernel_dir" ]]; then
      if [ ! -d "$formatted_kernel_dir" ]; then
          # a kernel prefix was specified but it isn't a valid directory
          return 1
      fi

      # Get all directories in the kernels directory under the specified prefix
      for dir in "$formatted_kernel_dir"/*; do
          if [ -d "$dir" ]; then
              # Extract just the kernel name (basename)
              local name=""
              name=$(basename "$dir")

              # Check if it matches the input
              if [ "$name" = "$kernel_name" ]; then
                  echo 1 # Kernel exists
                  return 0  # Function succeeded
              fi
          fi
      done
    fi
  fi

  echo 0 # Kernel does not exist
  return 0  # Function succeeded
}

# Create and set up new environment
setup_new_environment() {
  # Create environment name based on deploy type
  log "INFO" "Setting up new environment '$DEPLOY_NAME'..."

  local conda_install_cmd
  local repo_install_cmd
  local kernel_install_cmd

  # CONDA_LOC_CMD is set in the main function, before this call
  log "INFO" "Creating conda environment with ${CONDA_LOC_CMD[*]}"

  if [ "$DRY_RUN" = true ]; then
    log "INFO" "DRY RUN: Would create conda environment"
    log "INFO" "DRY RUN: Would install requirements and repo '$GITHUB_REPO'"
    log "INFO" "DRY RUN: Would install kernel '$DEPLOY_NAME'"
    return
  fi

  # Clone the repository to get requirements
  TEMP_DIR=$(mktemp -d)
  log "INFO" "Cloning repository to get requirements..."

  # Note that lightweight cloning (e.g. --depth 1) that leaves out full history only works for lightweight (not annotated) tags
  GITHUB_URL="https://github.com/$GITHUB_REPO"
  git clone --depth 1 --branch "$DEPLOY_TAG" "$GITHUB_URL" "$TEMP_DIR"

  # Create new conda environment from environment.yml
  if [ -f "$TEMP_DIR/environment.yml" ]; then
    log "INFO" "Found environment.yml, installing conda environment and dependencies..."
    conda_install_cmd=(conda env create --file "$TEMP_DIR/environment.yml" "${CONDA_LOC_CMD[@]}")
    if ! "${conda_install_cmd[@]}"; then
      report "Failed to install from environment.yml"
    fi
  else
    report "Could not find environment.yml"
  fi

  # Install the repo
  log "INFO" "Installing repo $GITHUB_REPO"
  repo_install_cmd=(conda run "${CONDA_LOC_CMD[@]}" pip install "git+$GITHUB_URL@$DEPLOY_TAG")
  if ! "${repo_install_cmd[@]}"; then
    rollback "Failed to install repo" "$GITHUB_REPO"
  fi

  # Install the kernel; send to user-specified directory iff KERNEL_PREFIX is set else to new conda env
  if [ -z "$KERNEL_PREFIX" ]; then
    KERNEL_PREFIX=$(conda run "${CONDA_LOC_CMD[@]}" python -c 'import sys; print(sys.prefix)')
  fi
  log "INFO" "Installing kernel $DEPLOY_NAME in $KERNEL_PREFIX ..."
  kernel_install_cmd=(conda run "${CONDA_LOC_CMD[@]}" python -m ipykernel install --name="$DEPLOY_NAME" --display-name="$DEPLOY_NAME" --prefix="$KERNEL_PREFIX")
  if ! "${kernel_install_cmd[@]}"; then
    rollback "Failed to install kernel" "$DEPLOY_NAME"
  fi

  # Clean up
  rm -rf "$TEMP_DIR"
}

# Verify a newly installed environment
verify_environment() {
  local env_name=$1
  local kernel_name=$2
  
  log "INFO" "Verifying environment '$env_name' and kernel '$kernel_name'..."

  # Check if environment exists
  if [[ -n "$CONDA_PREFIX" ]]; then
    if [ ! -d "$CONDA_PATH/conda-meta" ]; then
      log "ERROR" "Conda environment not found at prefix: $CONDA_PATH"
      return 1
    fi
  else
    if ! conda info --envs | awk '{print $1}' | grep -Fxq "$env_name"; then
      log "ERROR" "Named conda environment '$env_name' not found"
      return 1
    fi
  fi
  
  # Check if kernel we just tried to create in fact exists now
  log "INFO" "Checking if kernel '$kernel_name' exists for prefix '$KERNEL_PREFIX'..."
  exists=$(kernel_exists "$kernel_name")
  if [ $? -ne 0 ]; then
    log "ERROR" "Error checking kernel existence"
    return 1
  elif [ "$exists" -eq 0 ]; then
    log "ERROR" "Kernel '$kernel_name' not found"
    return 1
  fi

  # Create a temporary notebook to verify the kernel
  TEMP_DIR=$(mktemp -d)
  TEMP_NOTEBOOK="$TEMP_DIR/deploy_test.ipynb"
  cat > "$TEMP_NOTEBOOK" << EOF
{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": null,
   "id": "c59cc569-40ad-4881-acde-f4099e79edbf",
   "metadata": {},
   "outputs": [],
   "source": [
    "print('Kernel verification successful')"
   ]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "$kernel_name",
   "language": "python",
   "name": "$kernel_name"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}
EOF

  log "INFO" "Executing temporary notebook '$TEMP_NOTEBOOK'..."

  local return_value
  local notebook_cmd=(conda run "${CONDA_LOC_CMD[@]}" jupyter nbconvert --to notebook --execute --ExecutePreprocessor.timeout=60 "$TEMP_NOTEBOOK")
  if ! "${notebook_cmd[@]}"; then
    log "ERROR" "Kernel verification failed - kernel could not execute notebook"

    log "WARNING" "Removing kernel '$kernel_name' due to error ..."
    jupyter kernelspec remove -f "$kernel_name"
    return_value=1
  else
    log "INFO" "Environment and kernel verification successful"
    return_value=0
  fi

  rm -r "$TEMP_DIR"
  return $return_value
}

# Report if deployment fails
report() {
  local message=$1
  error_exit "Deployment failed: $message"
}

# Undo creation of environment if downstream steps fail
rollback() {
    local message=$1
    local deploy_name=$2

    log "WARNING" "Removing conda environment '$deploy_name' due to error..."
    local conda_remove_cmd
    conda_remove_cmd=(conda env remove "${CONDA_LOC_CMD[@]}" --yes)
    if ! "${conda_remove_cmd[@]}"; then
      log "WARNING" "Failed to remove environment with ${CONDA_LOC_CMD[*]}"
    fi
    report "$message"
}

# Main function
main() {
  parse_args "$@"

  setup_logging
  check_dependencies
  
  log "INFO" "Starting deployment for tag '$DEPLOY_TAG'..."

  # Replace literal periods (.) and plus signs (+) in the tag name with underscores (_)
  DEPLOY_NAME=$(echo "$DEPLOY_TAG" | sed 's/[.+]/_/g')
  CONDA_LOC_CMD=(-n "$DEPLOY_NAME")
  if [[ -n "$CONDA_PREFIX" ]]; then
    CONDA_PATH="$CONDA_PREFIX/$DEPLOY_NAME"
    CONDA_LOC_CMD=(-p "$CONDA_PATH")
  fi
  
  # Check for existing kernel iff a kernel prefix is provided
  if [[ -n "$KERNEL_PREFIX" ]]; then
    log "INFO" "Checking for pre-existing kernel '$DEPLOY_NAME'..."
    exists=$(kernel_exists "$DEPLOY_NAME")
    if [ $? -ne 0 ]; then
      error_exit "Error checking kernel existence"
    elif [ "$exists" -eq 1 ]; then
      error_exit "Kernel '$DEPLOY_NAME' already exists"
    fi
  fi
  
  # Set up new environment
  setup_new_environment
  
  # Verify the new environment and kernel
  if [ "$DRY_RUN" = false ]; then
    log "INFO" "Verifying new environment..."
    # NB: double use of "$DEPLOY_NAME" is NOT a typo :)
    if ! verify_environment "$DEPLOY_NAME" "$DEPLOY_NAME"; then
      rollback "Environment verification failed" "$DEPLOY_NAME"
    fi
  else
    log "INFO" "DRY RUN: Would verify environment '$DEPLOY_NAME' and kernel '$DEPLOY_NAME'"
  fi
  
  log "INFO" "Deployment successful!"
  log "INFO" "New kernel '$DEPLOY_NAME' is using conda environment '$DEPLOY_NAME'"
  log "INFO" "Log file: $LOG_FILE"
  exit 0
}

# Execute main function with all arguments
main "$@"
