#!/bin/bash

# Enable error handling
set -e

# Capture all arguments from environment variables
PROJECT_NAME="$PROJECT_NAME"
PROJECT_REPO="$PROJECT_REPO"
PROJECT_DOMAIN="$PROJECT_DOMAIN"
PROJECT_PORT="$PROJECT_PORT"
PM2_FILE_TYPE="${PM2_FILE_TYPE:-cjs}"
SSL_EMAIL="$SSL_EMAIL"

# Function for error handling
handle_error() {
  echo "ERROR: Deployment failed at step: $1"
  exit 1
}

# Function to validate required environment variables
validate_required_vars() {
  local missing_vars=()
  
  # Check each required environment variable
  # Server access credentials are handled by SSH action
  
  # Project configuration
  [ -z "$PROJECT_NAME" ] && missing_vars+=("PROJECT_NAME")
  [ -z "$PROJECT_REPO" ] && missing_vars+=("PROJECT_REPO")
  [ -z "$PROJECT_DOMAIN" ] && missing_vars+=("PROJECT_DOMAIN")
  
  # Application configuration
  [ -z "$ENV_FILE_CONTENT" ] && missing_vars+=("ENV_FILE_CONTENT")
  [ -z "$PM2_ENV_VARS" ] && missing_vars+=("PM2_ENV_VARS")
  
  # SSL configuration
  [ -z "$SSL_EMAIL" ] && missing_vars+=("SSL_EMAIL")
  
  # If any variables are missing, print error and exit
  if [ ${#missing_vars[@]} -gt 0 ]; then
    echo "ERROR: The following required environment variables are missing:"
    printf "  - %s\n" "${missing_vars[@]}"
    exit 1
  fi
  
  echo "✓ All required environment variables are available"
}

# Validate environment variables before proceeding
validate_required_vars

# Function to find an available port or use the assigned one
find_available_port() {
  local project_name=$1
  local preferred_port=$2
  local port_config_file="/var/www/port_mappings.json"
  local min_port=3000
  local max_port=4000
  
  # Create port mapping file if it doesn't exist
  if [ ! -f "$port_config_file" ]; then
    echo "{}" > "$port_config_file"
  fi
  
  # Check if this project already has an assigned port
  local assigned_port=$(jq -r ".[\"$project_name\"] // \"\"" "$port_config_file")
  
  if [ -n "$assigned_port" ] && [ "$assigned_port" != "null" ]; then
    echo "Project has previously assigned port: $assigned_port"
    # Verify the port is still available
    if ! netstat -tuln | grep -q ":$assigned_port "; then
      echo "Using previously assigned port: $assigned_port"
      return $assigned_port
    else
      echo "Previously assigned port $assigned_port is now in use by another process"
    fi
  fi
  
  # Use preferred port if specified and available
  if [ -n "$preferred_port" ] && ! netstat -tuln | grep -q ":$preferred_port "; then
    # Update port mapping file
    jq ".[\"$project_name\"] = \"$preferred_port\"" "$port_config_file" > "$port_config_file.tmp" && 
    mv "$port_config_file.tmp" "$port_config_file"
    echo "Using preferred port: $preferred_port"
    return $preferred_port
  fi
  
  # Find an available port in the range
  for port in $(seq $min_port $max_port); do
    if ! netstat -tuln | grep -q ":$port "; then
      # Update port mapping file
      jq ".[\"$project_name\"] = \"$port\"" "$port_config_file" > "$port_config_file.tmp" && 
      mv "$port_config_file.tmp" "$port_config_file"
      echo "Assigned new port: $port"
      return $port
    fi
  done
  
  echo "ERROR: No available ports found in range $min_port-$max_port"
  exit 1
}

# Get port dynamically or use preferred port from env var if available
PORT=$(find_available_port "$PROJECT_NAME" "$PROJECT_PORT")
export PORT

echo "Using port $PORT for $PROJECT_NAME"
export PROJECT_PATH="/var/www/${PROJECT_NAME}"

# ----- UTILITY FUNCTIONS -----

# Function to safely backup a file before changing it
safe_backup() {
  local FILE="$1"
  if [ -f "$FILE" ]; then
    cp "$FILE" "${FILE}.bak" || echo "WARNING: Failed to backup $FILE"
    return 0
  fi
  return 1  # File didn't exist
}

# Function to track state of various components before changes
track_deployment_state() {
  # Empty the state variables
  export ENV_CREATED=
  export PM2_CONFIG_CREATED=
  export NGINX_CONFIG_CREATED=
  export PM2_EXISTED=
  export BUILD_EXISTED=
  
  # Check if environment file exists
  [ ! -f "$PROJECT_PATH/.env" ] && ENV_CREATED="true"
  
  # Check if PM2 config exists
  [ ! -f "$PROJECT_PATH/$PM2_FILE" ] && PM2_CONFIG_CREATED="true"
  
  # Check if Nginx config exists
  [ ! -f "/etc/nginx/sites-available/${PROJECT_NAME}" ] && NGINX_CONFIG_CREATED="true"
  
  # Check if PM2 process exists
  pm2 list | grep -q "$PROJECT_NAME" && PM2_EXISTED="true"
  
  # Check if build directory exists
  [ -d "$PROJECT_PATH/.next" ] && BUILD_EXISTED="true" && 
    # Backup the build only if it exists
    cp -a "$PROJECT_PATH/.next" "$PROJECT_PATH/.next.bak" 2>/dev/null || :
  
  # Ensure the logs directory exists for all potential state information
  mkdir -p "$PROJECT_PATH/logs"
}

# ----- ROLLBACK MECHANISM -----
# This function is called by the trap on ERR signal or explicitly
rollback() {
  local EXIT_CODE=${2:-$?}  # Use provided exit code or default to $?
  local STEP=$1
  local BACKUP_DIR="/tmp/${PROJECT_NAME}_rollback_$(date +%s)"
  
  echo "ERROR: Deployment failed at step: $STEP with exit code: $EXIT_CODE"
  echo "Starting enhanced rollback procedure..."
  
  # Create backup directory for any files we need to save during rollback
  mkdir -p "$BACKUP_DIR" || echo "WARNING: Failed to create backup directory, continuing anyway"
  
  # Log the failure for later analysis
  {
    echo "===== DEPLOYMENT FAILURE REPORT ====="
    echo "Timestamp: $(date)"
    echo "Project: $PROJECT_NAME"
    echo "Domain: $PROJECT_DOMAIN"
    echo "Failed step: $STEP"
    echo "Exit code: $EXIT_CODE"
    echo "Working directory: $(pwd)"
    echo "--------------------------------"
    echo "Environment state:"
    env | grep -v "SECRET\|PASSWORD\|KEY" | sort  # Exclude sensitive information
    echo "--------------------------------"
    echo "Last 20 lines of command output:"
    tail -n 20 /tmp/deployment_output_$$.log 2>/dev/null || echo "No output log found"
    echo "===== END REPORT ====="
  } > "$BACKUP_DIR/failure_report.log"
  
  # Copy the report to the project logs directory if it exists
  if [ -d "${PROJECT_PATH}/logs" ]; then
    cp "$BACKUP_DIR/failure_report.log" "${PROJECT_PATH}/logs/deployment_failure_$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || :
  fi
  
  case $STEP in
    "repository")
      echo "Rolling back repository changes..."
      if [ -d "$PROJECT_PATH" ]; then
        if [ ! -d "$PROJECT_PATH/.git" ]; then
          # Remove directory if it was just created without git initialization
          echo "Removing incomplete project directory"
          rm -rf "$PROJECT_PATH"
        elif [ -f "$PROJECT_PATH/.git/ORIG_HEAD" ]; then
          # Reset to previous state if git pull failed
          echo "Resetting git repository to previous state"
          (cd "$PROJECT_PATH" && git reset --hard ORIG_HEAD && 
           git clean -fd && echo "Repository successfully reset")
        elif [ -f "$PROJECT_PATH/.git/refs/tags/deployment-backup" ]; then
          # Try to use the deployment-backup tag if it exists
          echo "Attempting to restore from deployment backup tag"
          (cd "$PROJECT_PATH" && git reset --hard deployment-backup &&
           git clean -fd && echo "Repository reset to backup tag")
        else
          # No clean way to roll back - save current state and warn
          echo "WARNING: No clean repository rollback point available"
          echo "Current state preserved in $PROJECT_PATH"
        fi
      fi
      ;;
      
    "build")
      echo "Rolling back failed build..."
      # Check for backup of previous build
      if [ -d "$PROJECT_PATH/.next.bak" ]; then
        echo "Restoring previous build from backup"
        rm -rf "$PROJECT_PATH/.next" 2>/dev/null || :
        mv "$PROJECT_PATH/.next.bak" "$PROJECT_PATH/.next"
        echo "Previous build restored"
      else
        # Try to clean up failed build artifacts
        echo "No build backup found, cleaning up failed build artifacts"
        rm -rf "$PROJECT_PATH/.next" 2>/dev/null || :
        rm -rf "$PROJECT_PATH/.next-*" 2>/dev/null || :
        rm -rf "$PROJECT_PATH/node_modules/.cache" 2>/dev/null || :
        echo "Build artifacts cleaned up"
      fi
      ;;
      
    "dependencies")
      echo "Rolling back dependency installation..."
      if [ -d "$PROJECT_PATH/node_modules.bak" ]; then
        echo "Restoring previous node_modules from backup"
        rm -rf "$PROJECT_PATH/node_modules"
        mv "$PROJECT_PATH/node_modules.bak" "$PROJECT_PATH/node_modules"
        echo "Previous node_modules restored"
      else
        echo "No node_modules backup found, removing failed installation"
        rm -rf "$PROJECT_PATH/node_modules"
        echo "Clean slate for future dependency installation"
      fi
      
      # Also check if package-lock.json was modified
      if [ -f "$PROJECT_PATH/package-lock.json.bak" ]; then
        echo "Restoring previous package-lock.json"
        mv "$PROJECT_PATH/package-lock.json.bak" "$PROJECT_PATH/package-lock.json"
      fi
      ;;
      
    "config")
      echo "Rolling back configuration changes..."
      # Restore .env if backup exists
      if [ -f "$PROJECT_PATH/.env.bak" ]; then
        echo "Restoring previous .env file"
        mv "$PROJECT_PATH/.env.bak" "$PROJECT_PATH/.env" && echo "Restored .env file"
      elif [ -f "$PROJECT_PATH/.env" ] && [ -n "$ENV_CREATED" ]; then
        echo "Removing newly created .env file"
        rm "$PROJECT_PATH/.env"
      fi
      
      # Restore PM2 config if backup exists
      if [ -f "$PROJECT_PATH/$PM2_FILE.bak" ]; then
        echo "Restoring previous PM2 config"
        mv "$PROJECT_PATH/$PM2_FILE.bak" "$PROJECT_PATH/$PM2_FILE" && echo "Restored PM2 config"
      elif [ -f "$PROJECT_PATH/$PM2_FILE" ] && [ -n "$PM2_CONFIG_CREATED" ]; then
        echo "Removing newly created PM2 config"
        rm "$PROJECT_PATH/$PM2_FILE"
      fi
      ;;
      
    "nginx")
      echo "Rolling back Nginx configuration..."
      # Check for backup of existing config
      if [ -f "/etc/nginx/sites-available/${PROJECT_NAME}.bak" ]; then
        echo "Restoring previous Nginx config from backup"
        sudo mv "/etc/nginx/sites-available/${PROJECT_NAME}.bak" "/etc/nginx/sites-available/${PROJECT_NAME}"
        echo "Ensuring Nginx config is valid..."
        if ! sudo nginx -t &>/dev/null; then
          echo "WARNING: Restored Nginx config is invalid, removing it for safety"
          sudo rm -f "/etc/nginx/sites-available/${PROJECT_NAME}"
          [ -L "/etc/nginx/sites-enabled/${PROJECT_NAME}" ] && sudo rm -f "/etc/nginx/sites-enabled/${PROJECT_NAME}"
        else
          echo "Restored Nginx config is valid"
        fi
      elif [ -f "/etc/nginx/sites-available/${PROJECT_NAME}" ] && [ -n "$NGINX_CONFIG_CREATED" ]; then
        # If Nginx config was newly created and failed, remove it
        echo "Removing newly created Nginx config"
        sudo rm -f "/etc/nginx/sites-available/${PROJECT_NAME}"
        if [ -L "/etc/nginx/sites-enabled/${PROJECT_NAME}" ]; then
          echo "Removing symbolic link"
          sudo rm -f "/etc/nginx/sites-enabled/${PROJECT_NAME}"
        fi
      fi
      
      # Always try to reload Nginx if it's running
      if systemctl is-active --quiet nginx; then
        echo "Reloading Nginx to apply rollback changes"
        sudo systemctl reload nginx || echo "WARNING: Nginx reload failed, may need manual intervention"
      fi
      ;;
      
    "pm2")
      echo "Rolling back PM2 process changes..."
      
      # Store PM2 state before we make changes
      pm2 list --no-interaction > "$BACKUP_DIR/pm2_state.txt" 2>/dev/null || :
      
      # Different handling based on whether the PM2 process existed before
      if pm2 list | grep -q "$PROJECT_NAME"; then
        if [ -n "$PM2_EXISTED" ]; then
          # Process existed before, try to restore it from backup config
          echo "Restoring existing PM2 process"
          if [ -f "$PROJECT_PATH/$PM2_FILE.bak" ]; then
            echo "Using backup PM2 config"
            mv "$PROJECT_PATH/$PM2_FILE.bak" "$PROJECT_PATH/$PM2_FILE"
            # Try reload first, fall back to restart
            pm2 reload "$PROJECT_NAME" --update-env || 
              pm2 restart "$PROJECT_NAME" --update-env ||
              echo "WARNING: Failed to restore PM2 process, manual restart may be required"
          else
            echo "No PM2 config backup found, attempting general restart"
            pm2 restart "$PROJECT_NAME" || echo "WARNING: Failed to restart PM2 process"
          fi
        else
          # Process was newly created during this deployment, remove it
          echo "Removing newly created PM2 process"
          pm2 delete "$PROJECT_NAME" || echo "WARNING: Failed to delete PM2 process"
        fi
        
        # Always save PM2 configuration after changes
        pm2 save 2>/dev/null || echo "WARNING: Failed to save PM2 process list"
      else
        echo "No active PM2 process found for $PROJECT_NAME"
      fi
      ;;
      
    "ssl")
      echo "Rolling back SSL certificate changes..."
      # SSL rollback is complex and potentially dangerous
      echo "SSL changes cannot be safely rolled back automatically"
      echo "If there were SSL errors, manual intervention may be required"
      echo "Previous SSL certificates should still be available in /etc/letsencrypt/archive"
      ;;
      
    "unexpected")
      echo "Handling unexpected failure..."
      # Try to determine the context based on working directory and files
      if [ "$(pwd)" = "$PROJECT_PATH" ]; then
        echo "Failure occurred while in project directory"
        
        # Check for possible failure contexts
        if [ -f "package.json" ] && [ -d "node_modules" ] && [ ! -d ".next" ]; then
          echo "Appears to be during dependency or build phase"
          # Clean up potential partial build artifacts
          rm -rf .next-* 2>/dev/null || :
          rm -rf .next 2>/dev/null || :
        fi
      fi
      
      echo "Creating recovery report in $PROJECT_PATH/logs/recovery_report.txt"
      mkdir -p "$PROJECT_PATH/logs"
      {
        echo "Recovery report generated at $(date)"
        echo "Current directory: $(pwd)"
        echo "Project state:"
        ls -la "$PROJECT_PATH" 2>/dev/null || echo "Cannot access project directory"
        echo "Running processes related to this project:"
        ps aux | grep "$PROJECT_NAME" | grep -v grep
        echo "Port usage:"
        netstat -tuln | grep ":$PORT " || echo "Port $PORT not in use"
        echo "PM2 process state:"
        pm2 list 2>/dev/null || echo "PM2 list command failed"
      } > "$PROJECT_PATH/logs/recovery_report.txt" 2>&1
      ;;
      
    *)
      echo "No specific rollback action for step: $STEP"
      echo "Manual verification of system state is recommended"
      ;;
  esac
  
  # Clean up temporary files
  echo "Cleaning up temporary files..."
  find /tmp -maxdepth 1 -name "${PROJECT_NAME}*" -type f -mmin +60 -delete 2>/dev/null || :
  
  # Final verification
  echo "Performing final verification of system state..."
  local ISSUES=0
  
  # Check if project directory exists as expected
  if [ ! -d "$PROJECT_PATH" ] && [ "$STEP" != "repository" ]; then
    echo "ERROR: Project directory missing after rollback"
    ((ISSUES++))
  fi
  
  # Check if important services are running
  if ! systemctl is-active --quiet nginx; then
    echo "WARNING: Nginx is not running after rollback"
    ((ISSUES++))
  fi
  
  # Check if port is in use when it should be (only if PM2 process should exist)
  if [ -n "$PM2_EXISTED" ] && ! netstat -tuln | grep -q ":$PORT "; then
    echo "WARNING: Application port $PORT is not in use after rollback"
    ((ISSUES++))
  fi
  
  if [ $ISSUES -gt 0 ]; then
    echo "ALERT: $ISSUES issues detected after rollback. Manual intervention may be required."
  else
    echo "System appears to be in a consistent state after rollback"
  fi
  
  # Send notification about the failure if possible
  if command -v mail >/dev/null && [ -n "$ADMIN_EMAIL" ]; then
    echo "Sending notification email about deployment failure"
    echo "Deployment of $PROJECT_NAME to $PROJECT_DOMAIN failed at step: $STEP" | 
      mail -s "Deployment Failure: $PROJECT_NAME" "$ADMIN_EMAIL" || :
  fi
  
  echo "Rollback completed. System state might require manual verification."
  exit $EXIT_CODE
}

