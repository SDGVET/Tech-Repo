# Nextcloud Tasks MCP Server

This tool lets **Claude Code** (the AI assistant in VS Code) read and manage your Nextcloud tasks by talking directly to your Nextcloud server. Once set up, you can say things like *"add a high-priority task to my Home Lab list"* or *"mark the parking sign task as complete"* and Claude will do it.

---

## What you need before starting

- A Nextcloud account with the **Tasks** app enabled (check your Nextcloud app store if you're not sure)
- [VS Code](https://code.visualstudio.com/) with the **Claude Code extension** installed
- Python 3.10 or newer — check by opening a terminal and running `python3 --version`

---

## Step 1 — Download the files

Clone or download this repository, then open a terminal and navigate into the project folder:

```bash
cd nextcloud-tasks-mcp
```

If you're not sure how to get here, right-click the `nextcloud-tasks-mcp` folder in your file manager and look for "Open Terminal Here."

---

## Step 2 — Create a virtual environment

A virtual environment keeps the Python packages for this project separate from everything else on your computer. Run these two commands one at a time:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Your terminal prompt should now start with `(.venv)` — that means it worked.

> **Windows note:** Use `.venv\Scripts\activate` instead of the `source` command above.

---

## Step 3 — Install dependencies

```bash
pip install -r requirements.txt
```

This downloads everything the server needs. It may take a minute. You should see a line at the end that says `Successfully installed ...`.

---

## Step 4 — Create your credentials file

Copy the example file:

```bash
cp .env.example .env
```

Now open the new `.env` file in any text editor and fill in your details:

```
NEXTCLOUD_URL=https://your-nextcloud-server.com
NEXTCLOUD_USERNAME=your_username
NEXTCLOUD_PASSWORD=your_password
```

**Where to find these values:**
- `NEXTCLOUD_URL` — the address you use to log into Nextcloud in a browser, e.g. `https://cloud.example.com`. No trailing slash, no `/remote.php/...` — just the base address.
- `NEXTCLOUD_USERNAME` — your Nextcloud login username (not your email).
- `NEXTCLOUD_PASSWORD` — your Nextcloud password. If you use two-factor authentication (2FA), you'll need to create a dedicated **App Password** instead: go to Nextcloud → Settings → Security → Devices & sessions → Create new app password.

> **Security:** The `.env` file contains your password and is listed in `.gitignore`. It will never be accidentally committed to Git or uploaded to GitHub.

---

## Step 5 — Find the full path to this folder

You need the absolute path (the full address from the root of your filesystem) to tell Claude Code where the server lives. Run this:

```bash
pwd
```

It will print something like `/home/yourname/nextcloud-tasks-mcp`. Copy that output — you'll need it in the next step.

---

## Step 6 — Register the server with Claude Code

Claude Code reads its MCP server list from a file called `~/.claude.json` in your home directory. Open it in a text editor (create it if it doesn't exist) and add this inside the `"mcpServers"` section:

```json
"nextcloud-tasks": {
  "command": "/home/yourname/nextcloud-tasks-mcp/.venv/bin/python",
  "args": ["/home/yourname/nextcloud-tasks-mcp/server.py"]
}
```

Replace `/home/yourname/nextcloud-tasks-mcp` with the path you copied in Step 5.

**Full example of what `~/.claude.json` should look like** (if it was previously empty):

```json
{
  "mcpServers": {
    "nextcloud-tasks": {
      "command": "/home/yourname/nextcloud-tasks-mcp/.venv/bin/python",
      "args": ["/home/yourname/nextcloud-tasks-mcp/server.py"]
    }
  }
}
```

If `~/.claude.json` already has other servers in it, just add the `"nextcloud-tasks"` block alongside them — don't replace the whole file.

---

## Step 7 — Reload VS Code

Press **F1**, type `Developer: Reload Window`, and press Enter. This restarts Claude Code and loads the new server.

---

## Step 8 — Test it

In the Claude Code chat, type:

> *List my Nextcloud task lists*

Claude should respond with a list of your Nextcloud calendars. If it does, everything is working. Try:

> *List tasks in [name of a calendar]*

---

## Troubleshooting

**"No calendars found" or connection error**
- Double-check `NEXTCLOUD_URL` in your `.env` — no trailing slash, no `/remote.php/dav`
- Make sure your username and password are correct by logging into Nextcloud in a browser
- If you use 2FA, use an App Password (see Step 4)

**"command not found" or server won't start**
- Make sure the path in `~/.claude.json` points to `.venv/bin/python` inside your project folder, not the system Python
- Re-run `pip install -r requirements.txt` with the venv active to make sure packages are installed

**Server loaded but returns errors**
- Check that the Nextcloud **Tasks** app is installed and enabled in your Nextcloud instance

---

## What Claude can do once connected

| Say something like... | What happens |
|-----------------------|--------------|
| *"List my task lists"* | Shows all your Nextcloud calendars |
| *"List tasks in Home Lab"* | Shows all tasks in that calendar |
| *"Add a task called Buy servers to Home Lab"* | Creates the task |
| *"Add a subtask under that"* | Creates a nested subtask |
| *"Mark the Buy servers task as complete"* | Marks it done |
| *"Set the priority to high"* | Updates priority to 1 |
| *"Delete the test task"* | Removes it permanently |

### Priority levels
1–4 = High, 5 = Medium, 6–9 = Low (matches how Nextcloud Tasks displays them)

### Task status options
`NEEDS-ACTION` (not started) · `IN-PROCESS` · `COMPLETED` · `CANCELLED`


This Was made with the help of Claude Code, this was made for personal use and works well for me, if you find this and can't get it to work for some reason, I'm sorry! 