# Deploying Garage on cbhcloud

[Garage](https://garagehq.deuxfleurs.fr/) is an open-source S3-compatible object storage system. It replaces MinIO as the data storage backend for DuckLake on cbhcloud.

## Architecture

```
DuckLake = PostgreSQL (catalog) + Garage (parquet files)
```

Garage stores the actual `.parquet` data files. DuckDB connects to it using the S3 protocol, exactly like it did with MinIO.

---

## Why a custom Docker image?

The official `dxflrs/garage` image is scratch-based — it contains only the Garage binary with no shell. cbhcloud's SSH feature runs a shell inside the container, which immediately closes because there is no shell to run.

The solution is a multi-stage build: copy the Garage binary from the official image into an Alpine Linux base that includes a shell. The `garage.toml` config is baked into the image at `/etc/garage.toml` (Garage's default config path). `GARAGE_RPC_SECRET` is read directly from the environment variable — it does not need to appear in the config file.

The image is built from the `Dockerfile`, `entrypoint.sh`, and `garage.toml` in this repo and pushed to GitHub Container Registry.

---

## Problems encountered and solutions

### 1. Official image has no shell → SSH closes immediately
**Problem:** `dxflrs/garage` is a scratch image. Running `ssh ducklake-garage@deploy.cloud.cbh.kth.se` immediately closes the connection.
**Solution:** Multi-stage build — copy the Garage binary from `dxflrs/garage:v2.1.0` into an Alpine base that includes a shell.

### 2. ghcr.io image is private by default
**Problem:** After pushing to GitHub Container Registry, cbhcloud could not pull the image because packages are private by default.
**Solution:** Go to `github.com/<user>?tab=packages` → select the package → Package settings → Change visibility to **Public**.

### 4. SSH tunnel access only works for the deployment owner

**Problem:** Sharing the deployment via "Share with team" gives the team member dashboard visibility but not SSH tunnel access. Running the tunnel gives:
```
channel 2: open failed: connect failed: user cannot access pod <deployment-name>
```
**Solution:** The team member must create a **new** SSH key that is not registered on their own cbhcloud profile, and the owner adds that key to their own profile. The team member then uses `-i` to specify that key:

**Linux / macOS:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_shared
ssh -i ~/.ssh/id_ed25519_shared -L <port>:localhost:<port> <deployment>@deploy.cloud.cbh.kth.se -N
```

**Windows (PowerShell):**
```powershell
ssh-keygen -t ed25519 -f "C:\Users\<username>\.ssh\id_ed25519_shared"
ssh -i "C:\Users\<username>\.ssh\id_ed25519_shared" -L <port>:localhost:<port> <deployment>@deploy.cloud.cbh.kth.se -N
```

> See [ducklake-guide](https://github.com/WildRelation/ducklake-guide) for detailed step-by-step instructions.

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
garage node id
```

Copy the long hex string.

### Step 3 — Assign layout

```bash
garage layout assign -z dc1 -c 1G <node-id>
garage layout apply --version 1
```

### Step 4 — Create a bucket

```bash
garage bucket create ducklake
```

### Step 5 — Create an access key

```bash
garage key create ducklake-key
```

Save the **Key ID** (`GK...`) and **Secret key** that appear.

### Step 6 — Grant permissions

```bash
garage bucket allow --read --write --owner ducklake --key ducklake-key
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
