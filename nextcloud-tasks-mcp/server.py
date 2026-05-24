#!/usr/bin/env python3
"""MCP server for managing Nextcloud tasks via CalDAV/VTODO."""

import os
import uuid
from datetime import datetime, date, timezone
from pathlib import Path
from typing import Optional

import caldav
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

load_dotenv(dotenv_path=Path(__file__).parent / ".env")

NEXTCLOUD_URL = os.getenv("NEXTCLOUD_URL", "").rstrip("/")
NEXTCLOUD_USERNAME = os.getenv("NEXTCLOUD_USERNAME", "")
NEXTCLOUD_PASSWORD = os.getenv("NEXTCLOUD_PASSWORD", "")
CALDAV_URL = f"{NEXTCLOUD_URL}/remote.php/dav"
mcp = FastMCP("nextcloud-tasks")


def _get_client() -> caldav.DAVClient:
    return caldav.DAVClient(
        url=CALDAV_URL,
        username=NEXTCLOUD_USERNAME,
        password=NEXTCLOUD_PASSWORD,
    )


def _format_date(dt) -> str:
    if dt is None:
        return "None"
    if hasattr(dt, "dt"):
        dt = dt.dt
    if isinstance(dt, datetime):
        return dt.date().isoformat()
    if isinstance(dt, date):
        return dt.isoformat()
    return str(dt)


def _parse_todo(todo) -> dict:
    vtodo = todo.vobject_instance.vtodo
    return {
        "uid": str(vtodo.uid.value) if hasattr(vtodo, "uid") else "",
        "summary": str(vtodo.summary.value) if hasattr(vtodo, "summary") else "(no title)",
        "status": str(vtodo.status.value) if hasattr(vtodo, "status") else "NEEDS-ACTION",
        "priority": str(vtodo.priority.value) if hasattr(vtodo, "priority") else "",
        "due": _format_date(vtodo.due) if hasattr(vtodo, "due") else "None",
        "url": str(todo.url),
    }


def _build_vtodo_ical(
    summary: str,
    uid: str,
    due_date: Optional[str] = None,
    priority: Optional[int] = None,
    notes: Optional[str] = None,
    status: str = "NEEDS-ACTION",
    related_to: Optional[str] = None,
) -> str:
    now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//nextcloud-tasks-mcp//EN",
        "BEGIN:VTODO",
        f"UID:{uid}",
        f"DTSTAMP:{now}",
        f"SUMMARY:{summary}",
        f"STATUS:{status}",
    ]
    if priority is not None:
        lines.append(f"PRIORITY:{priority}")
    if notes:
        lines.append(f"DESCRIPTION:{notes}")
    if due_date:
        dt = datetime.strptime(due_date, "%Y-%m-%d").date()
        lines.append(f"DUE;VALUE=DATE:{dt.strftime('%Y%m%d')}")
    if related_to:
        lines.append(f"RELATED-TO;RELTYPE=PARENT:{related_to}")
    lines += ["END:VTODO", "END:VCALENDAR"]
    return "\r\n".join(lines)


@mcp.tool()
def list_task_lists() -> str:
    """
    List all task lists (calendars that support VTODO) in Nextcloud.

    Returns a formatted list of task list names and their CalDAV URLs.
    Use the URL from this output as the calendar_url parameter for other tools.
    """
    try:
        client = _get_client()
        principal = client.principal()
        calendars = principal.calendars()

        if not calendars:
            return "No calendars found on this Nextcloud account."

        # Nextcloud calendars all support VTODO by default — list them all.
        results = [f"  Name: {cal.name}\n  URL:  {cal.url}" for cal in calendars]
        return "Calendars (all support tasks):\n\n" + "\n\n".join(results)
    except Exception as e:
        return f"Error listing task lists: {e}"


@mcp.tool()
def list_tasks(calendar_url: str) -> str:
    """
    List all tasks in a given task list, including completed ones.

    Args:
        calendar_url: The CalDAV URL of the task list (obtained from list_task_lists).

    Returns a formatted list showing each task's title, status, priority, due date,
    UID, and URL. Use the task URL as the task_url parameter for update/complete/delete tools.
    Use the task UID as the parent_uid parameter for create_subtask.
    """
    try:
        client = _get_client()
        calendar = client.calendar(url=calendar_url)
        todos = calendar.todos(include_completed=True)

        if not todos:
            return "No tasks found in this task list."

        lines = []
        for todo in todos:
            t = _parse_todo(todo)
            lines.append(
                f"  Title:    {t['summary']}\n"
                f"  Status:   {t['status']}\n"
                f"  Priority: {t['priority'] or 'None'}\n"
                f"  Due:      {t['due']}\n"
                f"  UID:      {t['uid']}\n"
                f"  URL:      {t['url']}"
            )

        return f"Tasks ({len(todos)} total):\n\n" + "\n\n".join(lines)
    except Exception as e:
        return f"Error listing tasks: {e}"


@mcp.tool()
def create_task(
    calendar_url: str,
    title: str,
    due_date: Optional[str] = None,
    priority: Optional[int] = None,
    notes: Optional[str] = None,
) -> str:
    """
    Create a new task in a task list.

    Args:
        calendar_url: The CalDAV URL of the task list (obtained from list_task_lists).
        title: The task title/summary (required).
        due_date: Optional due date in YYYY-MM-DD format, e.g. "2025-06-30".
        priority: Optional priority from 1 (highest) to 9 (lowest). 5 is medium.
        notes: Optional description or notes for the task.

    Returns the UID and URL of the newly created task.
    """
    try:
        client = _get_client()
        calendar = client.calendar(url=calendar_url)
        uid = str(uuid.uuid4())
        ical = _build_vtodo_ical(
            summary=title,
            uid=uid,
            due_date=due_date,
            priority=priority,
            notes=notes,
        )
        todo = calendar.save_todo(ical)
        return f"Task created.\n  Title: {title}\n  UID:   {uid}\n  URL:   {todo.url}"
    except Exception as e:
        return f"Error creating task: {e}"


