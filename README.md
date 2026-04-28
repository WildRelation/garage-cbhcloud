# Deploying Garage on cbhcloud

[Garage](https://garagehq.deuxfleurs.fr/) is an open-source S3-compatible object storage system. It replaces MinIO as the data storage backend for DuckLake on cbhcloud.

## Architecture

```
DuckLake = PostgreSQL (catalog) + Garage (parquet files)
```

Garage stores the actual `.parquet` data files. DuckDB connects to it using the S3 protocol, exactly like it did with MinIO.

---

## Why a custom Docker image?

The official `dxflrs/garage` image is minimal (scratch-based) — it contains only the Garage binary with no shell. This causes two problems on cbhcloud:

1. **SSH immediately closes** — cbhcloud's SSH feature runs a shell inside the container, but there is no shell to run.
2. **No way to create the config file** — Garage requires a `garage.toml` config file, and without SSH access there is no way to create it.

The solution is a custom image based on Alpine Linux that:
- Includes a shell (so SSH works)
- Includes a startup script (`entrypoint.sh`) that automatically generates `garage.toml` from environment variables on first run

The image is built from the `Dockerfile` and `entrypoint.sh` in this repo and pushed to GitHub Container Registry.

---

## Problems encountered and solutions

### 1. Official image has no shell → SSH closes immediately
**Problem:** `dxflrs/garage` is a scratch image. Running `ssh ducklake-garage@deploy.cloud.cbh.kth.se` immediately closes the connection.
**Solution:** Build a custom Alpine-based image with the Garage binary downloaded manually.

### 2. Wrong download URL for the Garage binary
**Problem:** The documentation references `/download/` but the actual URL path is `/_releases/`.
```
# Wrong
https://garagehq.deuxfleurs.fr/download/v1.0.0/x86_64-unknown-linux-musl/garage

# Correct
https://garagehq.deuxfleurs.fr/_releases/v1.3.1/x86_64-unknown-linux-musl/garage
```
**Solution:** Updated the Dockerfile to use `/_releases/` with version `v1.3.1`.

### 3. ghcr.io image is private by default
**Problem:** After pushing to GitHub Container Registry, cbhcloud could not pull the image because packages are private by default.
**Solution:** Go to `github.com/<user>?tab=packages` → select the package → Package settings → Change visibility to **Public**.

### 4. `-c` flag conflict
**Problem:** The cbhcloud Image start arguments were set to `server -c /data/garage.toml`, but the `entrypoint.sh` already adds `-c /data/garage.toml`. The resulting command was:
```
garage -c /data/garage.toml server -c /data/garage.toml
```
`garage server` does not accept `-c`, so it failed with `Found argument '-c' which wasn't expected`.
**Solution:** Change Image start arguments to just `server`. The entrypoint handles `-c` automatically.

---

## Building and pushing the custom image

You need Docker installed and a GitHub Personal Access Token with `write:packages` scope.

```bash
# Login to GitHub Container Registry
echo "your_github_token" | docker login ghcr.io -u <your-github-username> --password-stdin

# Build the image
docker build -t ghcr.io/<your-github-username>/garage-cbhcloud:latest .

# Push
docker push ghcr.io/<your-github-username>/garage-cbhcloud:latest
```

Then make the package public on GitHub:
- Go to `github.com/<your-github-username>?tab=packages`
- Select `garage-cbhcloud`
- **Package settings → Change visibility → Public**

---

## Phase 1 — Create the deployment on cbhcloud

### Name
```
ducklake-garage
```

### Image
```
ghcr.io/<your-github-username>/garage-cbhcloud:latest
```

### Image start arguments
```
server
```
The entrypoint script handles `-c /data/garage.toml` automatically.

### Visibility
**Public** — DuckDB needs to reach Garage from outside cbhcloud.

### Environment variables

| Variable | Value | Why |
|---|---|---|
| `PORT` | `3900` | cbhcloud routes external traffic to this port. Garage's S3 API listens on 3900. |
| `GARAGE_RPC_SECRET` | *(generated)* | Required by Garage even on a single node. |

Generate the RPC secret:
```bash
openssl rand -hex 32
```

### Persistent storage

| Name | App path |
|---|---|
| `garage-data` | `/data` |

### Specs
Defaults (0.2 CPU, 0.5 GB RAM) are sufficient for a lab deployment.

---

## Phase 2 — Initialize Garage (one-time)

After the container starts successfully, SSH in to initialize the cluster layout, create a bucket, and generate access keys.

### Step 1 — SSH in

```bash
ssh <deployment-name>@deploy.cloud.cbh.kth.se
```

### Step 2 — Get the node ID

```bash
garage -c /data/garage.toml node id
```

Copy the long hex string.

### Step 3 — Assign layout

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

Save the **Key ID** (`GK...`) and **Secret key** that appear.

### Step 6 — Grant permissions

```bash
garage -c /data/garage.toml bucket allow --read --write --owner ducklake --key ducklake-key
```

---

## Connecting DuckDB to Garage

```python
con.execute("""
CREATE OR REPLACE SECRET garage_secret (
    TYPE s3,
    KEY_ID 'GKxxxxxxxxxxxx',
    SECRET 'your-secret-key',
    ENDPOINT '<deployment-name>.app.cloud.cbh.kth.se',
    REGION 'garage',
    URL_STYLE 'path',
    USE_SSL true
);
""")

con.execute("""
ATTACH 'ducklake:postgres:host=localhost dbname=<your-db> user=<your-user> password=<your-password> port=5432'
AS my_lake (DATA_PATH 's3://ducklake/');
""")
```

> `REGION 'garage'` must match the `s3_region` in `garage.toml`.

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
| Config | env vars only | `garage.toml` file required |
| Docker image | has shell | scratch image — needs custom wrapper |
