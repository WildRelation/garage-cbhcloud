# Deploying Garage on cbhcloud

[Garage](https://garagehq.deuxfleurs.fr/) is an open-source S3-compatible object storage system. It replaces MinIO as the data storage backend for DuckLake on cbhcloud.

## Architecture

```
DuckLake = PostgreSQL (catalog) + Garage (parquet files)
```

Garage stores the actual `.parquet` data files. DuckDB connects to it using the S3 protocol, exactly like it did with MinIO.

---

## Why two phases?

Garage requires a `garage.toml` configuration file inside the container. cbhcloud does not support mounting external config files directly, so the deployment starts, we create the config via SSH, and then restart.

```
Phase 1: Deploy → container fails (no config yet) — expected
Phase 2: SSH in → create config → restart → initialize Garage
```

---

## Phase 1 — Create the deployment on cbhcloud

Fill in the form as follows:

### Name
```
ducklake-garage
```
This will also be the subdomain: `ducklake-garage.app.cloud.cbh.kth.se`

### Image
```
dxflrs/garage
```

### Image start arguments
```
server -c /data/garage.toml
```
Tells Garage to start the S3 server using the config file we will create in Phase 2.

### Visibility
Set to **Public** — DuckDB needs to reach Garage from outside cbhcloud to read and write parquet files.

### Environment variables

| Variable | Value | Why |
|---|---|---|
| `PORT` | `3900` | cbhcloud routes external traffic to this port. Garage's S3 API listens on 3900. |
| `GARAGE_RPC_SECRET` | *(see below)* | Required by Garage for internal cluster communication, even on a single node. |

Generate the RPC secret by running this in your terminal:
```bash
openssl rand -hex 32
```
Copy the output and paste it as the value of `GARAGE_RPC_SECRET`.

### Persistent storage

| Name | App path |
|---|---|
| `garage-data` | `/data` |

This stores both the Garage config, metadata, and data files. Without this, everything is lost on restart.

### Specs
The defaults (0.2 CPU, 0.5 GB RAM) are sufficient for a single-node lab deployment.

Click **Create**. The container will start and immediately fail — this is expected because `garage.toml` does not exist yet.

---

## Phase 2 — Configure Garage via SSH

### Step 1 — SSH into the deployment

```bash
ssh ducklake-garage@deploy.cloud.cbh.kth.se
```

### Step 2 — Create the directories

```bash
mkdir -p /data/meta /data/data
```

### Step 3 — Create the config file

Create `/data/garage.toml` with this content, replacing `YOUR_RPC_SECRET` with the same value you used in the environment variables:

```bash
cat > /data/garage.toml << 'EOF'
metadata_dir = "/data/meta"
data_dir = "/data/data"
db_engine = "sqlite"
replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "YOUR_RPC_SECRET"

[s3_api]
api_bind_addr = "[::]:3900"
s3_region = "garage"

[admin]
api_bind_addr = "[::]:3903"
EOF
```

### Step 4 — Exit SSH and restart the deployment

Exit the SSH session and click **Restart** in the cbhcloud panel. The container should now start successfully and show logs like:

```
Garage storage server is ready to accept requests
```

---

## Phase 3 — Initialize Garage

Garage requires a one-time layout initialization before it can store data. Do this via SSH.

### Step 1 — SSH back in

```bash
ssh ducklake-garage@deploy.cloud.cbh.kth.se
```

### Step 2 — Get the node ID

```bash
garage -c /data/garage.toml node id
```

Copy the long hex string that appears (the node ID).

### Step 3 — Assign layout

Replace `<node-id>` with the hex string from the previous step:

```bash
garage -c /data/garage.toml layout assign -z dc1 -c 1G <node-id>
garage -c /data/garage.toml layout apply --version 1
```

### Step 4 — Create a bucket

```bash
garage -c /data/garage.toml bucket create ducklake
```

### Step 5 — Create an access key

```bash
garage -c /data/garage.toml key create ducklake-key
```

This prints a **Key ID** (starts with `GK`) and a **Secret key**. Save both — you will need them to connect from DuckDB.

### Step 6 — Grant the key access to the bucket

```bash
garage -c /data/garage.toml bucket allow --read --write --owner ducklake --key ducklake-key
```

---

## Connecting DuckDB to Garage

Use these values in your DuckDB S3 secret (replace with your actual Key ID and Secret key from Phase 3):

```python
con.execute("""
CREATE OR REPLACE SECRET garage_secret (
    TYPE s3,
    KEY_ID 'GKxxxxxxxxxxxx',
    SECRET 'your-secret-key',
    ENDPOINT 'ducklake-garage.app.cloud.cbh.kth.se',
    REGION 'garage',
    URL_STYLE 'path',
    USE_SSL true
);
""")

con.execute("""
ATTACH 'ducklake:postgres:host=localhost dbname=ducklake user=duck password=123456 port=5432'
AS my_lake (DATA_PATH 's3://ducklake/');
""")
```

> Note: `REGION 'garage'` is required — it must match the `s3_region` value in `garage.toml`.

---

## Key differences from MinIO

| | MinIO | Garage |
|---|---|---|
| S3 API port | `9000` | `3900` |
| Region | configurable | `garage` |
| Credentials | root user/password | generated key pair (`GK...`) |
| Web console | yes (port 9001) | no |
| Bucket creation | S3 API or Python | CLI: `garage bucket create` |
| Access keys | single root credential | per-key with per-bucket permissions |
| Config | env vars | `garage.toml` file |