# Replace the simple error handler with the enhanced rollback-enabled version
handle_error() {
  # Create a record of the environment and state for debugging
  export ERROR_STEP="$1"
  export ERROR_DETAILS="$2"
  export ERROR_TIME="$(date +%s)"
  
  # Capture more context about the error
  echo "Error detected in step: $ERROR_STEP"
  echo "Details: ${ERROR_DETAILS:-No additional details provided}"
  
  # Track state right before rollback to help with diagnostics
  if [ -d "$PROJECT_PATH" ]; then
    mkdir -p "$PROJECT_PATH/logs"
    {
      echo "=== Pre-rollback State ==="
      echo "Date: $(date)"
      echo "Failed step: $ERROR_STEP"
      echo "Free disk space: $(df -h / | tail -1 | awk '{print $4}')"
      echo "Memory status: $(free -h | head -2)"
      echo "Project file count: $(find "$PROJECT_PATH" -type f | wc -l) files"
      echo "Git status:"
      (cd "$PROJECT_PATH" && git status -s 2>/dev/null) || echo "Not a git repository"
      echo "========================="
    } > "$PROJECT_PATH/logs/pre_rollback_state_${ERROR_TIME}.log" 2>&1
  fi
  
  # Call the enhanced rollback function
  rollback "$ERROR_STEP" $? "${ERROR_DETAILS}"
}

