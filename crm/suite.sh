#!/bin/bash

# Developed by Loren Heyns (with Claude) and Lokesh Reddy, extending Linux 10-min install by Chris.

# Parse command line arguments
VERSION="8.9.0"  # New version
INSTANCE_FOLDER="account"  # Default subfolder

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --subfolder)
            INSTANCE_FOLDER="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--version VERSION] [--subfolder INSTANCE_FOLDER]"
            echo "  --version    SuiteCRM version (new version: 8.9.0)"
            echo "  --subfolder  Installation subfolder (default: account)"
            echo "Example: $0 --version 8.8.0 --subfolder account"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Convert version to zip file format (replace dots with dashes)
ZIP_VERSION=$(echo "$VERSION" | sed 's/\./-/g')
ZIP_FILENAME="suitecrm-${ZIP_VERSION}.zip"

echo "🚀 SuiteCRM Installation Script"
#echo "📦 Version: $VERSION"
#echo "📁 Subfolder: $INSTANCE_FOLDER"
echo "📎 ZIP file: $ZIP_FILENAME"
echo ""

# Detect platform
platform="$(uname)"
case "$platform" in
  Darwin*)
    echo "Platform detected: macOS"
    os="macos"
    ;;
  Linux*)
    echo "Platform detected: Linux"
    os="linux"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    echo "Platform detected: Windows (Git Bash or Cygwin)"
    os="windows"
    ;;
  *)
    echo "Unsupported platform: $platform"
    exit 1
    ;;
esac

# Check if running as root and warn user
if [[ "$EUID" -eq 0 ]]; then
    echo "❌ ERROR: This script should NOT be run as root (sudo)!"
    echo ""
    echo "Running as root causes:"
    echo "  - Permission issues with Homebrew"
    echo "  - Locked directories that regular users can't access"
    echo "  - Security risks"
    echo ""
    echo "Please run this script as your regular user (without sudo):"
    echo "  ./$(basename "$0") --version $VERSION --subfolder $INSTANCE_FOLDER"
    echo ""
    exit 1
fi

# Function to backup configuration files
backup_config_files() {
    local httpd_conf="$1"
    local httpd_vhosts="$2"
    local os_type="$3"
    
    echo "🔧 Creating backups of Apache configuration files for $os_type..."
    
    # Backup httpd.conf if it exists and backup doesn't already exist
    if [ -f "$httpd_conf" ]; then
        if [ ! -f "${httpd_conf%.conf}.bkup" ]; then
            cp "$httpd_conf" "${httpd_conf%.conf}.bkup" || {
                echo "⚠️ Failed to create backup of httpd.conf"
                return 1
            }
            echo "✅ Created backup: ${httpd_conf%.conf}.bkup"
        else
            echo "✅ Backup already exists: ${httpd_conf%.conf}.bkup"
        fi
    else
        echo "⚠️ httpd.conf not found at: $httpd_conf"
    fi
    
    # Backup httpd-vhosts.conf if it exists and backup doesn't already exist
    if [ -f "$httpd_vhosts" ]; then
        if [ ! -f "${httpd_vhosts%.conf}.bkup" ]; then
            cp "$httpd_vhosts" "${httpd_vhosts%.conf}.bkup" || {
                echo "⚠️ Failed to create backup of httpd-vhosts.conf"
                return 1
            }
            echo "✅ Created backup: ${httpd_vhosts%.conf}.bkup"
        else
            echo "✅ Backup already exists: ${httpd_vhosts%.conf}.bkup"
        fi
    else
        echo "⚠️ httpd-vhosts.conf not found at: $httpd_vhosts"
    fi
    
    return 0
}

# Function to update paths in httpd-vhosts.conf to use same variables as httpd.conf
update_vhosts_paths() {
    local httpd_vhosts="$1"
    local document_root="$2"
    local instance_folder="$3"
    local os_type="$4"
    
    echo "🔧 Updating paths in httpd-vhosts.conf for $os_type..."
    
    if [ ! -f "$httpd_vhosts" ]; then
        echo "⚠️ httpd-vhosts.conf not found at: $httpd_vhosts"
        return 1
    fi
    
    # Define the CRM public directory path
    local crm_public_dir="$document_root/$instance_folder/public"
    
    # Update DocumentRoot paths in vhosts file
    sed -i.tmp "s|DocumentRoot \".*\"|DocumentRoot \"$crm_public_dir\"|g" "$httpd_vhosts" && rm -f "${httpd_vhosts}.tmp" || {
        echo "⚠️ Failed to update DocumentRoot in httpd-vhosts.conf"
        return 1
    }
    
    # Update Directory paths in vhosts file
    sed -i.tmp "s|<Directory \".*\">|<Directory \"$crm_public_dir\">|g" "$httpd_vhosts" && rm -f "${httpd_vhosts}.tmp" || {
        echo "⚠️ Failed to update Directory paths in httpd-vhosts.conf"
        return 1
    }
    
    echo "✅ Updated paths in httpd-vhosts.conf to use consistent path variables"
    return 0
}

# Function to request user input
get_input() {
    read -p "$1: " value
    echo $value
}

# Function to automatically get the internal IP
get_internal_ip() {
  if command -v ip > /dev/null; then
    # Linux (ip command available)
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127' | head -n1
  elif command -v ifconfig > /dev/null; then
    # macOS or older Linux
    ifconfig | grep -E 'inet (addr:)?' | grep -v '127.0.0.1' | \
      awk '{ print $2 }' | sed 's/addr://' | head -n1
  elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    # Windows Git Bash or Cygwin
    ipconfig | grep -E "IPv4.*: " | grep -v '127.0.0.1' | \
      sed -E 's/.*:\s*([0-9\.]+)/\1/' | head -n1
  else
    echo "Unsupported OS" >&2
    return 1
  fi
}

# Function to restart services properly based on user privileges
restart_services() {
    echo "🔄 Restarting services..."
    brew services restart httpd || echo "⚠️ Failed to restart Apache"
    brew services restart mariadb || echo "⚠️ Failed to restart MariaDB"
    echo "✅ Services restarted successfully."
}

# Function to check MariaDB root password status
check_mysql_root_status() {
    echo "🔍 Checking MariaDB root access..."
    local retries=5
    local attempt=1
    local reset_attempted=false

    while [[ $attempt -le $retries ]]; do
        read -sp "Enter MariaDB root password (leave empty if none) [attempt $attempt/$retries]: " MYSQL_ROOT_PASS
        echo ""

        if mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" &>/dev/null; then
            if [[ -z "$MYSQL_ROOT_PASS" ]]; then
                echo "✅ MariaDB root access confirmed (empty password)."
                ROOT_PASS_SET=false
                MYSQL_SECURE_NEEDED=true
            else
                echo "✅ MariaDB root password verified."
                ROOT_PASS_SET=true
                MYSQL_SECURE_NEEDED=false
            fi
            return 0
        else
            echo "❌ Invalid root password (attempt $attempt/$retries)."
            ((attempt++))
            if [[ $attempt -le $retries ]]; then
                echo "Please try again."
            fi
        fi
    done

    # Offer password reset after max retries
    echo "❌ Max retries reached."
    read -p "Would you like to reset the MariaDB root password? [y/N]: " reset_choice
    if [[ "$reset_choice" =~ ^[Yy]$ ]]; then
        echo "🔧 Attempting to reset MariaDB root password..."
        read -sp "Enter new MariaDB root password: " NEW_ROOT_PASS
        echo ""
        if mysqladmin -u root -p"$MYSQL_ROOT_PASS" password "$NEW_ROOT_PASS" &>/dev/null; then
            echo "✅ Root password reset successfully."
            MYSQL_ROOT_PASS="$NEW_ROOT_PASS"
            ROOT_PASS_SET=true
            MYSQL_SECURE_NEEDED=false
            # Re-check access with new password
            if mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" &>/dev/null; then
                echo "✅ MariaDB root access confirmed with new password."
                return 0
            else
                echo "❌ Failed to verify new root password."
            fi
        else
            echo "❌ Failed to reset root password. Please reset manually using:"
            echo "   mysqladmin -u root password"
            echo "   Then re-run the script or try again below."
        fi
        reset_attempted=true
    fi
}

