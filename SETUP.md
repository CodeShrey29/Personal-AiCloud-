# Cloudai — Complete Setup Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   Render.com                         │
│  ┌──────────────────────────────────────────────┐   │
│  │          Docker Container                     │   │
│  │  ┌──────────┐ ┌────────────┐ ┌────────────┐ │   │
│  │  │seaf-server│ │ fileserver │ │  seahub     │ │   │
│  │  │ (C daemon)│ │   (Go)    │ │ (Django/    │ │   │
│  │  │ port:intl │ │ port:8082 │ │  Gunicorn)  │ │   │
│  │  └──────────┘ └────────────┘ │ port:$PORT  │ │   │
│  │                               └──────────────┘   │
│  │  Persistent Disk: /data (10GB)                │   │
│  └──────────────────────────────────────────────┘   │
│                        │                             │
└────────────────────────│─────────────────────────────┘
                         │
              ┌──────────▼──────────┐
              │   MySQL Database     │
              │  (Aiven free tier)   │
              │  - ccnet_db          │
              │  - seafile_db        │
              │  - seahub_db         │
              └──────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    ┌────▼────┐    ┌─────▼─────┐   ┌─────▼─────┐
    │ Browser │    │ Android   │   │  Desktop   │
    │ (Web UI)│    │ App       │   │  Client    │
    └─────────┘    └───────────┘   └───────────┘
```

---

## Step 1: Get a Free MySQL Database

Seafile requires MySQL. Render.com only offers PostgreSQL, so use a free external MySQL.

### Option A: Aiven.io (Recommended)

1. Go to **https://aiven.io** → Sign up (free)
2. Click **Create Service** → **MySQL**
3. Select **Free Plan** (Hobbyist)
4. Choose region closest to your Render region
5. Click **Create Service**
6. Wait for it to become **Running** (1-2 min)
7. From the service dashboard, copy:
   - **Host**: e.g., `mysql-xxxxxxx.aiven.io`
   - **Port**: e.g., `12345`
   - **User**: `avnadmin`
   - **Password**: (shown/copy it)
8. **Create 3 databases** — Click "Databases" tab or connect via MySQL client:
   ```
   mysql -h <HOST> -P <PORT> -u avnadmin -p --ssl-mode=REQUIRED
   ```
   Then run:
   ```sql
   CREATE DATABASE ccnet_db CHARACTER SET utf8mb4;
   CREATE DATABASE seafile_db CHARACTER SET utf8mb4;
   CREATE DATABASE seahub_db CHARACTER SET utf8mb4;
   ```

### Option B: TiDB Cloud

1. Go to **https://tidb.cloud** → Sign up
2. Create a **Serverless** cluster (free)
3. Note the host, port, user, password
4. Create the 3 databases as above

---

## Step 2: Push Code to GitHub

Open a terminal in the project folder:

```bash
cd "d:\Shrey\Cloud storage"

# Make sure everything is committed
git add -A
git commit -m "Cloudai - Render.com deployment"
git push origin main
```

Your repo should have this structure:
```
Cloud storage/
├── Intelligent-cloud/           # Sync client daemon (not used in deploy)
├── Intelligent-cloud-android-app/ # Android app (build separately)
├── Intelligent-cloud-core/      # Server core (C + Go) ← compiled in Docker
├── Intelligent-cloud-web-end/   # Web UI (Django) ← runs as seahub
├── Intelligent-cloud-webdav/    # WebDAV (optional)
├── Dockerfile                   # Docker build instructions
├── docker-entrypoint.sh         # Startup script
├── render.yaml                  # Render.com deployment config
└── .dockerignore
```

---

## Step 3: Deploy on Render.com

### 3a. Create the service

1. Go to **https://render.com** → Sign in
2. Click **New** → **Blueprint**
3. Connect your GitHub repo (`personal-aicloud-`)
4. Render reads `render.yaml` and shows the service config
5. Click **Apply**

### 3b. Set environment variables

Render will prompt you for the env vars marked `sync: false`. Fill them in:

| Variable | Value | Example |
|---|---|---|
| `DB_HOST` | Your MySQL host | `mysql-xxxx.aiven.io` |
| `DB_USER` | Your MySQL user | `avnadmin` |
| `DB_PASS` | Your MySQL password | `your-password-here` |
| `SEAFILE_ADMIN_EMAIL` | Your admin login email | `admin@example.com` |
| `SEAFILE_ADMIN_PASSWORD` | Your admin password (min 8 chars) | `MySecurePass123!` |

The following are set automatically:
- `DB_PORT` = `3306` (change if your MySQL uses different port)
- `DB_NAME_CCNET` = `ccnet_db`
- `DB_NAME_SEAFILE` = `seafile_db`
- `DB_NAME_SEAHUB` = `seahub_db`
- `RENDER_EXTERNAL_HOSTNAME` = auto-detected

### 3c. Deploy

1. Click **Create Resources**
2. Render will:
   - Build the Docker image (~10-15 min first time, compiling C/Go code)
   - Create the persistent disk
   - Start the container
3. Once **Live**, your URL will be: `https://cloudai.onrender.com`

