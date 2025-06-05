#!/bin/bash

#########################################################################
# JupyterHub Environment and Kernel Deployment Script
#
# Purpose:
#   Deploy a github repo to a new conda environment and JupyterHub kernel
#   - Implements verification and logging capabilities
#
# Usage:
# bash  ./deploy.sh -r <repo_name> -t <tag_name> [-c <conda_prefix>] [-j <jupyter_prefix>] [--dry-run] [--help]
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
  -d, --dry-run                       Show what would happen without making changes
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
  # capture any stdout and append to a log file while
  # *also* writing to the screen; do the same with stderr
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "INFO" "Starting deployment script..."
}

# Exit with error message and report deployment failure
error_exit() {
  local message=$1
  log "ERROR" "Deployment failed: $message"
  exit 1
}

# Check dependencies
check_dependencies() {
  log "INFO" "Checking dependencies..."
  
  # NB: these are just the dependencies to run this script, not
  # the dependencies for the lab notebooks
  for cmd in conda git python; do
    # check if command is available in shell's $PATH;
    # don't want the output (path to command)--just the exit code
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
  # will look in all the relevant places; this is preferable because jupyter
  # DOES allow multiple kernels with the same name to exist in different
  # locations, and it silently returns the first one it finds based on its
  # internal search order, which could lead to very confusing bugs--so if
  # ANY path that jupyter checks contains a kernel of the specified name,
  # we want to refuse to make another one with the same name
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
    # If jupyter is not available, we have to fall back to the only method
    # left to us, which is to check that there's no kernel of the specified
    # name in the kernel directory the user specified--if they did specify
    # one.  If they didn't, we're basically out of luck for checking and
    # will just assume the kernel doesn't exist.
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

# Undo creation of environment if downstream steps fail
rollback() {
    local message=$1
    local deploy_name=$2

    log "WARNING" "Removing conda environment '$deploy_name' due to error..."
    local conda_remove_cmd
    # CONDA_LOC_CMD is set in the main function, before this call
    conda_remove_cmd=(conda env remove "${CONDA_LOC_CMD[@]}" --yes)
    if ! "${conda_remove_cmd[@]}"; then
      log "WARNING" "Failed to remove environment with ${CONDA_LOC_CMD[*]}"
    fi
    error_exit "$message"
}

# Create and set up new environment
setup_new_environment() {
  # Create environment name based on deploy type
  log "INFO" "Setting up new environment '$DEPLOY_NAME'..."

  local conda_install_cmd
  local repo_install_cmd
  local kernel_install_cmd

  # CONDA_LOC_CMD is set in the main function, before this function is called
  log "INFO" "Creating conda environment with ${CONDA_LOC_CMD[*]}"

  if [ "$DRY_RUN" = true ]; then
    log "INFO" "DRY RUN: Would create conda environment"
    log "INFO" "DRY RUN: Would install requirements and repo '$GITHUB_REPO'"
    log "INFO" "DRY RUN: Would install kernel '$DEPLOY_NAME'"
    return
  fi

  # Clone the repository to get requirements
  log "INFO" "Cloning repository to get requirements..."
  # Note that lightweight cloning (e.g. --depth 1) that leaves out full history only works for lightweight (not annotated) tags
  GITHUB_URL="https://github.com/$GITHUB_REPO"
  git clone --depth 1 --branch "$DEPLOY_TAG" "$GITHUB_URL" "$SETUP_TEMP_DIR"

  # Create new conda environment from environment.yml
  local env_yml_path
  env_yml_path="$SETUP_TEMP_DIR/environment.yml"
  if [ -f "$env_yml_path" ]; then
    log "INFO" "Found environment.yml, installing conda environment and dependencies..."
    conda_install_cmd=(conda env create --file "$env_yml_path" "${CONDA_LOC_CMD[@]}")
    if ! "${conda_install_cmd[@]}"; then
      error_exit "Failed to install from environment.yml"
    fi
  else
    error_exit "Could not find environment.yml"
  fi

  # Failures before this point just report an error and exit;
  # after this point, we need to roll back the environment creation
  # if anything fails.  Note that kernel rollback (if necessary) is handled
  # in the verify_environment function, which is called after this one.

  # Install the repo
  log "INFO" "Installing repo $GITHUB_REPO"
  repo_install_cmd=(conda run "${CONDA_LOC_CMD[@]}" pip install "git+$GITHUB_URL@$DEPLOY_TAG")
  if ! "${repo_install_cmd[@]}"; then
    rollback "Failed to install repo" "$GITHUB_REPO"
  fi

  # Install the kernel; send to user-specified directory iff KERNEL_PREFIX is set else to new conda env
  # Note that for all code running after this point, $KERNEL_PREFIX will ALWAYS be set (to something)
  if [ -z "$KERNEL_PREFIX" ]; then
    KERNEL_PREFIX=$(conda run "${CONDA_LOC_CMD[@]}" python -c 'import sys; print(sys.prefix)')
  fi
  log "INFO" "Installing kernel $DEPLOY_NAME in $KERNEL_PREFIX ..."
  kernel_install_cmd=(conda run "${CONDA_LOC_CMD[@]}" python -m ipykernel install --name="$DEPLOY_NAME" --display-name="$DEPLOY_NAME" --prefix="$KERNEL_PREFIX")
  if ! "${kernel_install_cmd[@]}"; then
    rollback "Failed to install kernel" "$DEPLOY_NAME"
  fi
}

# Verify a newly installed environment
verify_environment() {
  local env_name=$1
  local kernel_name=$2
  
  log "INFO" "Verifying environment '$env_name' and kernel '$kernel_name'..."

  # Check if environment exists; if it is a prefix-based environment,
  # we have to look at the directory directly; if it is a named environment,
  # we can use conda info --envs to check for its existence
  if [[ -n "$CONDA_PREFIX" ]]; then
    if [ ! -d "$CONDA_PATH/conda-meta" ]; then
      log "ERROR" "Conda environment not found at prefix: $CONDA_PATH"
      return 1
    fi
  else
    # extract first column of conda info --envs output and match:
    # -F = fixed string, not regex
    # -x = matches whole line (exact match)
    # -q = quiet mode, no output, just exit status
    if ! conda info --envs | awk '{print $1}' | grep -Fxq "$env_name"; then
      log "ERROR" "Named conda environment '$env_name' not found"
      return 1
    fi
  fi
  
  # Check if kernel we just tried to create in fact exists now
  log "INFO" "Checking if kernel '$kernel_name' exists for prefix '$KERNEL_PREFIX'..."
  exists=$(kernel_exists "$kernel_name")
  # $? holds the exit code of the last command executed
  if [ $? -ne 0 ]; then
    log "ERROR" "Error checking kernel existence"
    return 1
  elif [ "$exists" -eq 0 ]; then
    log "ERROR" "Kernel '$kernel_name' not found"
    return 1
  fi

  # Create a temporary notebook to verify the kernel
  local temp_notebook
  temp_notebook="$VERIFY_TEMP_DIR/deploy_test.ipynb"
  cat > "$temp_notebook" << EOF
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

  log "INFO" "Executing temporary notebook '$temp_notebook'..."

  local return_value
  # CONDA_LOC_CMD is set in the main function, before this function is called
  local notebook_cmd=(conda run "${CONDA_LOC_CMD[@]}" jupyter nbconvert --to notebook --execute --ExecutePreprocessor.timeout=60 "$temp_notebook")
  if ! "${notebook_cmd[@]}"; then
    log "ERROR" "Kernel verification failed - kernel could not execute notebook"

    log "WARNING" "Removing kernel '$kernel_name' due to error ..."
    jupyter kernelspec remove -f "$kernel_name"
    return_value=1
  else
    log "INFO" "Environment and kernel verification successful"
    return_value=0
  fi

  return $return_value
}

# Main function
main() {
  parse_args "$@"

  setup_logging
  check_dependencies
  
  log "INFO" "Starting deployment for tag '$DEPLOY_TAG'..."

  # Replace literal periods (.) and plus signs (+) in the tag name with underscores (_)
  DEPLOY_NAME=$(echo "$DEPLOY_TAG" | sed 's/[.+]/_/g')

  # Decide whether the new conda environment will be created as a named
  # environment in the default location or as a prefix-based environment
  # at the user-specified path
  CONDA_LOC_CMD=(-n "$DEPLOY_NAME")
  # Note: CONDA_PREFIX is the user-specified directory into which to add a new
  # conda environment (if they specified one); if they did, then the
  # CONDA_PATH is set to be the user-specified path plus the environment name,
  # which is the actual location into which the environment will be installed.
  if [[ -n "$CONDA_PREFIX" ]]; then
    CONDA_PATH="$CONDA_PREFIX/$DEPLOY_NAME"
    CONDA_LOC_CMD=(-p "$CONDA_PATH")
  fi
  
  # Check for existing kernel with the same name and error out if it exists
  log "INFO" "Checking for pre-existing kernel '$DEPLOY_NAME'..."
  exists=$(kernel_exists "$DEPLOY_NAME")
  if [ $? -ne 0 ]; then
    error_exit "Error checking kernel existence"
  elif [ "$exists" -eq 1 ]; then
    error_exit "Kernel '$DEPLOY_NAME' already exists"
  fi
  
  # Create a temp directory to hold the setup files and ensure it is cleaned up
  # on exit, then set up the new environment
  SETUP_TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$SETUP_TEMP_DIR"' EXIT
  setup_new_environment
  
  # Verify the new environment and kernel
  if [ "$DRY_RUN" = false ]; then
    # Create a temp directory for verification files and ensure it is cleaned
    # up on exit, then verify the new environment.  NOT using the same temp
    # directory as the one used for setup to ensure that the verification
    # isn't incorrectly depending on any of the setup files.
    VERIFY_TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$SETUP_TEMP_DIR"; rm -rf "$VERIFY_TEMP_DIR"' EXIT

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
