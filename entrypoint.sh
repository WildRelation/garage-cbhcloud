#!/bin/sh
set -e

CONFIG_FILE="/data/garage.toml"

# Create config from env vars on first run
if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p /data/meta /data/data
    cat > "$CONFIG_FILE" << EOF
metadata_dir = "/data/meta"
data_dir = "/data/data"
db_engine = "sqlite"
replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
api_bind_addr = "[::]:3900"
s3_region = "garage"

[admin]
api_bind_addr = "[::]:3903"
EOF
    echo "Config created at $CONFIG_FILE"
fi

exec garage -c "$CONFIG_FILE" "$@"
