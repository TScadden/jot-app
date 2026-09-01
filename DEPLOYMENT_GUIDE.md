# Deployment Guide: Pushing Changes to AWS Lightsail Server

This document outlines the standard workflow for committing, pushing, and deploying updates to the live AWS Lightsail server (`jot-production-server`).

---

## Architecture Overview

1. **`jot-app` Repository (`https://github.com/TScadden/jot-app.git`)**
   - Contains the full monorepo (Android application, server, and website).
   - Main codebase for development.

2. **`jot-server` Repository (`https://github.com/TScadden/jot-server.git`)**
   - Contains the backend Express API and database routes.
   - Deployed on AWS Lightsail instance at `~/jot-server`.

---

## Step 1: Local Commit & Push

Before deploying, commit and push changes from your local workspace.

### Push Monorepo (`jot-app`)
```bash
git add .
git commit -m "Describe your changes"
git push origin main
```

### Push Backend API (`jot-server`)
If you edited backend server code inside `jot-server/`, push to the server repository as well:
```bash
cd jot-server
git add .
git commit -m "Backend server updates"
git push origin main
```

---

## Step 2: Deploy to AWS Lightsail

1. Open the **AWS Lightsail Console** and connect to your instance terminal (`jot-production-server`).
2. Run the deployment commands:

```bash
# Navigate to the backend server directory
cd ~/jot-server

# Pull the latest changes from GitHub
git pull origin main

# If you installed new npm packages:
npm install

# Restart the live server with PM2
pm2 restart jot-server
```

---

## Step 3: Verify Deployment

Check that the server process is online and running without errors:

```bash
# View active PM2 processes
pm2 status

# View live server logs
pm2 logs jot-server --lines 50
```

---

## Troubleshooting

- **Server fails to start?**
  Run `pm2 logs jot-server` to inspect error stack traces.
- **Port already in use?**
  Run `pm2 restart jot-server` to perform a clean process restart.