# Enhanced database configuration with proper permissions
configure_database_enhanced() {
    echo "🔧 Configuring database with enhanced permissions..."
    
    # First, check if MariaDB is running
    if ! pgrep -f "mysql" > /dev/null; then
        echo "❌ MariaDB is not running. Cannot continue with database setup."
        echo "Attempting to start MariaDB..."
        brew services start mariadb || {
            echo "❌ Failed to start MariaDB."
            exit 1
        }
        # Wait a moment for MariaDB to start
        sleep 3
    fi

    # Check MariaDB root status
    check_mysql_root_status

    # Configure database with proper error handling
    echo "🔧 Creating database and user..."
    
    if [[ "$ROOT_PASS_SET" == false ]]; then
        MYSQL_CMD="mysql -u root"
    else
        MYSQL_CMD="mysql -u root -p$MYSQL_ROOT_PASS"
    fi
    # Tried both $db_pass and $MYSQL_ROOT_PASS with "admin" (Failed to configure database.))
    # "admin" is prbobably correct for root password. Because hitting Enter returned "Invalid root password. Database configuration failed."
    # Could Failed message be because database already exists?
    


    # Create database and user with comprehensive permissions
    if ! $MYSQL_CMD <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '$db_user'@'localhost';
CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        echo "❌ Failed to configure database. Check MariaDB status and permissions."
        exit 1
    fi

    # Verify database creation
    if ! $MYSQL_CMD -e "USE CRM" &>/dev/null; then
        echo "❌ Failed to access database CRM."
        exit 1
    else
        echo "✅ Database CRM created and accessible."
    fi

    # Comprehensive user verification
    if ! $MYSQL_CMD -e "SELECT User FROM mysql.user WHERE User='$db_user';" | grep -q "$db_user"; then
        echo "❌ Failed to create user $db_user."
        exit 1
    else
        echo "✅ User $db_user created successfully."
        
        # Verify comprehensive permissions with better error handling
        echo "🔍 Verifying user permissions..."
        GRANTS=$($MYSQL_CMD -e "SHOW GRANTS FOR '$db_user'@'localhost';" 2>/dev/null || echo "")
        
        if [[ -z "$GRANTS" ]]; then
            echo "⚠️ Warning: Could not retrieve user permissions."
            echo "📋 Manual verification steps:"
            echo "   1. Connect to MariaDB: mysql -u root -p"
            echo "   2. Run: SHOW GRANTS FOR '$db_user'@'localhost';"
            echo "   3. Verify the user has ALL PRIVILEGES on CRM database"
            echo "   4. If permissions are missing, run:"
            echo "      GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';"
            echo "      FLUSH PRIVILEGES;"
        elif echo "$GRANTS" | grep -q "GRANT ALL PRIVILEGES ON \`CRM\`"; then
            echo "✅ User $db_user has full privileges on CRM database."
        elif echo "$GRANTS" | grep -q "ON \`CRM\`"; then
            echo "✅ User $db_user has permissions on CRM database."
            echo "📋 Granted permissions:"
            echo "$GRANTS" | grep "CRM"
        else
            echo "⚠️ Warning: Could not verify user permissions."
            echo "📋 Manual verification steps:"
            echo "   1. Connect to MariaDB: mysql -u root -p"
            echo "   2. Run: SHOW GRANTS FOR '$db_user'@'localhost';"
            echo "   3. Verify the user has ALL PRIVILEGES on CRM database"
            echo "   4. Current grants output:"
            echo "$GRANTS"
        fi
    fi

    # Test user connection
    echo "🔍 Testing user database connection..."
    if mysql -u "$db_user" -p"$db_pass" -e "USE CRM; SELECT 'Connection successful' as Status;" &>/dev/null; then
        echo "✅ User database connection test successful."
    else
        echo "❌ User cannot connect to database. Please check credentials and permissions."
        echo "📋 Troubleshooting steps:"
        echo "   1. Verify MariaDB is running: brew services list | grep mariadb"
        echo "   2. Test root connection: mysql -u root -p"
        echo "   3. Check user exists: SELECT User FROM mysql.user WHERE User='$db_user';"
        echo "   4. Reset user password: ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
        exit 1
    fi
}

# Enhanced MySQL security setup
setup_mysql_security() {
    echo "🔒 Setting up MySQL security..."
    
    # Re-check root password status after potential mysql_secure_installation
    if [[ -z "$MYSQL_ROOT_PASS" ]]; then
        check_mysql_root_status
    else
        echo "🔁 Reusing previously verified MariaDB root password."
    fi
    
    if [[ "$MYSQL_SECURE_NEEDED" == true ]]; then
        echo "⚠️ MariaDB root password is not set. Setting it automatically..."
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DEFAULT_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF
MYSQL_SECURE_NEEDED=false
        
        if [[ ! "$run_secure" =~ ^[Nn]$ ]]; then
            echo "🔒 Running mysql_secure_installation..."
            echo "Please follow the prompts to secure your MariaDB installation."
            echo "Recommended answers: Y, Y, Y, Y, Y"
            echo ""
            
            # Was mysql_secure_installation
            if command -v mariadb-secure-installation &>/dev/null; then
                mysql_secure_installation || {
                    echo "⚠️ mysql_secure_installation encountered issues. Please run it manually later."
                }
                
                # After running mysql_secure_installation, update the root password status
                echo "🔍 Re-checking MariaDB root status after security setup..."
                check_mysql_root_status
                
            else
                echo "❌ mysql_secure_installation not found. Please run it manually:"
                echo "sudo $(brew --prefix)/bin/mysql_secure_installation"
            fi
        else
            echo "⚠️ Skipping MySQL security setup. Remember to run 'mysql_secure_installation' later."
            MYSQL_SECURE_NEEDED=true
        fi
    else
        echo "✅ MariaDB root password is already set - security setup complete."
        MYSQL_SECURE_NEEDED=false
    fi
}

# Function to check and fix Apache configuration
check_apache_config() {
    echo "🔍 Checking Apache configuration..."
    
    # Test Apache configuration
    if ! httpd -t &>/dev/null; then
        echo "❌ Apache configuration has errors. Checking common issues..."
        
        # Check if the configuration file exists
        if [ ! -f "$HTTPD_CONF" ]; then
            echo "❌ Apache configuration file not found at $HTTPD_CONF"
            return 1
        fi
        
        # Check for common issues and fix them
        echo "🔧 Attempting to fix common Apache configuration issues..."
        
        # Fix ServerRoot if needed
        if ! grep -q "^ServerRoot" "$HTTPD_CONF"; then
            echo "ServerRoot /opt/homebrew/var" >> "$HTTPD_CONF"
        fi
        
        # Ensure PidFile directory exists
        PIDFILE_DIR=$(grep "^PidFile" "$HTTPD_CONF" | cut -d' ' -f2 | xargs dirname 2>/dev/null || echo "/opt/homebrew/var/run")
        if [ ! -d "$PIDFILE_DIR" ]; then
            mkdir -p "$PIDFILE_DIR"
        fi
        
        # Test again
        if ! httpd -t &>/dev/null; then
            echo "❌ Apache configuration still has errors. Please check manually:"
            echo "   Run: httpd -t"
            echo "   Check error logs: tail -f /opt/homebrew/var/log/httpd/error_log"
            return 1
        fi
    fi
    
    echo "✅ Apache configuration is valid."
    return 0
}