# ----- MAIN DEPLOYMENT STEPS -----

# Initialize state tracking for rollback mechanism
echo "Initializing deployment state tracking..."
track_deployment_state

# Step 1: Clone or pull the latest version with error handling
echo "Checking repository..."
if [ -d "$PROJECT_PATH" ]; then
  echo "Repository exists, pulling latest changes..."
  cd $PROJECT_PATH || handle_error "repository" "Failed to change to project directory"
  git pull origin main || handle_error "repository" "Failed to pull latest code"
else
  echo "Cloning repository..."
  mkdir -p $PROJECT_PATH || handle_error "repository" "Failed to create project directory"
  
  # Handle private repository authentication if needed
  if [[ "$PROJECT_REPO" == *"git@"* ]]; then
    # Ensure SSH agent is running for private repos
    eval $(ssh-agent) > /dev/null
    ssh-add ~/.ssh/id_rsa 2>/dev/null || echo "SSH key not added, ensure keys are configured"
  fi
  
  git clone $PROJECT_REPO $PROJECT_PATH || handle_error "repository" "Failed to clone repository"
  cd $PROJECT_PATH || handle_error "repository" "Failed to change to project directory" 
fi

# Backup existing files before modifications
[ -f ".env" ] && safe_backup ".env"
[ -f "$PM2_FILE" ] && safe_backup "$PM2_FILE"
[ -f "/etc/nginx/sites-available/${PROJECT_NAME}" ] && sudo cp "/etc/nginx/sites-available/${PROJECT_NAME}" "/etc/nginx/sites-available/${PROJECT_NAME}.bak" 2>/dev/null || echo "WARNING: Failed to backup Nginx config"