@mcp.tool()
def create_subtask(
    calendar_url: str,
    title: str,
    parent_uid: str,
    due_date: Optional[str] = None,
    priority: Optional[int] = None,
    notes: Optional[str] = None,
) -> str:
    """
    Create a subtask linked to a parent task via the RELATED-TO field.

    Args:
        calendar_url: The CalDAV URL of the task list (obtained from list_task_lists).
        title: The subtask title/summary (required).
        parent_uid: The UID of the parent task (obtained from list_tasks).
        due_date: Optional due date in YYYY-MM-DD format.
        priority: Optional priority from 1 (highest) to 9 (lowest).
        notes: Optional description or notes.

    Returns the UID and URL of the newly created subtask.
    """
    try:
        client = _get_client()
        calendar = client.calendar(url=calendar_url)
        uid = str(uuid.uuid4())
        ical = _build_vtodo_ical(
            summary=title,
            uid=uid,
            due_date=due_date,
            priority=priority,
            notes=notes,
            related_to=parent_uid,
        )
        todo = calendar.save_todo(ical)
        return (
            f"Subtask created.\n"
            f"  Title:      {title}\n"
            f"  UID:        {uid}\n"
            f"  Parent UID: {parent_uid}\n"
            f"  URL:        {todo.url}"
        )
    except Exception as e:
        return f"Error creating subtask: {e}"


@mcp.tool()
def update_task(
    task_url: str,
    title: Optional[str] = None,
    status: Optional[str] = None,
    priority: Optional[int] = None,
    due_date: Optional[str] = None,
) -> str:
    """
    Update one or more fields on an existing task.

    Args:
        task_url: The CalDAV URL of the task (obtained from list_tasks).
        title: New title/summary (optional).
        status: New status (optional). Valid values: NEEDS-ACTION, IN-PROCESS,
                COMPLETED, CANCELLED.
        priority: New priority 1-9 (optional).
        due_date: New due date in YYYY-MM-DD format (optional).
                  Pass "none" (case-insensitive) to clear the due date.

    Returns a summary of the changes made.
    """
    try:
        client = _get_client()
        todo = client.object_by_url(task_url)
        vtodo = todo.vobject_instance.vtodo

        changes = []

        if title is not None:
            vtodo.summary.value = title
            changes.append(f"title → {title}")

        if status is not None:
            status = status.upper()
            if hasattr(vtodo, "status"):
                vtodo.status.value = status
            else:
                vtodo.add("status").value = status
            changes.append(f"status → {status}")

        if priority is not None:
            if hasattr(vtodo, "priority"):
                vtodo.priority.value = priority
            else:
                vtodo.add("priority").value = priority
            changes.append(f"priority → {priority}")

        if due_date is not None:
            if due_date.lower() == "none":
                if hasattr(vtodo, "due"):
                    vtodo.remove(vtodo.due)
                changes.append("due → cleared")
            else:
                dt = datetime.strptime(due_date, "%Y-%m-%d").date()
                if hasattr(vtodo, "due"):
                    vtodo.due.value = dt
                else:
                    vtodo.add("due").value = dt
                changes.append(f"due → {due_date}")

        if not changes:
            return "No changes specified — provide at least one field to update."

        todo.save()
        return f"Task updated.\n  Changes: {', '.join(changes)}"
    except Exception as e:
        return f"Error updating task: {e}"


@mcp.tool()
def complete_task(task_url: str) -> str:
    """
    Mark a task as COMPLETED and record the completion timestamp.

    Args:
        task_url: The CalDAV URL of the task (obtained from list_tasks).

    Returns a confirmation message with the task title.
    """
    try:
        client = _get_client()
        todo = client.object_by_url(task_url)
        vtodo = todo.vobject_instance.vtodo
        now = datetime.now(timezone.utc)

        if hasattr(vtodo, "status"):
            vtodo.status.value = "COMPLETED"
        else:
            vtodo.add("status").value = "COMPLETED"

        if hasattr(vtodo, "completed"):
            vtodo.completed.value = now
        else:
            vtodo.add("completed").value = now

        todo.save()
        title = str(vtodo.summary.value) if hasattr(vtodo, "summary") else "(unknown)"
        return f"Task '{title}' marked as COMPLETED."
    except Exception as e:
        return f"Error completing task: {e}"


@mcp.tool()
def delete_task(task_url: str) -> str:
    """
    Permanently delete a task. This action cannot be undone.

    Args:
        task_url: The CalDAV URL of the task (obtained from list_tasks).

    Returns a confirmation message with the deleted task's title.
    """
    try:
        client = _get_client()
        todo = client.object_by_url(task_url)
        title = "(unknown)"
        try:
            title = str(todo.vobject_instance.vtodo.summary.value)
        except Exception:
            pass
        todo.delete()
        return f"Task '{title}' deleted."
    except Exception as e:
        return f"Error deleting task: {e}"


if __name__ == "__main__":
    mcp.run()
