#!/bin/bash

# Fulcrum Electrum Server Setup Script for Debian 12 Bookworm
# Configures Fulcrum with Let's Encrypt SSL (port 443), Tor hidden service (TCP 50001), and an existing Bitcoin node
# Includes setcap for port 443 binding, optimized for high-capacity server
# No ZMQ configuration, as Bitcoin node lacks ZMQ support

# Exit on error
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to prompt for user input with improved validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    local value
    read -p "$prompt${default:+ [default: $default]}: " value
    value=${value:-$default}
    if [ -z "$value" ]; then
        echo "Error: Input for $var_name cannot be empty."
        exit 1
    fi
    case $var_name in
        BITCOIN_RPC_USER|BITCOIN_RPC_PASSWORD)
            if [[ "$value" =~ [[:space:]] || "$value" =~ [^a-zA-Z0-9_-] ]]; then
                echo "Error: $var_name cannot contain spaces or special characters (except _ and -)."
                exit 1
            fi
            ;;
        BITCOIN_RPC_HOST)
            if ! [[ "$value" =~ ^[0-9.]+$ || "$value" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                echo "Error: Invalid $var_name format. Use IP or hostname."
                exit 1
            fi
            ;;
        BITCOIN_RPC_PORT)
            if ! [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le 65535 ]]; then
                echo "Error: $var_name must be a valid port number (1-65535)."
                exit 1
            fi
            ;;
        PUBLIC_DNS)
            if ! [[ "$value" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                echo "Error: Invalid $var_name format. Use a valid domain (e.g., electrum.degga.net)."
                exit 1
            fi
            ;;
    esac
    eval "$var_name='$value'"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (use sudo)."
    exit 1
fi

# Update package lists
echo "Updating package lists..."
apt-get update

# Install required dependencies
echo "Installing dependencies..."
apt-get install -y build-essential qtbase5-dev qt5-qmake qtbase5-dev-tools libssl-dev zlib1g-dev libbz2-dev certbot python3-certbot-nginx git libcap2-bin tor

# Install Fulcrum
echo "Installing Fulcrum..."
cd /opt
rm -rf Fulcrum
git clone https://github.com/cculianu/Fulcrum.git
if [ ! -f Fulcrum/Fulcrum.pro ]; then
    echo "Error: Failed to clone Fulcrum or Fulcrum.pro missing. Check network or GitHub repository."
    exit 1
fi
cd Fulcrum
qmake Fulcrum.pro
make -j$(nproc)
make install
cd /opt

# Grant Fulcrum permission to bind to privileged ports (fixes "address is protected" error)
echo "Granting port binding permissions..."
setcap 'cap_net_bind_service=+ep' /usr/local/bin/Fulcrum

# Create Fulcrum user and directories
echo "Creating Fulcrum user and directories..."
mkdir -p /var/lib/fulcrum
useradd -m -s /bin/false fulcrum || echo "User fulcrum already exists."
chown -R fulcrum:fulcrum /var/lib/fulcrum
chmod 750 /var/lib/fulcrum

# Prompt for public DNS name and Bitcoin RPC credentials
prompt_for_input "Enter your public DNS name (e.g., electrum.degga.net)" PUBLIC_DNS
prompt_for_input "Enter Bitcoin RPC username" BITCOIN_RPC_USER
prompt_for_input "Enter Bitcoin RPC password" BITCOIN_RPC_PASSWORD
prompt_for_input "Enter Bitcoin RPC host" BITCOIN_RPC_HOST "127.0.0.1"
prompt_for_input "Enter Bitcoin RPC port" BITCOIN_RPC_PORT "8332"

# Create Fulcrum configuration directory
mkdir -p /etc/fulcrum
CONFIG_FILE="/etc/fulcrum/fulcrum.conf"

# Write Fulcrum configuration
echo "Creating Fulcrum configuration..."
cat > $CONFIG_FILE <<EOL
# Fulcrum Configuration
[bitcoin]
datadir = /var/lib/fulcrum
bitcoind = http://$BITCOIN_RPC_USER:$BITCOIN_RPC_PASSWORD@$BITCOIN_RPC_HOST:$BITCOIN_RPC_PORT
workers = 8
rpc_timeout = 60
utxo_cache = 1000

[electrum]
host = 0.0.0.0
tcp = 0.0.0.0:50001
ssl = 0.0.0.0:443
cert = /etc/letsencrypt/live/$PUBLIC_DNS/fullchain.pem
key = /etc/letsencrypt/live/$PUBLIC_DNS/privkey.pem
banner = Welcome to Fulcrum Electrum Server at $PUBLIC_DNS
maxclients = 1000
clienttimeout = 300
rpcport = 8000
rpchost = 127.0.0.1
cache = 2000
peer-discovery = true
bandwidth-limit = 400000

[logging]
level = info
file = /var/log/fulcrum.log

[database]
db-max-mem = 2000
db-num-shards = 32
EOL

# Set log file permissions
touch /var/log/fulcrum.log
chown fulcrum:fulcrum /var/log/fulcrum.log

# Install Nginx for Let's Encrypt validation
if ! command_exists nginx; then
    echo "Installing Nginx..."
    apt-get install -y nginx
fi

# Obtain Let's Encrypt certificate
echo "Obtaining Let's Encrypt certificate..."
certbot certonly --nginx -d $PUBLIC_DNS --non-interactive --agree-tos --email admin@$PUBLIC_DNS || {
    echo "Failed to obtain Let's Encrypt certificate. Please check your DNS settings and try again."
    exit 1
}
chgrp -R fulcrum /etc/letsencrypt/{live,archive}
chmod -R g+rx /etc/letsencrypt/{live,archive}

# Configure Tor hidden service
echo "Configuring Tor hidden service..."
mkdir -p /var/lib/tor/hidden_service_fulcrum
chown -R tor:tor /var/lib/tor/hidden_service_fulcrum
chmod 700 /var/lib/tor/hidden_service_fulcrum
cat >> /etc/tor/torrc <<EOL
# Hidden Service for Fulcrum TCP
HiddenServiceDir /var/lib/tor/hidden_service_fulcrum/
HiddenServiceVersion 3
HiddenServicePort 50001 127.0.0.1:50001
EOL
systemctl reload tor

# Create systemd service for Fulcrum
echo "Creating Fulcrum systemd service..."
cat > /etc/systemd/system/fulcrum.service <<EOL
[Unit]
Description=Fulcrum Electrum Server
After=network.target

[Service]
User=fulcrum
Group=fulcrum
ExecStart=/usr/local/bin/Fulcrum /etc/fulcrum/fulcrum.conf
WorkingDirectory=/var/lib/fulcrum
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable fulcrum
systemctl start fulcrum

# Open firewall ports (if ufw is installed)
if command_exists ufw; then
    echo "Configuring firewall..."
    ufw allow 443/tcp
    ufw allow 50001/tcp
    echo "Firewall rules updated."
fi

# Display completion message
echo "Fulcrum server setup complete with Tor connectivity!"
echo "Server is running and accessible at:"
echo "- Clearnet TCP: $PUBLIC_DNS:50001"
echo "- Clearnet SSL: $PUBLIC_DNS:443"
echo "- Tor TCP: $(cat /var/lib/tor/hidden_service_fulcrum/hostname):50001"
echo "Ensure your Bitcoin node is fully synced and running."
echo "Monitor logs with: journalctl -u fulcrum -f"
