# Voice Task API

Add tasks to your Nextcloud while driving using Tasker and Google Assistant — completely hands-free.

This is a companion to the [`nextcloud-tasks-mcp`](../nextcloud-tasks-mcp) server. That one connects Claude Code on your desktop. This one exposes a simple HTTP endpoint so your phone can add tasks by voice while you're in the car.

---

## How it works

1. You say "Hey Google, add a task" (or tap a widget on your car mount).
2. Tasker asks "What's the task?" — you say it.
3. Tasker POSTs the task title to this API running on your Unraid server.
4. The API adds it to Nextcloud via CalDAV.
5. Your phone reads back "Added 'Buy hay' to Tasks" so you know it worked.
6. The task shows up in Planify and your phone's Tasks app instantly.

---

## What you need before starting

- Your Unraid server accessible on your local network (or via a domain/VPN if you want to use it away from home Wi-Fi)
- Docker and the Compose Manager plugin installed on Unraid
- Nginx Proxy Manager already running on Unraid (for HTTPS)
- A Nextcloud App Password — **do not use your main password** (see Step 2)
- [Tasker](https://play.google.com/store/apps/details?id=net.dinglisch.android.taskerm) installed on your Android phone (~$3.49 one-time)

---

## Step 1 — Download the files

Clone the Tech-Repo or copy the `voice-task-api` folder to your Unraid server. A good location is somewhere under `/mnt/user/appdata/`, for example:

```
/mnt/user/appdata/voice-task-api/
```

---

## Step 2 — Create a Nextcloud App Password

This gives the API its own credential that you can revoke any time without changing your main password.

1. Log into Nextcloud in a browser.
2. Go to **Settings → Security → Devices & sessions**.
3. At the bottom, type a name like `voice-task-api` and click **Create new app password**.
4. Copy the generated password — you'll need it in the next step. It won't be shown again.

---

## Step 3 — Create your credentials file

In the `voice-task-api` folder on Unraid, copy the example:

```bash
cp .env.example .env
```

Open `.env` and fill in your values:

```
NEXTCLOUD_URL=https://your-nextcloud.example.com
NEXTCLOUD_USERNAME=your_username
NEXTCLOUD_PASSWORD=paste-the-app-password-from-step-2

API_KEY=paste-a-long-random-secret-here

DEFAULT_LIST=Tasks
```

**Generating the API key** — run this on any machine with Python 3:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Copy the output into `API_KEY`. You'll need this same value later in Tasker.

**`DEFAULT_LIST`** — the name of the Nextcloud task list tasks go into when you don't specify one. Use the exact name as it appears in Planify (e.g. `Tasks`, `Home Lab`, `Shopping`).

---

## Step 4 — Check the port

Open `docker-compose.yml`. The line `"8080:8080"` means the container listens on host port 8080. If something else on your Unraid server already uses 8080, change the **left** number to any free port:

```yaml
ports:
  - "9123:8080"   # host port 9123 → container port 8080
```

Note the host port you choose — you'll need it when setting up NPM and Tasker.

---

## Step 5 — Build and start the container

From the `voice-task-api` folder:

```bash
docker compose up -d --build
```

Check that it started cleanly:

```bash
docker logs voice-task-api
```

You should see a line like `Uvicorn running on http://0.0.0.0:8080`. If you see `Missing required environment variables`, re-check your `.env` file.

Test it locally on Unraid:

```bash
curl http://localhost:8080/health
```

Should return `ok`.

---

## Step 6 — Set up HTTPS in Nginx Proxy Manager

In NPM, add a new Proxy Host:

- **Domain name:** the subdomain you want (e.g. `tasks-api.yourdomain.com`)
- **Scheme:** `http`
- **Forward hostname/IP:** your Unraid server's local IP
- **Forward port:** the host port you chose in Step 4
- **SSL:** request a new Let's Encrypt certificate, enable **Force SSL**

Once NPM shows the certificate as active, test from your phone's browser:

```
https://tasks-api.yourdomain.com/health
```

Should return `ok`.

---

## Step 7 — Set up Tasker on your phone

See [`docs/tasker-setup.md`](docs/tasker-setup.md) for the full walkthrough with screenshots.

The short version:

1. Create a new Tasker **Task** called `Add Nextcloud Task`.
2. Add action: **Input → Get Voice** — prompt `"What's the task?"`, store in `%taskTitle`.
3. Add action: **Net → HTTP Request**:
   - Method: `POST`
   - URL: `https://tasks-api.yourdomain.com/add-task`
   - Headers: `Content-Type:application/json` and `X-Api-Key:your-api-key-from-env`
   - Body: `{"title": "%taskTitle"}`
   - Save result to `%httpResult`
4. Add action: **Say** — text `%httpResult` (reads the confirmation aloud).
5. Create a **Google Assistant shortcut** pointing to this task.

---

## Step 8 — Test end to end

Run the Tasker task manually (tap the play button in Tasker). Say a task title when prompted. You should hear the confirmation spoken back, and the task should appear in Planify and your Tasks app within a few seconds.

---

## Troubleshooting

**Container won't start — "Missing required environment variables"**
Open `.env` and make sure all five values are filled in with no blank lines.

**`curl /health` returns connection refused**
The container isn't running or the port doesn't match. Run `docker ps` to confirm the container is up and check the port mapping.

**Tasker HTTP request fails (error 401)**
The `X-Api-Key` header value in Tasker doesn't match `API_KEY` in your `.env`. They must be identical — copy-paste both from the same source.

**Task isn't appearing in Planify**
Check the `DEFAULT_LIST` value in `.env` — it must exactly match the list name in Planify (case-sensitive). You can verify the available list names by running the `nextcloud-tasks-mcp` server and asking Claude to list task lists.

**NPM shows 502 Bad Gateway**
The container isn't reachable at the IP/port NPM is forwarding to. Re-check the host port in `docker-compose.yml` and the Forward Port in NPM.

---

## API reference

### `GET /health`
Returns `ok` if the server is running. No authentication required. Use this to verify NPM routing and connectivity.

### `POST /add-task`
Creates a task in Nextcloud.

**Headers:**
```
Content-Type: application/json
X-Api-Key: your-api-key
```

**Body:**
```json
{
  "title": "Buy hay",
  "list": "Farm",
  "priority": "high"
}
```

- `title` — required. The task name.
- `list` — optional. Task list name. Defaults to `DEFAULT_LIST` if blank or omitted.
- `priority` — optional. `"high"`, `"medium"`, or `"low"`.

**Response** (plain text, suitable for Tasker TTS):
```
Added 'Buy hay' to Farm
```

---

Made with Claude Code for personal use.