# Step 2: Install dependencies
echo "Installing dependencies..."
cd $PROJECT_PATH || handle_error "dependencies" "Failed to change directory"
npm install || handle_error "dependencies" "Failed to install dependencies"

# Step 3: Create environment file from environment variables BEFORE building
echo "Checking for environment file changes..."
cat << 'EOF' > /tmp/env-new
$ENV_FILE_CONTENT
EOF

if [ ! -f ".env" ] || ! cmp -s "/tmp/env-new" ".env"; then
  echo "Creating/updating .env file..."
  cp /tmp/env-new .env || handle_error "config" "Failed to create .env file"
else
  echo ".env file unchanged"
fi
rm /tmp/env-new

# Step 4: Build the project with error handling
echo "Building project..."
npm run build || handle_error "build" "Failed to build project"

# Step 5: Configure PM2 ecosystem file
echo "Checking for PM2 config changes..."
PM2_FILE="ecosystem.config.${PM2_FILE_TYPE}"

cat << EOF > /tmp/ecosystem-new.config
module.exports = {
  apps: [
    {
      name: "${PROJECT_NAME}",
      script: "npm",
      args: "start",
      cwd: "${PROJECT_PATH}",
      env: {
        NODE_ENV: "production",
        PORT: ${PORT},
        ${PM2_ENV_VARS}
      },
      // Error log file path
      error_file: "${PROJECT_PATH}/logs/error.log",
      // Out log file path
      out_file: "${PROJECT_PATH}/logs/out.log",
      // Enable/disable watch mode
      watch: false,
      // Max memory restart (if app exceeds this, PM2 will restart it)
      max_memory_restart: "500M"
    }
  ]
};
EOF