# Function to check if Apache is actually running and accessible
check_apache_status() {
    echo "🔍 Checking Apache status..."
    
    # Check if Apache process is running
    if ! pgrep -f "httpd" > /dev/null; then
        echo "❌ Apache is not running."
        return 1
    fi
    
    # Check if Apache is listening on port 8080
    if ! netstat -an | grep -q ":8080.*LISTEN"; then
        echo "❌ Apache is not listening on port 8080."
        echo "📋 Troubleshooting steps:"
        echo "   1. Check Apache configuration: httpd -t"
        echo "   2. Check Apache error log: tail -f /opt/homebrew/var/log/httpd/error_log"
        echo "   3. Try restarting Apache: brew services restart httpd"
        return 1
    fi
    
    echo "✅ Apache is running and listening on port 8080."
    return 0
}

# Function to set proper permissions without locking
set_proper_permissions() {
    local target_dir="$1"
    local current_user="$2"
    local group="$3"
    
    echo "🔧 Setting proper permissions for $target_dir..."
    
    # Ensure the current user owns the directory
    chown -R "$current_user:$group" "$target_dir" || {
        echo "⚠️ Failed to set ownership. Trying with sudo..."
        sudo chown -R "$current_user:$group" "$target_dir" || {
            echo "❌ Failed to set ownership even with sudo."
            return 1
        }
    }
    
    # Set permissions: owner can read/write/execute, group can read/execute, others can read/execute
    find "$target_dir" -type d -exec chmod 755 {} \; || {
        echo "⚠️ Failed to set directory permissions."
        return 1
    }
    find "$target_dir" -type f -exec chmod 644 {} \; || {
        echo "⚠️ Failed to set file permissions."
        return 1
    }
    
    # Make sure executable files stay executable
    if [ -f "$target_dir/bin/console" ]; then
        chmod +x "$target_dir/bin/console" || {
            echo "⚠️ Failed to make console script executable."
        }
    fi
    
    # Make storage directories writable for the web server
    for dir in "storage" "cache" "public/legacy/cache" "public/legacy/upload"; do
        if [ -d "$target_dir/$dir" ]; then
            chmod -R 775 "$target_dir/$dir" || {
                echo "⚠️ Failed to set permissions for $dir directory."
            }
        fi
    done
    
    echo "✅ Permissions set successfully."
    return 0
}

# Function to download and extract SuiteCRM
download_and_extract_suitecrm() {
    local download_url="$1"
    local target_dir="$2"
    
    echo "📦 Downloading SuiteCRM version $VERSION..."
    
    # Create subfolder if it doesn't exist
    mkdir -p "$target_dir" || {
        echo "❌ Failed to create target directory: $target_dir"
        exit 1
    }
    
    cd "$target_dir" || {
        echo "❌ Failed to change to target directory: $target_dir"
        exit 1
    }
    
    # Download SuiteCRM if not already present
    if [ ! -f "$ZIP_FILENAME" ]; then
        echo "📦 Downloading $ZIP_FILENAME..."
        wget -O "$ZIP_FILENAME" "$download_url" || {
            echo "❌ Failed to download SuiteCRM from $download_url"
            echo "Please check your internet connection and the download URL."
            exit 1
        }
        echo "✅ Downloaded $ZIP_FILENAME successfully."
    else
        echo "✅ $ZIP_FILENAME already exists, using cached version."
    fi
    
    # Extract SuiteCRM in the same directory
    echo "📦 Extracting $ZIP_FILENAME..."
    unzip -o "$ZIP_FILENAME" || {
        echo "❌ Failed to extract $ZIP_FILENAME"
        echo "The ZIP file may be corrupted. Try deleting it and running the script again."
        exit 1
    }
    echo "✅ SuiteCRM extracted successfully to $target_dir"
    
    return 0
}

# Request user information
echo ""
echo "Choose where to set up your SuiteCRM database:"
echo "1 - Azure (remotely)"
echo "2 - MariaDB (locally)"
read -p "Enter your choice [1/2]: " db_choice

if [[ "$db_choice" == "1" ]]; then
    echo "🧭 Azure setup selected."
    read -p "Enter Azure MySQL host (e.g., your-db.mysql.database.azure.com): " azure_host
    read -p "Enter Azure DB name: " azure_db
    read -p "Enter Azure DB username (e.g., suitecrm_user@your-db): " azure_user
    read -sp "Enter Azure DB password: " azure_pass
    echo ""
    echo "🔧 Azure setup is currently under development."
    echo "➡️ Please manually run the Azure SQL script or configure DB access in SuiteCRM installer."
    exit 0
fi

# If not Azure, proceed with local MariaDB as usual
read -p "Enter your MariaDB username: " db_user
read -sp "Enter your MariaDB password: " db_pass
echo ""

# Automatically get the internal IP
server_ip=$(get_internal_ip)
echo "IP retrieved: $server_ip"

# Function to install a package if not already installed
install_if_missing() {
  if ! brew list "$1" &>/dev/null; then
    echo "📦 Installing $1..."
    brew install "$1"
  else
    echo "✅ $1 is already installed."
  fi
}

install_php_macos() {
    # Install PHP 8.2 and common extensions
    echo "📦 Installing PHP 8.2 and extensions..."
    brew install php@8.2

    # Add PHP 8.2 to PATH if not already in it
    PHP82_PATH="/opt/homebrew/opt/php@8.2/bin"
    if ! echo "$PATH" | grep -q "$PHP82_PATH"; then
      echo "🔧 Updating PATH to use PHP 8.2..."
      echo 'export PATH="/opt/homebrew/opt/php@8.2/bin:$PATH"' >> ~/.zprofile
      echo 'export PATH="/opt/homebrew/opt/php@8.2/sbin:$PATH"' >> ~/.zprofile
      export PATH="/opt/homebrew/opt/php@8.2/bin:$PATH"
      export PATH="/opt/homebrew/opt/php@8.2/sbin:$PATH"
    fi

    # Link PHP 8.2 as the default
    brew link --overwrite --force php@8.2

    # Common PHP extensions (included or installable via PECL)
    echo "📦 Installing PECL and common PHP extensions..."
    brew install autoconf pkg-config
    pecl install imagick || true
    pecl install ldap || true
    pecl install imap || true
    pecl install soap || true
    pecl install bcmath || true

    echo "✅ PHP 8.2 and common extensions are installed."
    # Show installed PHP version
    if ! command -v php > /dev/null; then
        echo "❌ PHP is still not installed. Aborting."
        echo "➡️ Please check your Homebrew installation and try again."
        exit 1
    else
        php -v
    fi
}

install_php_PC() {
    echo "📦 Installing PHP 8.2 for Windows (Git Bash or Cygwin)..."

    # Assuming Chocolatey is installed — check if not, guide user
    if ! command -v choco &> /dev/null; then
        echo "⚠️ Chocolatey not found. Please install Chocolatey first: https://chocolatey.org/install"
        return 1
    fi

    # Install PHP via Chocolatey
    choco install php --version=8.2 -y

    # Optional: Add PHP to PATH
    PHP_PATH="/c/tools/php82"
    if ! echo "$PATH" | grep -q "$PHP_PATH"; then
        echo "🔧 Please manually add PHP 8.2 to your Windows PATH or restart Git Bash after installation."
    fi

    # Show PHP version
    php -v
}

