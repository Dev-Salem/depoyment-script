#!/bin/bash
# This script prepares the environment for the main deployment script

# Check for required system commands
check_requirements() {
  local missing_cmds=()
  
  for cmd in git node npm jq nginx pm2 certbot; do
    if ! command -v $cmd &> /dev/null; then
      missing_cmds+=($cmd)
    fi
  done
  
  if [ ${#missing_cmds[@]} -gt 0 ]; then
    echo "ERROR: The following required commands are missing:"
    printf "  - %s\n" "${missing_cmds[@]}"
    echo "Please install them before proceeding with deployment."
    exit 1
  fi
  
  echo "✓ All required commands are available"
}

# Ensure target directories exist
prepare_directories() {
  mkdir -p /var/www
  mkdir -p /var/www/logs
  
  # Ensure proper permissions
  chmod 755 /var/www
}

# Run checks
check_requirements
prepare_directories

echo "Environment is ready for deployment"
