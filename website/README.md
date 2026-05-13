# Jot Website – Deployment Guide

## Overview
This folder contains the static website for the **Jot** app built with **Vite** (HTML, CSS, TypeScript). The site includes a custom Chart.js pie‑chart with a bespoke legend.

---

## 1️⃣ Prerequisites
- **Node.js** (v18 or later) and **npm** installed.
- **Git** configured with your GitHub (or other) credentials.
- An existing **GitHub repository** (e.g., `https://github.com/TScadden/jot-app`). The `website/` folder should be part of that repository.
- **AWS account** with access to **AWS Amplify**.

---

## 2️⃣ Local development
```bash
# From the project root
cd website

# Install dependencies
npm ci

# Run a development server
npm run dev
```
Open `http://localhost:5173` to preview.

---

## 3️⃣ Build for production
```bash
npm run build   # outputs to website/dist
```
The `dist/` directory contains the static files that Amplify will serve.

---

## 4️⃣ Git workflow (push website changes)
1. **Stage & commit**
   ```bash
   git add website/
   git commit -m "Your commit message"
   ```
   *If there are no changes, Git will report “nothing to commit”.*
2. **Push to the remote**
   ```bash
   git push origin main   # replace ‘main’ with your branch name if different
   ```
   *Do **not** include comments after the command – the previous failure was caused by stray text after the push command.*

If the remote repository does not yet contain the `website/` folder, you can create a new repo on GitHub, add it as a remote, and push:
```bash
# Create a new repo on GitHub (e.g., jot-website) – copy the HTTPS URL
git remote add origin https://github.com/your‑username/jot-website.git
git branch -M main   # ensure you are on ‘main’
git push -u origin main
```

---

## 5️⃣ Deploy to AWS Amplify (Console method)
1. Log in to the **AWS Amplify** console.
2. Click **“Get started → Host web app”.**
3. **Connect repository** – select GitHub (or other) and authorize Amplify.
4. Choose the repository and branch that contains the website.
5. **Build settings**:
   - **Base directory**: `website`
   - **Build command**: `npm ci && npm run build`
   - **Publish directory**: `website/dist`
6. Save & Deploy. Amplify will run the build and provide a preview URL.

---

## 6️⃣ Deploy to AWS Amplify (CLI method) – optional
```bash
# Install Amplify CLI (if not installed)
npm install -g @aws-amplify/cli

# Configure the CLI (runs once)
amplify configure

# Initialise Amplify in the repo root
cd /Users/Tysonn/AndroidStudioProjects/Notel
amplify init   # choose JavaScript, no framework
amplify add hosting
#   ► Select “Continuous deployment (Git)”.
#   ► Choose your Git provider, repository, and branch.
#   ► Set Base directory = website, Publish directory = website/dist
amplify push   # creates the Amplify app and starts the first build
```

---

## 7️⃣ Custom domain (optional)
In the Amplify console go to **Domain management → Add domain**, enter your domain (e.g., `jotapp.com`), and follow the DNS validation steps. Amplify automatically provisions HTTPS.

---

## 8️⃣ What you need to do now
- Verify that the `website/` folder is committed and pushed to your remote repository (step 4).
- Follow the **Console** or **CLI** instructions above to create the Amplify app.
- Once the first build finishes, visit the provided Amplify URL to confirm the site (pie chart, legend, etc.) renders correctly.

If any step fails (e.g., build errors, missing dependencies), copy the error message and let me know – I can help troubleshoot.

---

*Happy deploying!*