# Configuration for MacOS, Linux and Windows
if [[ "$os" == "macos" ]]; then
    
    echo "Platform detected: macOS - Beginning setup process..."
    # Track installation status
    HOMEBREW_INSTALLED=false
    HOMEBREW_FAILED=false

    # Check for Homebrew installation
    echo "🔍 Checking for Homebrew..."
    if ! command -v brew &> /dev/null; then
      echo "🍺 Homebrew not found. Installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        echo "❌ Failed to install Homebrew. Please install it manually: https://brew.sh"
        echo "⚠️ Without Homebrew, the following components might NOT be installed:"
        echo "   - Apache (httpd)"
        echo "   - PHP 8.2"
        echo "   - MariaDB"
        echo "   - wget, unzip utilities"
        echo ""
        HOMEBREW_FAILED=true
        exit 1
      }
      
      # Add Homebrew to PATH if not already there
      if [[ "$(uname -m)" == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
      else
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/usr/local/bin/brew shellenv)"
      fi
      HOMEBREW_INSTALLED=true
    else
      echo "✅ Homebrew is already installed."
      HOMEBREW_INSTALLED=true
    fi

    # Function for installing packages
    install_package() {
      local package=$1
      echo "📦 Installing $package..."
      if ! brew list "$package" &>/dev/null; then
        brew install "$package" || {
          echo "❌ Failed to install $package."
          return 1
        }
        echo "✅ $package installed successfully."
      else
        echo "✅ $package is already installed."
      fi
      return 0
    }

    # Update and upgrade Homebrew
    echo "🔄 Updating Homebrew and packages..."
    brew update && brew upgrade || {
      echo "⚠️ Warning: Failed to update Homebrew. Continuing anyway..."
    }

    # Install essential packages
    install_package wget || exit 1
    install_package unzip || exit 1

    # Install PHP 8.2 if not already installed or update if needed
    CURRENT_PHP=""
    if command -v php >/dev/null 2>&1; then
      CURRENT_PHP="$(php -v | head -n 1 | awk '{print $2}')"
    fi
    
    if [ -n "$CURRENT_PHP" ]; then
        if [[ "$CURRENT_PHP" != 8.2* ]]; then
          echo "⚠️ Detected PHP version: $CURRENT_PHP"
          echo "Switching to PHP 8.2 may affect your local development environment."
          read -p "Do you want to continue and install/switch to PHP 8.2? [y/N]: " confirm
          if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Not updating PHP"
          else
            echo "Starting PHP update process"
            install_php_macos || {
              echo "❌ Failed to install PHP 8.2"
              exit 1
            }
          fi
        else
          echo "✅ PHP 8.2 is already installed."
        fi
    else
        install_php_macos || {
          echo "❌ Failed to install PHP 8.2"
          exit 1
        }
    fi

    # Install and configure Apache
    echo "🔧 Installing and configuring Apache Server..."
    install_package httpd || exit 1

    # Define Apache and PHP paths
    HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
    HTTPD_VHOSTS="/opt/homebrew/etc/httpd/extra/httpd-vhosts.conf"
    PHP_CONF="/opt/homebrew/etc/httpd/extra/httpd-php.conf"
    PHP_INI="/opt/homebrew/etc/php/8.2/php.ini"
    
    # Check if paths exist, adjust for Intel Macs if needed
    if [ ! -f "$HTTPD_CONF" ]; then
      HTTPD_CONF="/usr/local/etc/httpd/httpd.conf"
      HTTPD_VHOSTS="/usr/local/etc/httpd/extra/httpd-vhosts.conf"
      PHP_CONF="/usr/local/etc/httpd/extra/httpd-php.conf"
      PHP_INI="/usr/local/etc/php/8.2/php.ini"
    fi

    # Create backups of configuration files
    backup_config_files "$HTTPD_CONF" "$HTTPD_VHOSTS" "macOS"

    # Configure Apache modules and PHP integration
    echo "🔧 Configuring Apache modules..."
    if [ -f "$HTTPD_CONF" ]; then
        # Enable mod_rewrite
        sed -i '' 's/#LoadModule rewrite_module/LoadModule rewrite_module/g' "$HTTPD_CONF"
        
        # Enable PHP module
        if ! grep -q "LoadModule php_module" "$HTTPD_CONF"; then
            PHP_MODULE=$(find /opt/homebrew/opt/php@8.2 -name "libphp.so" 2>/dev/null || find /usr/local/opt/php@8.2 -name "libphp.so" 2>/dev/null)
            if [ -n "$PHP_MODULE" ]; then
                echo "LoadModule php_module $PHP_MODULE" >> "$HTTPD_CONF"
                echo "✅ PHP module enabled in Apache configuration."
            else
                echo "⚠️ PHP module not found. PHP may not work correctly with Apache."
            fi
        fi
        
        # Add PHP handling if not already configured
        if ! grep -q "SetHandler application/x-httpd-php" "$HTTPD_CONF"; then
    cat << EOF >> "$HTTPD_CONF"
<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
DirectoryIndex index.php index.html
EOF
    echo "✅ PHP handler configuration added."
else
    echo "✅ PHP handler already exists — skipping addition."
fi

    PHP_MODULE_LINE="LoadModule php_module /opt/homebrew/opt/php@8.2/lib/httpd/modules/libphp.so"

# Add PHP module line if not present
if ! grep -q "^LoadModule php_module" "$HTTPD_CONF"; then
    echo "🔧 Adding PHP module to httpd.conf..."
    # Add after the last LoadModule line
    awk -v newline="$PHP_MODULE_LINE" '
        /^LoadModule/ { last=NR }
        { lines[NR]=$0 }
        END {
            for (i=1; i<=last; i++) print lines[i]
            print newline
            for (i=last+1; i<=NR; i++) print lines[i]
        }
    ' "$HTTPD_CONF" > "${HTTPD_CONF}.tmp" && mv "${HTTPD_CONF}.tmp" "$HTTPD_CONF"
    echo "✅ PHP module line added."
else
    echo "✅ PHP module already present — skipping."
fi

        
        # Disable directory listing globally
        sed -i '' 's/Options Indexes FollowSymLinks/Options -Indexes +FollowSymLinks/g' "$HTTPD_CONF"
        echo "✅ Directory listing disabled."

        # Ensure Apache listens on port 8080
        if ! grep -q "Listen 8080" "$HTTPD_CONF"; then
            sed -i '' 's/Listen 80$/Listen 8080/' "$HTTPD_CONF"
            echo "✅ Apache configured to listen on port 8080."
        else
            echo "⚠️ Apache is NOT yet configured to listen on port 8080. Run: brew services start httpd"

            # Add Listen 8080 directive - NO EFFECT
            #echo "Listen 8080" >> "$HTTPD_CONF"
            #echo "✅ Apache configured to listen on port 8080."
        fi
    fi

    DOCUMENT_ROOT="$(pwd)"
    echo "Current working directory: $DOCUMENT_ROOT"
    INSTANCE_FOLDER="$INSTANCE_FOLDER" # account folder

    # Get current user and group
    CURRENT_USER=$(whoami)
    GROUP=$(id -gn)

    # Construct full path to the SuiteCRM public directory
    CRM_PUBLIC_DIR="$DOCUMENT_ROOT/$INSTANCE_FOLDER/public"
    echo "📁 SuiteCRM public path: $CRM_PUBLIC_DIR"
    
    # Create directories if they don't exist with proper ownership
    echo "🔧 Creating CRM directories..."
    mkdir -p "$INSTANCE_FOLDER" || {
        echo "❌ Failed to create CRM directory."
        exit 1
    }
    
    # Download and install SuiteCRM
    echo "🔧 Installing and configuring SuiteCRM..."
    
    # Construct download URL - you may need to adjust this based on SuiteCRM's actual download URLs
    DOWNLOAD_URL="https://suitecrm.com/download/148/suite87/564667/$ZIP_FILENAME"
    
    # Download and extract to the subfolder
    download_and_extract_suitecrm "$DOWNLOAD_URL" "$DOCUMENT_ROOT/$INSTANCE_FOLDER"
    
    # Set proper permissions without locking
    set_proper_permissions "$DOCUMENT_ROOT/$INSTANCE_FOLDER" "$CURRENT_USER" "$GROUP" || {
        echo "❌ Failed to set proper permissions."
        exit 1
    }

    # Configure Virtual Host
    echo "🔧 Configuring VirtualHost..."
    
    # Make sure vhosts directory exists
    VHOSTS_DIR=$(dirname "$HTTPD_VHOSTS")
    if [ ! -d "$VHOSTS_DIR" ]; then
        mkdir -p "$VHOSTS_DIR" || {
            echo "❌ Failed to create vhosts directory."
            exit 1
        }
    fi
    
    # Enable vhosts module in main config
    sed -i '' 's/#Include.*httpd-vhosts.conf/Include \/opt\/homebrew\/etc\/httpd\/extra\/httpd-vhosts.conf/g' "$HTTPD_CONF" || {
        # Try Intel Mac path
        sed -i '' 's/#Include.*httpd-vhosts.conf/Include \/usr\/local\/etc\/httpd\/extra\/httpd-vhosts.conf/g' "$HTTPD_CONF" || {
            echo "⚠️ Failed to enable vhosts in Apache config. Manual configuration may be required."
        }
    }

    # ----------- PATCH httpd.conf (Global Apache Config) ------------
    if [ -f "$HTTPD_CONF" ]; then
        echo "🛠️ Updating httpd.conf..."
        # Set DocumentRoot
        sed -i '' "s|^DocumentRoot \".*\"|DocumentRoot \"$CRM_PUBLIC_DIR\"|" "$HTTPD_CONF"
        # Update the Directory block following DocumentRoot
        sed -i '' "/<Directory \".*www\"/,/<\/Directory>/c\\
    <Directory \"$CRM_PUBLIC_DIR\">\\
        Options -Indexes +FollowSymLinks\\
        AllowOverride All\\
        Require all granted\\
    </Directory>" "$HTTPD_CONF"
    fi
    
    # Create VirtualHost configuration with security headers
    echo "🛠️ Writing new httpd-vhosts.conf..."
    cat << EOF > "$HTTPD_VHOSTS"
    <VirtualHost *:8080>
        ServerAdmin admin@example.com
        DocumentRoot "$CRM_PUBLIC_DIR"
        ServerName localhost
        <Directory "$CRM_PUBLIC_DIR">
            Options -Indexes +FollowSymLinks +MultiViews
            AllowOverride All
            Require all granted
        </Directory>
        ErrorLog /opt/homebrew/var/log/httpd/crm-error_log
        CustomLog /opt/homebrew/var/log/httpd/crm-access_log combined
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-XSS-Protection "1; mode=block"
        Header always set X-Frame-Options "SAMEORIGIN"
    </VirtualHost>
EOF

    # Update paths in httpd-vhosts.conf to use consistent variables
    update_vhosts_paths "$HTTPD_VHOSTS" "$DOCUMENT_ROOT" "$INSTANCE_FOLDER" "macOS"

    echo "🔐 Fixing folder permissions for Apache..."
    PARENT="$CRM_PUBLIC_DIR"
    while [[ "$PARENT" != "/" ]]; do
        chmod +x "$PARENT" 2>/dev/null || true
        PARENT=$(dirname "$PARENT")
    done
    chmod -R 755 "$CRM_PUBLIC_DIR"
    chown -R "$CURRENT_USER:$GROUP" "$CRM_PUBLIC_DIR"
    
    # Enable headers module for security headers
    sed -i '' 's/#LoadModule headers_module/LoadModule headers_module/g' "$HTTPD_CONF" || {
        echo "⚠️ Failed to enable headers module in Apache config."
    }

    # Configure php.ini
    echo "🔧 Setting php.ini..."
    if [ -f "$PHP_INI" ]; then
        # Make backup of original php.ini
        cp "$PHP_INI" "${PHP_INI}.bak" || {
            echo "⚠️ Failed to create backup of php.ini"
        }
        
        # Update PHP settings
        sed -i '' 's/memory_limit = .*/memory_limit = 512M/' "$PHP_INI" || echo "⚠️ Failed to set memory_limit"
        sed -i '' 's/upload_max_filesize = .*/upload_max_filesize = 50M/' "$PHP_INI" || echo "⚠️ Failed to set upload_max_filesize"
        sed -i '' 's/post_max_size = .*/post_max_size = 50M/' "$PHP_INI" || echo "⚠️ Failed to set post_max_size"
        sed -i '' 's/max_execution_time = .*/max_execution_time = 300/' "$PHP_INI" || echo "⚠️ Failed to set max_execution_time"
        
        # Add security settings
        sed -i '' 's/display_errors = .*/display_errors = Off/' "$PHP_INI" || echo "⚠️ Failed to set display_errors"
        sed -i '' 's/expose_php = .*/expose_php = Off/' "$PHP_INI" || echo "⚠️ Failed to set expose_php"
        
        echo "✅ PHP configuration updated."
    else
        echo "⚠️ PHP config file not found at $PHP_INI"
    fi
    
    # Install and configure MariaDB
    echo "🔧 Installing MariaDB..."
    install_package mariadb || exit 1

    # Start MariaDB service with error handling
    if ! pgrep -f "mysql" > /dev/null; then
        echo "🔧 Starting MariaDB service..."
        if [[ "$IS_ROOT" == false ]]; then
            brew services start mariadb || {
              echo "⚠️ Failed to start MariaDB service. Attempting to restart..."
              brew services restart mariadb || {
                echo "❌ Failed to start MariaDB. Please check for errors."
                exit 1
              }
            }
        else
            echo "⚠️ Cannot start MariaDB service as root. Manual start required."
        fi
    fi
    
    # Check if MariaDB is running
    if ! pgrep -f "mysql" > /dev/null; then
        echo "❌ MariaDB is not running. Cannot continue with database setup."
        echo "Please start MariaDB manually and re-run this script."
        exit 1
    else
        echo "✅ MariaDB is running."
    fi

    # Enhanced database configuration
    configure_database_enhanced

    # Setup MySQL security
    setup_mysql_security
    
    # Restart services with proper handling
    restart_services
    
    # Create a simple health check
    echo "<?php echo 'CRM Health Check: ' . date('Y-m-d H:i:s'); ?>" > "$DOCUMENT_ROOT/$INSTANCE_FOLDER/public/health.php"
    chmod 644 "$DOCUMENT_ROOT/$INSTANCE_FOLDER/public/health.php" || {
        echo "⚠️ Failed to create health check file."
    }
    
    echo ""
    echo "🎉 macOS setup completed successfully!"
    echo "📝 You can now complete the installation of your CRM at: http://$server_ip:8080"
    echo "👉 Health check URL: http://$server_ip:8080/health.php"
    echo ""
    echo "📋 Configuration summary:"
    echo "  - Database: CRM"
    echo "  - Database User: $db_user (with full privileges)"
    echo "  - Server IP: $server_ip"
    echo "  - Document Root: $DOCUMENT_ROOT/$INSTANCE_FOLDER"
    echo "  - Apache port: 8080 (Homebrew default)"
    echo ""
    
    if [[ "$IS_ROOT" == true ]]; then
        echo "⚠️ IMPORTANT - Manual steps required (script was run as root):"
        echo "1. Switch to your regular user account"
        echo "2. Run: brew services restart httpd"
        echo "3. Run: brew services restart mariadb"
        echo ""
    fi
    
    echo "🔒 Security recommendations:"
    if [[ "$ROOT_PASS_SET" == false ]]; then
        echo "  - Run 'mysql_secure_installation' to secure MariaDB"
    fi
    echo "  - Consider setting up SSL/TLS certificates for production use"
    echo "  - Review and customize Apache security settings as needed"

elif [[ "$os" == "linux" ]]; then

    echo "Platform detected: Linux - Beginning setup process..."

    # Define Apache and PHP paths for Linux
    HTTPD_CONF="/etc/apache2/apache2.conf"
    HTTPD_VHOSTS="/etc/apache2/sites-available/000-default.conf"
    PHP_INI="/etc/php/8.2/apache2/php.ini"
    
    # Alternative paths for different Linux distributions
    if [ ! -f "$HTTPD_CONF" ]; then
        # Try CentOS/RHEL paths
        HTTPD_CONF="/etc/httpd/conf/httpd.conf"
        HTTPD_VHOSTS="/etc/httpd/conf.d/vhost.conf"
        PHP_INI="/etc/php.ini"
    fi

    # Create backups of configuration files
    backup_config_files "$HTTPD_CONF" "$HTTPD_VHOSTS" "Linux"

    # Update package repositories
    echo "🔄 Updating package repositories..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update || {
            echo "⚠️ Failed to update package repositories."
        }
    elif command -v yum &> /dev/null; then
        sudo yum update -y || {
            echo "⚠️ Failed to update package repositories."
        }
    elif command -v dnf &> /dev/null; then
        sudo dnf update -y || {
            echo "⚠️ Failed to update package repositories."
        }
    fi

    # Install essential packages
    echo "📦 Installing essential packages..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y wget unzip apache2 php8.2 php8.2-mysql php8.2-curl php8.2-gd php8.2-mbstring php8.2-xml php8.2-soap mariadb-server || {
            echo "❌ Failed to install packages via apt-get."
            exit 1
        }
    elif command -v yum &> /dev/null; then
        sudo yum install -y wget unzip httpd php php-mysql php-curl php-gd php-mbstring php-xml php-soap mariadb-server || {
            echo "❌ Failed to install packages via yum."
            exit 1
        }
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y wget unzip httpd php php-mysql php-curl php-gd php-mbstring php-xml php-soap mariadb-server || {
            echo "❌ Failed to install packages via dnf."
            exit 1
        }
    else
        echo "❌ No supported package manager found (apt-get, yum, or dnf)."
        exit 1
    fi

    # Set document root and instance folder
    DOCUMENT_ROOT="/var/www/html"
    CRM_PUBLIC_DIR="$DOCUMENT_ROOT/$INSTANCE_FOLDER/public"

    # Configure Apache
    echo "🔧 Configuring Apache..."
    if [ -f "$HTTPD_CONF" ]; then
        # Enable required modules
        if command -v a2enmod &> /dev/null; then
            sudo a2enmod rewrite headers || {
                echo "⚠️ Failed to enable Apache modules."
            }
        fi
        
        # Update DocumentRoot in main config or vhost
        if [ -f "$HTTPD_VHOSTS" ]; then
            sudo sed -i "s|DocumentRoot.*|DocumentRoot $CRM_PUBLIC_DIR|" "$HTTPD_VHOSTS" || {
                echo "⚠️ Failed to update DocumentRoot in vhost config."
            }
        fi
    fi

    # Create directories and download SuiteCRM
    echo "🔧 Creating directories and downloading SuiteCRM..."
    sudo mkdir -p "$DOCUMENT_ROOT/$INSTANCE_FOLDER" || {
        echo "❌ Failed to create CRM directory."
        exit 1
    }
    
    cd "$DOCUMENT_ROOT/$INSTANCE_FOLDER" || {
        echo "❌ Failed to change to CRM directory."
        exit 1
    }
    
    # Download and extract SuiteCRM
    DOWNLOAD_URL="https://suitecrm.com/download/148/suite87/564667/$ZIP_FILENAME"
    download_and_extract_suitecrm "$DOWNLOAD_URL" "$DOCUMENT_ROOT/$INSTANCE_FOLDER"

    # Update paths in httpd-vhosts.conf to use consistent variables
    update_vhosts_paths "$HTTPD_VHOSTS" "$DOCUMENT_ROOT" "$INSTANCE_FOLDER" "Linux"

    # Set proper permissions
    echo "🔧 Setting permissions..."
    sudo chown -R www-data:www-data "$DOCUMENT_ROOT/$INSTANCE_FOLDER" || {
        sudo chown -R apache:apache "$DOCUMENT_ROOT/$INSTANCE_FOLDER" || {
            echo "⚠️ Failed to set ownership. Using generic permissions."
            sudo chmod -R 755 "$DOCUMENT_ROOT/$INSTANCE_FOLDER"
        }
    }

    # Configure MariaDB
    echo "🔧 Configuring MariaDB..."
    sudo systemctl start mariadb || sudo service mariadb start || {
        echo "❌ Failed to start MariaDB."
        exit 1
    }
    
    sudo systemctl enable mariadb || sudo chkconfig mariadb on || {
        echo "⚠️ Failed to enable MariaDB auto-start."
    }

    # Create database and user
    if ! mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        echo "❌ Failed to configure database."
        exit 1
    fi

    # Start Apache
    echo "🔄 Starting Apache..."
    sudo systemctl start apache2 || sudo systemctl start httpd || sudo service apache2 start || sudo service httpd start || {
        echo "❌ Failed to start Apache."
        exit 1
    }
    
    sudo systemctl enable apache2 || sudo systemctl enable httpd || sudo chkconfig httpd on || {
        echo "⚠️ Failed to enable Apache auto-start."
    }

    echo "✅ Linux setup completed successfully!"
    echo "📝 You can now complete the installation of your CRM at: http://$server_ip"

