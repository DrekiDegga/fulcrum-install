# Fulcrum Electrum Server Setup Script
This Bash script automates the installation and configuration of a high-capacity [Fulcrum](https://github.com/cculianu/Fulcrum) Electrum server on Debian 12 "Bookworm". It sets up Fulcrum to serve Electrum clients over TCP (port 50001) and SSL (port 443 with Let’s Encrypt), connecting to an existing Bitcoin Core node. The script is optimized for public servers with robust performance settings for high client loads.Features

- Installs Fulcrum with all dependencies, using qmake for compilation.
- Configures Let’s Encrypt SSL for secure connections on port 443.
- Includes high-capacity settings: maxclients=10000, cache=4000, utxo_cache=1000, workers=16, db-num-shards=16.
- Validates Bitcoin RPC credentials and ensures compatibility with Bitcoin Core.
- Sets up logging to /var/log/fulcrum.log and systemd journal.
- Configures firewall rules (if ufw is installed) for ports 443 and 50001.

## Requirements

- OS: Debian 12 "Bookworm".
- Bitcoin Node: Fully synced Bitcoin Core with txindex=1 and server=1.
- Hardware: 8+ CPU cores, 16 GB RAM, 1.3 TB SSD (800 GB for Fulcrum index, \~500 GB for Bitcoin Core).
- Network: Ports 443 (SSL) and 50001 (TCP) open.
- DNS: A public DNS name (e.g., [electrum.example.com](http://electrum.example.com)) resolving to your server’s public IP.
- Permissions: Run as root (via sudo).

## Installation

1. Clone or download this repository:

   bash

   ```bash
   git clone <https://github.com/DrekiDegga/fulcrum-install.git>
   cd <fulcrum-install>
   ```
2. Make the script executable:

   bash

   ```bash
   chmod +x fulcrum-install.sh
   ```
3. Run the script as root:

   bash

   ```bash
   sudo ./fulcrum-install.sh
   ```
4. Follow prompts to enter:
   - Public DNS name (e.g., [electrum.example.com](http://electrum.example.com)).
   - Bitcoin RPC username and password (from bitcoin.conf).
   - Bitcoin RPC host (default: 127.0.0.1) and port (default: 8332).

## Post-Installation

- Verify Setup:
  - Check service:

    bash

    ```bash
    systemctl status fulcrum
    ```
  - Monitor logs:

    bash

    ```bash
    journalctl -u fulcrum -f
    ```

      or

    bash

    ```bash
    cat /var/log/fulcrum.log
    ```
  - Test connectivity:

    bash

    ```bash
    openssl s_client -connect yourdomain.com:443
    ```

      or connect an Electrum wallet to yourdomain.com:443:s or yourdomain.com:50001:t.
- Initial Sync: Indexing takes 1-2 days with utxo_cache=1000. After completion (800 GB in /var/lib/fulcrum), set utxo_cache=0 in /etc/fulcrum/fulcrum.conf for full validation:

  bash

  ```bash
  sudo nano /etc/fulcrum/fulcrum.conf
  sudo systemctl restart fulcrum
  ```

## Configuration
The script generates /etc/fulcrum/fulcrum.conf with:

- Bitcoin Node: Connects via bitcoind=<http://user:pass@host:port>.
- High-Capacity Settings: Supports 10,000 clients (maxclients=10000), 4 GB cache (cache=4000), 16 workers (workers=16), and 16 database shards (db-num-shards=16).
- SSL: Uses Let’s Encrypt certificates for port 443.
- Logging: Writes to /var/log/fulcrum.log and systemd journal.

Customize settings in /etc/fulcrum/fulcrum.conf for your hardware (e.g., increase cache to 8000 for 64 GB RAM).

## Troubleshooting

- Bitcoin Node Issues:

  bash

  ```bash
  bitcoin-cli -rpcuser=<user> -rpcpassword=<pass> -rpcconnect=127.0.0.1 -rpcport=8332 getblockchaininfo
  ```

    Ensure "initialblockdownload": false and "chain": "main".
- Connectivity Issues:
  - Verify ports:

    bash

    ```bash
    nc -zv yourdomain.com 443
    nc -zv yourdomain.com 50001
    ```
  - Check DNS:

    bash

    ```bash
    dig +short yourdomain.com
    ```
- Logs: Review:

  bash

  ```bash
  journalctl -u fulcrum -f
  ```

    or

  bash

  ```bash
  cat /var/log/fulcrum.log
  ```

## Notes

- Performance: Optimized for 16+ cores, 32 GB RAM. Adjust cache, db-max-mem, and db-num-shards for your hardware.
- Security: Uses # for comments in fulcrum.conf (e.g., # High-capacity client limit).

## Contributing
Submit issues or pull requests for improvements.
