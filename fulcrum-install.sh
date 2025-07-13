#!/bin/bash

# Fulcrum Electrum Server Setup Script for Debian 12 Bookworm
# Configures Fulcrum with Let's Encrypt SSL, using an existing Bitcoin node
# Accepts connections on port 443, avoids qt5-default error

# Exit on error
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to prompt for user input with validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local value
    read -p "$prompt" value
    if [ -z "$value" ]; then
        echo "Error: Input cannot be empty."
        exit 1
    fi
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
apt-get install -y build-essential cmake libssl-dev zlib1g-dev qtbase5-dev qt5-qmake qtbase5-dev-tools libzmq3-dev certbot python3-certbot-nginx git

# Install Fulcrum
echo "Installing Fulcrum..."
cd /opt
git clone https://github.com/cculianu/Fulcrum.git
cd Fulcrum
mkdir build
cd build
cmake ..
make -j$(nproc)
make install
cd /opt
rm -rf Fulcrum

# Create Fulcrum user and directories
mkdir -p /var/lib/fulcrum
useradd -m -s /bin/false fulcrum || echo "User fulcrum already exists."
chown -R fulcrum:fulcrum /var/lib/fulcrum
chmod 750 /var/lib/fulcrum

# Prompt for public DNS name
prompt_for_input "Enter your public DNS name (e.g., electrum.example.com): " PUBLIC_DNS

# Prompt for Bitcoin RPC credentials
prompt_for_input "Enter Bitcoin RPC username: " BITCOIN_RPC_USER
prompt_for_input "Enter Bitcoin RPC password: " BITCOIN_RPC_PASSWORD
prompt_for_input "Enter Bitcoin RPC host (default: 127.0.0.1): " BITCOIN_RPC_HOST
BITCOIN_RPC_HOST=${BITCOIN_RPC_HOST:-127.0.0.1}
prompt_for_input "Enter Bitcoin RPC port (default: 8332): " BITCOIN_RPC_PORT
BITCOIN_RPC_PORT=${BITCOIN_RPC_PORT:-8332}

# Create Fulcrum configuration directory
mkdir -p /etc/fulcrum
CONFIG_FILE="/etc/fulcrum/fulcrum.conf"

# Write Fulcrum configuration with optimized settings for high-capacity server
echo "Creating Fulcrum configuration..."
cat > $CONFIG_FILE <<EOL
# Fulcrum Configuration
# Bitcoin node settings
[bitcoin]
datadir = /var/lib/fulcrum
rpcuser = $BITCOIN_RPC_USER
rpcpassword = $BITCOIN_RPC_PASSWORD
rpchost = $BITCOIN_RPC_HOST
rpcport = $BITCOIN_RPC_PORT
workers = 8
rpc_timeout = 60
fast-sync = true

# Electrum server settings
[electrum]
host = 0.0.0.0
tcp_port = 50001
ssl_port = 443
certfile = /etc/letsencrypt/live/$PUBLIC_DNS/fullchain.pem
keyfile = /etc/letsencrypt/live/$PUBLIC_DNS/privkey.pem
banner = Welcome to Fulcrum Electrum Server at $PUBLIC_DNS
maxclients = 5000
clienttimeout = 300
rpcport = 8000
rpchost = 127.0.0.1
cache = 2000
peer-discovery = true
bandwidth-limit = 400000

# Logging settings
[logging]
level = info
file = /var/log/fulcrum.log

# Database settings
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
LimitNOFILE=65535

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
echo "Fulcrum server setup complete!"
echo "Server is running and accessible at:"
echo "- TCP: $PUBLIC_DNS:50001"
echo "- SSL: $PUBLIC_DNS:443"
echo "Ensure your Bitcoin node is fully synced and running."
echo "You may need to configure your DNS to point $PUBLIC_DNS to this server's public IP."
echo "Monitor logs with: journalctl -u fulcrum -f"