elif [[ "$os" == "windows" ]]; then

    echo "Platform detected: Windows (Git Bash or Cygwin) - Beginning setup process..."

    # Check for administrative privileges
    if ! net session &>/dev/null; then
        echo "❌ This script requires administrative privileges on Windows."
        echo "Please right-click on Git Bash and select 'Run as administrator', then try again."
        exit 1
    fi

    # Check for Chocolatey
    if ! command -v choco &> /dev/null; then
        echo "⚠️ Chocolatey not found. Please install Chocolatey first:"
        echo "Run PowerShell as Administrator and execute:"
        echo "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
        exit 1
    else
        echo "✅ Chocolatey is installed."
    fi

    # Define base paths with proper Windows path handling
    APACHE_PATH=$(cygpath -w "/c/tools/apache24" | sed 's/\\/\//g')
    PHP_PATH=$(cygpath -w "/c/tools/php82" | sed 's/\\/\//g')
    DOCUMENT_ROOT="$APACHE_PATH/htdocs"
    INSTANCE_FOLDER="$DOCUMENT_ROOT/$INSTANCE_FOLDER"
    
    # Configuration files
    APACHE_CONF="$APACHE_PATH/conf/httpd.conf"
    APACHE_VHOSTS="$APACHE_PATH/conf/extra/httpd-vhosts.conf"
    PHP_INI="$PHP_PATH/php.ini"
    PHP_INI_DEVELOPMENT="$PHP_PATH/php.ini-development"

    # Create backups of configuration files
    backup_config_files "$APACHE_CONF" "$APACHE_VHOSTS" "Windows"

    # Install essential packages with error handling
    echo "📦 Installing essential tools..."
    choco install wget unzip -y || {
        echo "❌ Failed to install essential tools. Please check your internet connection."
        exit 1
    }

    # Install Apache HTTP Server
    echo "📦 Installing Apache HTTP Server..."
    if ! choco list --local-only | grep -q apache-httpd; then
        choco install apache-httpd -y || {
            echo "❌ Failed to install Apache HTTP Server."
            exit 1
        }
    else
        echo "✅ Apache HTTP Server is already installed."
    fi

    # Install PHP with improved handling
    echo "📦 Installing PHP 8.2..."
    install_php_PC || {
        echo "❌ Failed to install PHP 8.2."
        exit 1
    }

    # Verify PHP installation
    if ! command -v php &> /dev/null; then
        echo "❌ PHP installation failed or PHP is not in PATH."
        echo "Please add PHP to your PATH and try again."
        exit 1
    else
        PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}')
        echo "✅ PHP $PHP_VERSION installed successfully."
    fi

    # Configure PHP for Apache
    echo "🔧 Configuring PHP with Apache..."
    if [ -f "$APACHE_CONF" ]; then
        # Check if PHP module is already configured
        if ! grep -q "LoadModule php_module" "$APACHE_CONF"; then
            echo "LoadModule php_module \"$PHP_PATH/php8apache2_4.dll\"" >> "$APACHE_CONF" || {
                echo "❌ Failed to add PHP module to Apache config."
                exit 1
            }
            echo "AddType application/x-httpd-php .php" >> "$APACHE_CONF"
            echo "PHPIniDir \"$PHP_PATH\"" >> "$APACHE_CONF"
            echo "✅ PHP module added to Apache configuration."
        else
            echo "✅ PHP module already configured in Apache."
        fi
        
        # Enable required modules for CRM
        for MODULE in rewrite headers; do
            if grep -q "#LoadModule ${MODULE}_module" "$APACHE_CONF"; then
                sed -i "s/#LoadModule ${MODULE}_module/LoadModule ${MODULE}_module/" "$APACHE_CONF" || {
                    echo "⚠️ Failed to enable $MODULE module."
                }
                echo "✅ Enabled $MODULE module."
            else
                echo "✅ $MODULE module already enabled."
            fi
        done
        
        # Enable vhosts in main config if needed
        if grep -q "#Include conf/extra/httpd-vhosts.conf" "$APACHE_CONF"; then
            sed -i 's/#Include conf\/extra\/httpd-vhosts.conf/Include conf\/extra\/httpd-vhosts.conf/' "$APACHE_CONF" || {
                echo "⚠️ Failed to enable vhosts configuration."
            }
            echo "✅ Virtual hosts enabled."
        fi
    else
        echo "❌ Apache config file not found at $APACHE_CONF"
        exit 1
    fi

    # Configure php.ini with robust error handling
    echo "🔧 Configuring PHP settings..."
    if [ ! -f "$PHP_INI" ] && [ -f "$PHP_INI_DEVELOPMENT" ]; then
        echo "Creating php.ini from development template..."
        cp "$PHP_INI_DEVELOPMENT" "$PHP_INI" || {
            echo "❌ Failed to create php.ini from template."
            exit 1
        }
    fi
    
    if [ -f "$PHP_INI" ]; then
        # Create backup of php.ini
        cp "$PHP_INI" "${PHP_INI}.bak" || {
            echo "⚠️ Failed to create backup of php.ini"
        }
        
        # Update settings in php.ini with error checking
        echo "🔧 Updating PHP settings..."
        for SETTING in \
            "memory_limit = 512M" \
            "upload_max_filesize = 50M" \
            "post_max_size = 50M" \
            "max_execution_time = 300" \
            "display_errors = Off" \
            "expose_php = Off"; do
            
            SETTING_NAME=$(echo "$SETTING" | cut -d'=' -f1 | tr -d ' ')
            SETTING_VALUE=$(echo "$SETTING" | cut -d'=' -f2)
            
            sed -i "s/^${SETTING_NAME} =.*/${SETTING}/" "$PHP_INI" || {
                echo "⚠️ Failed to set $SETTING_NAME to $SETTING_VALUE"
            }
        done
        
        # Enable required extensions
        for EXT in curl gd mbstring mysqli pdo_mysql soap xml; do
            sed -i "s/;extension=${EXT}/extension=${EXT}/" "$PHP_INI" || {
                echo "⚠️ Failed to enable $EXT extension"
            }
        done
        
        echo "✅ PHP configuration updated."
    else
        echo "❌ PHP config file not found at $PHP_INI"
        exit 1
    fi

    # MariaDB installation with improved error handling
    echo "📦 Installing MariaDB..."
    if ! choco list --local-only | grep -q mariadb; then
        choco install mariadb -y || {
            echo "❌ Failed to install MariaDB."
            exit 1
        }
        
        # Wait for MariaDB to initialize
        echo "⏳ Waiting for MariaDB to initialize..."
        for i in {1..30}; do
            if net start | grep -q "MariaDB"; then
                echo "✅ MariaDB service is running."
                break
            elif [ $i -eq 30 ]; then
                echo "⚠️ Timeout waiting for MariaDB service. Attempting to start it manually..."
                net start MariaDB || {
                    echo "❌ Failed to start MariaDB service. Please start it manually and try again."
                    exit 1
                }
            else
                echo "Waiting for MariaDB service to start ($i/30)..."
                sleep 2
            fi
        done
    else
        echo "✅ MariaDB is already installed."
        
        # Ensure service is running
        if ! net start | grep -q "MariaDB"; then
            echo "⚠️ MariaDB service is not running. Attempting to start..."
            net start MariaDB || {
                echo "❌ Failed to start MariaDB service."
                exit 1
            }
        fi
    fi
    
    # Configure database with robust error handling
    echo "🔧 Configuring main database..."
    if ! mysql -u root -e "SELECT 1" &>/dev/null; then
        echo "❌ Cannot connect to MySQL. Please check if the service is running and credentials are correct."
        exit 1
    fi
    
    # Create database with error checking
    if ! mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        echo "❌ Failed to create database and user."
        exit 1
    fi

    # Verify database was created
    if ! mysql -u root -e "USE CRM"; then
        echo "❌ Failed to create database CRM. Please check MySQL root permissions."
        exit 1
    else
        echo "✅ Database CRM created successfully."
    fi

    # Verify User creation
    if ! mysql -u root -e "SELECT User FROM mysql.user WHERE User='$db_user';" | grep -q "$db_user"; then
        echo "❌ Failed to create user $db_user."
        exit 1
    else
        echo "✅ User $db_user created successfully."
        
        # Additional verification of user permissions
        GRANTS=$(mysql -u root -e "SHOW GRANTS FOR '$db_user'@'localhost';" | grep "ON \`CRM\`\." || echo "")
        if [[ -z "$GRANTS" ]]; then
            echo "⚠️ Warning: User $db_user may not have proper permissions on CRM database."
        else
            echo "✅ User permissions verified."
        fi
    fi

    # Create directories for SuiteCRM with error handling
    echo "🔧 Creating directories for SuiteCRM..."
    mkdir -p "$DOCUMENT_ROOT/$INSTANCE_FOLDER" || {
        echo "❌ Failed to create CRM directory. Check permissions."
        exit 1
    }
    
    # Download and extract SuiteCRM with robust error handling
    echo "📦 Downloading SuiteCRM..."
    cd "$DOCUMENT_ROOT/$INSTANCE_FOLDER" || {
        echo "❌ Failed to change to CRM directory."
        exit 1
    }
    
    if [ ! -f "suitecrm-8-8-0.zip" ]; then
        wget -O suitecrm-8-8-0.zip https://suitecrm.com/download/148/suite87/564667/suitecrm-8-8-0.zip || {
            echo "❌ Failed to download SuiteCRM."
            exit 1
        }
    else
        echo "✅ SuiteCRM archive already exists, using cached version."
    fi
    
    echo "📦 Extracting SuiteCRM..."
    unzip -o suitecrm-8-8-0.zip || {
        echo "❌ Failed to extract SuiteCRM."
        exit 1
    }
    echo "✅ SuiteCRM extracted successfully."

    # Configure VirtualHost with improved security
    echo "🔧 Configuring VirtualHost..."
    if [ -f "$APACHE_CONF" ]; then
        # Make sure the vhosts directory exists
        mkdir -p "$(dirname "$APACHE_VHOSTS")" || {
            echo "⚠️ Failed to create vhosts directory."
            exit 1
        }

        # Create a temporary file to hold the VirtualHost configuration
        tmpfile=$(mktemp) || {
            echo "❌ Failed to create temporary file for VirtualHost config."
            exit 1
        }

        # Write the VirtualHost configuration with security headers
        cat << EOF > "$tmpfile"
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot "$DOCUMENT_ROOT/$INSTANCE_FOLDER/public"
    ServerName $server_ip

    <Directory "$DOCUMENT_ROOT/$INSTANCE_FOLDER/public">
        Options -Indexes +FollowSymLinks +MultiViews
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog logs/crm-error.log
    CustomLog logs/crm-access.log combined

    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOF

        # Move the temporary file to the final config path
        mv "$tmpfile" "$APACHE_VHOSTS" || {
            echo "❌ Failed to move VirtualHost configuration to $APACHE_VHOSTS."
            exit 1
        }

        echo "✅ VirtualHost configuration created with security headers."
    else
        echo "❌ Failed to configure VirtualHost - Apache config not found at $APACHE_CONF."
        exit 1
    fi

    # Update paths in httpd-vhosts.conf to use consistent variables
    update_vhosts_paths "$APACHE_VHOSTS" "$DOCUMENT_ROOT" "$INSTANCE_FOLDER" "Windows"

    # Set permissions with Windows compatibility
    echo "🔧 Setting permissions..."
    if command -v icacls &>/dev/null; then
        # Grant appropriate permissions to the Apache user
        APACHE_USER="NETWORK SERVICE"
        
        # Find proper Apache service user
        if net user | grep -q "Apache"; then
            APACHE_USER="Apache"
        fi
        
        # Set permissions - Full control for Apache user, Read/Execute for Everyone
        icacls "$DOCUMENT_ROOT/$INSTANCE_FOLDER" /grant:r "$APACHE_USER:(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Everyone:(OI)(CI)RX" /T || {
            echo "⚠️ Failed to set Windows permissions with icacls."
            echo "Falling back to simpler permissions..."
            icacls "$DOCUMENT_ROOT/$INSTANCE_FOLDER" /grant Everyone:F /T
        }
        
        # Make storage and cache directories writable
        if [ -d "$DOCUMENT_ROOT/$INSTANCE_FOLDER/storage" ]; then
            icacls "$DOCUMENT_ROOT/$INSTANCE_FOLDER/storage" /grant:r "$APACHE_USER:(OI)(CI)F" /T
        fi
        if [ -d "$DOCUMENT_ROOT/$INSTANCE_FOLDER/cache" ]; then
            icacls "$DOCUMENT_ROOT/$INSTANCE_FOLDER/cache" /grant:r "$APACHE_USER:(OI)(CI)F" /T
        fi
    else
        echo "⚠️ icacls command not found. Using generic permissions."
        chmod -R 755 "$DOCUMENT_ROOT/$INSTANCE_FOLDER"
    fi
    echo "✅ Permissions set."

    # Create a simple health check
    echo "<?php echo 'CRM Health Check: ' . date('Y-m-d H:i:s'); ?>" > "$DOCUMENT_ROOT/$INSTANCE_FOLDER/public/health.php" || {
        echo "⚠️ Failed to create health check file."
    }
    
    # Restart Apache service
    echo "🔄 Restarting Apache..."
    if command -v httpd &>/dev/null; then
        # Check if Apache is already running
        if netstat -ano | grep -q ":80 "; then
            httpd -k restart || {
                echo "⚠️ Failed to restart Apache. Attempting to stop and start..."
                httpd -k stop
                sleep 2
                httpd -k start || {
                    echo "❌ Failed to start Apache. Please check configuration and try manually."
                    exit 1
                }
            }
        else
            httpd -k start || {
                echo "❌ Failed to start Apache. Please check configuration and try manually."
                exit 1
            }
        fi
    else
        # Try using Windows service name
        net stop Apache2.4 && net start Apache2.4 || {
            echo "⚠️ Failed to restart Apache via service. Please restart it manually."
        }
    fi

    # Final check of services
    echo "🔍 Checking services..."
    if netstat -ano | grep -q ":80 "; then
        echo "✅ Apache is running and listening on port 80."
    else
        echo "⚠️ Apache may not be running on port 80. Please check configuration."
    fi
    
    if netstat -ano | grep -q ":3306 "; then
        echo "✅ MariaDB is running and listening on port 3306."
    else
        echo "⚠️ MariaDB may not be running. Please check configuration."
    fi

    # Firewall configuration
    echo "🔧 Configuring Windows Firewall..."
    # Check if PowerShell is available
    if command -v powershell &>/dev/null; then
        powershell -Command "New-NetFirewallRule -DisplayName 'Allow HTTP' -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow" || {
            echo "⚠️ Failed to create firewall rule. Please manually allow port 80 in Windows Firewall."
        }
    else
        echo "⚠️ PowerShell not found. Please manually add a firewall rule for port 80."
    fi

    echo "✅ Windows setup completed successfully."
    echo "📝 You can now complete the installation of your CRM from the web browser using: http://$server_ip"
    echo "👉 Health check URL: http://$server_ip/health.php"
    echo "⚠️ SECURITY REMINDER: Run 'mysql_secure_installation' to secure your MariaDB installation."
    echo "📋 Configuration summary:"
    echo "  - Database: CRM"
    echo "  - Database User: $db_user"
    echo "  - Document Root: $DOCUMENT_ROOT/$INSTANCE_FOLDER"
    echo "  - Apache Configuration: $APACHE_CONF"
    echo "  - PHP Configuration: $PHP_INI"
    echo "⚠️ Important: If you encounter issues, check Apache and MariaDB logs."
    echo "    - Apache logs: $APACHE_PATH/logs/"
    echo "    - MariaDB logs: Check Windows Event Viewer"
fi
# Output blank line to help see where command completed
echo
