#!/bin/bash

# Fulcrum Electrum Server Setup Script for Debian 12 Bookworm
# Configures Fulcrum with Let's Encrypt SSL (port 443), Tor hidden service (TCP 50001), and an existing Bitcoin node
# Includes setcap for port 443, announcement settings (hostname, public_tcp_port, public_ssl_port, tor_hostname, tor_tcp_port, tor_banner),
# Tor proxy for outbound connections, Nginx cleanup, certificate renewal, enhanced error handling, and optional commented settings
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

# Check Bitcoin Core configuration
echo "Ensure Bitcoin Core is running with the following in ~/.bitcoin/bitcoin.conf:"
echo "server=1"
echo "txindex=1"
echo "rpcuser=<your-rpc-user>"
echo "rpcpassword=<your-rpc-password>"
read -p "Press Enter to continue if Bitcoin Core is configured, or Ctrl+C to exit and configure it..."

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
if [ ! -d Fulcrum ]; then
    echo "Error: Failed to clone Fulcrum repository. Check network or GitHub availability."
    exit 1
fi
cd Fulcrum
if [ ! -f Fulcrum.pro ]; then
    echo "Error: Fulcrum.pro missing. Check repository integrity."
    exit 1
fi
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

# Wait for Tor to generate onion address
sleep 5
ONION_ADDRESS=$(cat /var/lib/tor/hidden_service_fulcrum/hostname 2>/dev/null || echo "unavailable")
if [ "$ONION_ADDRESS" = "unavailable" ]; then
    echo "Warning: Failed to retrieve Tor onion address. Check Tor logs with 'journalctl -u tor -f'."
fi

# Create Fulcrum configuration directory
mkdir -p /etc/fulcrum
CONFIG_FILE="/etc/fulcrum/fulcrum.conf"

# Write Fulcrum configuration with announcement, Tor proxy, and commented optional settings
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
hostname = $PUBLIC_DNS
public_tcp_port = 50001
public_ssl_port = 443
tor_hostname = $ONION_ADDRESS
tor_banner = Welcome to Fulcrum Electrum Server (Tor) at $ONION_ADDRESS
tor_tcp_port = 50001
tor_proxy = socks5://127.0.0.1:9050
banner = Welcome to Fulcrum Electrum Server at $PUBLIC_DNS
maxclients = 1000
clienttimeout = 300
rpcport = 8000
rpchost = 127.0.0.1
cache = 2000
peer-discovery = true
bandwidth-limit = 400000
# Optional settings (uncomment to enable):
# max_clients_per_ip = 48
# max_pending_connections = 120
# max_subs = 20000000
# max_subs_per_ip = 120000
# bitcoind_throttle = 200 80 20
# stats = 0.0.0.0:8080
# polltime = 1.0
# txhash_cache = 512

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
if [ ! -f "/etc/letsencrypt/live/$PUBLIC_DNS/fullchain.pem" ]; then
    echo "Error: Certificate not found at /etc/letsencrypt/live/$PUBLIC_DNS/fullchain.pem."
    exit 1
fi

# Stop and disable Nginx to prevent port 443 conflicts
echo "Stopping and disabling