# Create logs directory if it doesn't exist
mkdir -p "${PROJECT_PATH}/logs" || handle_error "config" "Failed to create logs directory"

# Only update if content differs or file doesn't exist
if [ ! -f "$PM2_FILE" ] || ! cmp -s "/tmp/ecosystem-new.config" "$PM2_FILE"; then
  echo "Creating/updating PM2 ecosystem config..."
  cp /tmp/ecosystem-new.config "$PM2_FILE" || handle_error "config" "Failed to create PM2 config"
else
  echo "PM2 config unchanged"
fi
rm /tmp/ecosystem-new.config

# Step 6: Create and configure Nginx - check for project-specific static dirs
echo "Checking Nginx configuration..."

# Check if custom directories exist
HAS_UPLOADS=false
if [ -d "${PROJECT_PATH}/public/uploads" ]; then
  HAS_UPLOADS=true
fi

# Create Nginx config
cat << EOF > /tmp/nginx-${PROJECT_NAME}
server {
  server_name ${PROJECT_DOMAIN};

  location / {
    proxy_pass http://localhost:${PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
EOF

# Only add uploads location if directory exists
if [ "$HAS_UPLOADS" = true ]; then
  cat << EOF >> /tmp/nginx-${PROJECT_NAME}
  
  location /uploads/ {
    alias ${PROJECT_PATH}/public/uploads/;
    access_log off;
    expires 1y;
    add_header Cache-Control "public";
  }
EOF
fi

# Next.js static files
if [ -d "${PROJECT_PATH}/.next/static" ]; then
  cat << EOF >> /tmp/nginx-${PROJECT_NAME}
  
  location /_next/static/ {
    alias ${PROJECT_PATH}/.next/static/;
    access_log off;
    expires 30d;
    add_header Cache-Control "public";
  }
EOF
fi

# Public static files
if [ -d "${PROJECT_PATH}/public/static" ]; then
  cat << EOF >> /tmp/nginx-${PROJECT_NAME}
  
  location /static/ {
    alias ${PROJECT_PATH}/public/static/;
    access_log off;
    expires 30d;
    add_header Cache-Control "public";
  }
EOF
fi

# Complete the server block
cat << EOF >> /tmp/nginx-${PROJECT_NAME}
}

server {
  listen 80;
  server_name ${PROJECT_DOMAIN};
  return 301 https://\$host\$request_uri;
}
EOF

# Check if Nginx config already exists and compare
NGINX_CONFIG_PATH="/etc/nginx/sites-available/${PROJECT_NAME}"

if [ -f "$NGINX_CONFIG_PATH" ]; then
  # Compare with existing config
  if ! cmp -s "/tmp/nginx-${PROJECT_NAME}" "$NGINX_CONFIG_PATH"; then
    echo "Nginx configuration changed, updating..."
    sudo cp /tmp/nginx-${PROJECT_NAME} "$NGINX_CONFIG_PATH" || handle_error "nginx" "Failed to update Nginx config"
  else
    echo "Nginx configuration unchanged"
  fi
else
  # Create new config
  echo "Creating new Nginx configuration..."
  sudo cp /tmp/nginx-${PROJECT_NAME} "$NGINX_CONFIG_PATH" || handle_error "nginx" "Failed to create Nginx config"
fi

rm /tmp/nginx-${PROJECT_NAME}

# Create symbolic link if not exists
if [ ! -f "/etc/nginx/sites-enabled/${PROJECT_NAME}" ]; then
  echo "Creating Nginx symbolic link..."
  sudo ln -s "$NGINX_CONFIG_PATH" "/etc/nginx/sites-enabled/${PROJECT_NAME}" || handle_error "nginx" "Failed to create symbolic link"
fi

# Test Nginx configuration
echo "Testing Nginx configuration..."
sudo nginx -t || handle_error "nginx" "Nginx configuration test failed"

# Step 7: Restart/start PM2 process and reload Nginx
echo "Starting/restarting services..."
cd $PROJECT_PATH || handle_error "pm2" "Failed to change directory"

# Start or reload PM2 process with updated environment variables
if pm2 list | grep -q "$PROJECT_NAME"; then
  echo "Reloading PM2 process with updated environment..."
  pm2 reload "$PM2_FILE" --update-env || handle_error "pm2" "Failed to reload PM2 process"
else
  echo "Starting PM2 process with fresh environment..."
  pm2 start "$PM2_FILE" --update-env || handle_error "pm2" "Failed to start PM2 process"
fi

# Save PM2 process list
pm2 save || echo "Warning: Could not save PM2 process list"

# Restart Nginx only if necessary
echo "Reloading Nginx..."
sudo systemctl reload nginx || handle_error "nginx" "Failed to reload Nginx"

# Step 8: Set up or check SSL
echo "Checking SSL certificate status..."

# Check if domain resolves to current server
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
DOMAIN_IP=$(dig +short ${PROJECT_DOMAIN} || host -t A ${PROJECT_DOMAIN} | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)

if [ -z "$DOMAIN_IP" ]; then
  echo "WARNING: Could not resolve domain ${PROJECT_DOMAIN} to an IP address"
  echo "SSL certificate may fail if domain is not properly configured"
elif [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
  echo "WARNING: Domain ${PROJECT_DOMAIN} does not point to this server's IP ($SERVER_IP)"
  echo "SSL certificate acquisition may fail"
fi

# Check if ports 80 and 443 are available for Let's Encrypt validation
if netstat -tuln | grep -q ":80 "; then
  if ! netstat -tuln | grep ":80 " | grep -q "nginx"; then
    echo "WARNING: Port 80 is in use by a service other than nginx"
    echo "Let's Encrypt validation may fail"
  fi
fi

# Check certificate existence and expiration with more portable commands
CERT_EXISTS=false
CERT_DAYS_REMAINING=0

if [ -d "/etc/letsencrypt/live/${PROJECT_DOMAIN}" ]; then
  CERT_EXISTS=true
  # More portable way to check certificate expiration
  if command -v openssl >/dev/null; then
    CERT_PATH="/etc/letsencrypt/live/${PROJECT_DOMAIN}/cert.pem"
    if [ -f "$CERT_PATH" ]; then
      CERT_END_DATE=$(sudo openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
      CERT_END_EPOCH=$(sudo date -d "$CERT_END_DATE" +%s 2>/dev/null || sudo date -j -f "%b %d %T %Y %Z" "$CERT_END_DATE" +%s 2>/dev/null)
      NOW_EPOCH=$(date +%s)
      CERT_DAYS_REMAINING=$(( ($CERT_END_EPOCH - $NOW_EPOCH) / 86400 ))
      echo "Certificate for ${PROJECT_DOMAIN} expires in $CERT_DAYS_REMAINING days"
    fi
  else
    # Fallback to certbot but with more portable grep
    CERT_DAYS_REMAINING=$(sudo certbot certificates -d "${PROJECT_DOMAIN}" 2>/dev/null | grep 'VALID:' | grep -o '[0-9]* day' | grep -o '[0-9]*' | head -1 || echo "0")
  fi
fi

if [ "$CERT_EXISTS" = false ] || [ "$CERT_DAYS_REMAINING" -lt "30" ]; then
  echo "Setting up or renewing SSL certificate..."
  
  # Backup Nginx configs before making changes
  sudo mkdir -p /etc/nginx/sites-available/backup-before-ssl
  sudo cp "/etc/nginx/sites-available/${PROJECT_NAME}" "/etc/nginx/sites-available/backup-before-ssl/${PROJECT_NAME}.$(date +%s)" 2>/dev/null || true
  
  # More robust error handling for SSL setup
  if ! sudo certbot --nginx -d "${PROJECT_DOMAIN}" --non-interactive --agree-tos \
       --email $SSL_EMAIL \
       --keep-until-expiring --redirect; then
    echo "ERROR: SSL certificate setup failed"
    
    # Try to restore from backup if needed
    if [ -f "/etc/nginx/sites-available/backup-before-ssl/${PROJECT_NAME}.$(date +%s)" ]; then
      echo "Restoring Nginx config from backup..."
      sudo cp "/etc/nginx/sites-available/backup-before-ssl/${PROJECT_NAME}.$(date +%s)" "/etc/nginx/sites-available/${PROJECT_NAME}"
      sudo nginx -t && sudo systemctl reload nginx
    fi
    
    # Continue but record the issue - SSL will be retried on next deployment
    echo "Continuing deployment without valid SSL. Please check the certbot logs and fix DNS settings if needed."
  else
    echo "SSL certificate successfully installed/renewed"
  fi
else
  echo "SSL certificate is valid and not near expiration ($CERT_DAYS_REMAINING days remaining)"
fi

echo "Deployment completed successfully!"

# Add trap for unexpected failures with specific signal handling
trap 'handle_error "unexpected" "Script terminated unexpectedly"' ERR
trap 'handle_error "interrupted" "Script interrupted by user or system"' INT TERM