### 3d. First login

1. Go to your Render URL
2. Login with `SEAFILE_ADMIN_EMAIL` and `SEAFILE_ADMIN_PASSWORD`
3. You'll see the Seafile web interface — upload files, create libraries, etc.

---

## Step 4: Connect Android App

### Build the Android app

1. Open `Intelligent-cloud-android-app/` in **Android Studio**
2. Wait for Gradle sync
3. In the app settings/config, set the server URL to your Render URL:
   ```
   https://cloudai.onrender.com
   ```
4. Build → Run on your phone or generate APK:
   - **Build** → **Build Bundle(s) / APK(s)** → **Build APK(s)**
   - APK will be at: `app/build/outputs/apk/debug/app-debug.apk`

### Use the Android app

1. Install the APK on your phone
2. Open the app
3. Enter server: `https://cloudai.onrender.com`
4. Login with your admin email/password
5. You can now upload/download/sync files from your phone

---

## Step 5: Connect Desktop Client (Optional)

1. Download Seafile desktop client from https://www.seafile.com/en/download/
2. Add account → Server: `https://cloudai.onrender.com`
3. Login with your admin credentials
4. Sync libraries to your desktop

---

## Troubleshooting

### Build fails on Render

Check the deploy logs in Render dashboard. Common issues:
- **libsearpc not found**: The Dockerfile clones it from GitHub; check network
- **MySQL connection refused**: Verify your DB_HOST, DB_USER, DB_PASS are correct
- **Out of memory during build**: Upgrade to a higher Render plan for build

### Can't login after deploy

- Make sure `SEAFILE_ADMIN_EMAIL` and `SEAFILE_ADMIN_PASSWORD` are set
- Check logs: Render Dashboard → your service → **Logs**
- If admin wasn't created, you can shell into the container:
  ```
  # In Render Shell tab:
  cd /opt/seahub
  python3 manage.py createsuperuser
  ```

### Slow cold starts

Render free/starter tier spins down after 15 min of inactivity.
First request after sleep takes ~30 seconds. To avoid this:
- Upgrade to Standard plan ($25/mo), OR
- Use a free uptime monitor (UptimeRobot) to ping your URL every 14 min

### MySQL SSL errors

If using Aiven, add to `DB_HOST`:
```
SEAFILE_MYSQL_DB_HOST=mysql-xxxx.aiven.io
```
The connection uses SSL by default. If you get SSL errors, you may need to
set `use_ssl = true` in the seafile.conf (the entrypoint handles this).

---

## Costs

| Component | Cost |
|---|---|
| Render.com Starter (web + disk) | $7/month |
| Aiven MySQL (free tier) | Free |
| **Total** | **$7/month** |

### Free alternative
Use Render free tier (no persistent disk) — files are lost on redeploy.
Good for testing only.

---

## Updating

When you push new code to GitHub:
1. Render auto-deploys (if auto-deploy is enabled)
2. Or manually: Render Dashboard → **Manual Deploy** → **Deploy latest commit**

The persistent disk at `/data` survives redeployments — your files are safe.
