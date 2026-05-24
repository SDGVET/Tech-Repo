# Nextcloud Tasks MCP Server

An MCP (Model Context Protocol) server that lets Claude Code manage Nextcloud tasks via CalDAV/VTODO.

## Requirements

- Python 3.10+
- A Nextcloud instance with Tasks enabled

## Setup

### 1. Create and activate a virtual environment

```bash
cd nextcloud-tasks-mcp
python3 -m venv .venv
source .venv/bin/activate
```

### 2. Install dependencies

```bash
pip install -r requirements.txt
```

> If a pinned version is unavailable, check [PyPI](https://pypi.org) for the latest compatible release and update `requirements.txt` accordingly.

### 3. Create your `.env` file

Copy the example and fill in your credentials:

```bash
cp .env.example .env
```

Edit `.env`:

```
NEXTCLOUD_URL=https://your-nextcloud-server.com
NEXTCLOUD_USERNAME=your_username
NEXTCLOUD_PASSWORD=your_password
```

The CalDAV endpoint is constructed automatically as `{NEXTCLOUD_URL}/remote.php/dav`.

**The `.env` file is listed in `.gitignore` and will never be committed to version control.**

---

## Registering with Claude Code (VS Code on Linux)

Claude Code reads MCP server configuration from `~/.claude.json`. Add the following entry under `"mcpServers"`:

```json
{
  "mcpServers": {
    "nextcloud-tasks": {
      "command": "/absolute/path/to/nextcloud-tasks-mcp/.venv/bin/python",
      "args": ["/absolute/path/to/nextcloud-tasks-mcp/server.py"]
    }
  }
}
```

Replace both paths with the actual absolute paths on your machine. Using the `.venv` Python ensures the correct dependencies are available without affecting your system Python.

**Example** (adjust for your actual home directory):

```json
{
  "mcpServers": {
    "nextcloud-tasks": {
      "command": "/home/dl/Documents/SynFolder/LWVC/Tech protocols/nextcloud-tasks-mcp/.venv/bin/python",
      "args": ["/home/dl/Documents/SynFolder/LWVC/Tech protocols/nextcloud-tasks-mcp/server.py"]
    }
  }
}
```

After saving `~/.claude.json`, restart VS Code (or reload the Claude Code extension) for the new server to appear.

---

## Available Tools

| Tool | Description |
|------|-------------|
| `list_task_lists` | List all VTODO-capable task lists with their CalDAV URLs |
| `list_tasks` | List all tasks in a task list (including completed) |
| `create_task` | Create a task with optional due date, priority (1–9), and notes |
| `create_subtask` | Create a task linked to a parent via `RELATED-TO` |
| `update_task` | Update title, status, priority, or due date on an existing task |
| `complete_task` | Mark a task as `COMPLETED` with a timestamp |
| `delete_task` | Permanently delete a task |

### Status values for `update_task`

- `NEEDS-ACTION` — not started (default)
- `IN-PROCESS` — in progress
- `COMPLETED` — done
- `CANCELLED` — cancelled

### Priority values

1 = highest priority, 5 = medium, 9 = lowest. Nextcloud Tasks maps 1–4 as high, 5 as medium, 6–9 as low.

---

## Typical workflow

```
1. list_task_lists               → get the calendar_url for your task list
2. list_tasks(calendar_url)      → see existing tasks and their UIDs/URLs
3. create_task(calendar_url, …)  → add a new task
4. create_subtask(calendar_url, title, parent_uid) → add a subtask
5. complete_task(task_url)       → mark done
6. delete_task(task_url)         → remove if needed
```
