#!/usr/bin/env python3
"""HTTP API for voice-triggered Nextcloud task creation."""

import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import caldav
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

load_dotenv()

NEXTCLOUD_URL = os.getenv("NEXTCLOUD_URL", "").rstrip("/")
NEXTCLOUD_USERNAME = os.getenv("NEXTCLOUD_USERNAME", "")
NEXTCLOUD_PASSWORD = os.getenv("NEXTCLOUD_PASSWORD", "")
CALDAV_URL = f"{NEXTCLOUD_URL}/remote.php/dav"
API_KEY = os.getenv("API_KEY", "")
DEFAULT_LIST = os.getenv("DEFAULT_LIST", "Tasks")

PRIORITY_MAP = {"high": 1, "medium": 5, "low": 9}


@asynccontextmanager
async def lifespan(app: FastAPI):
    missing = [
        name
        for name, val in [
            ("API_KEY", API_KEY),
            ("NEXTCLOUD_URL", NEXTCLOUD_URL),
            ("NEXTCLOUD_USERNAME", NEXTCLOUD_USERNAME),
            ("NEXTCLOUD_PASSWORD", NEXTCLOUD_PASSWORD),
        ]
        if not val
    ]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")
    yield


app = FastAPI(title="Voice Task API", docs_url=None, redoc_url=None, lifespan=lifespan)


def verify_key(x_api_key: str = Header(...)):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")


class TaskRequest(BaseModel):
    title: str = Field(..., min_length=1)
    list: Optional[str] = None
    priority: Optional[str] = None  # "high", "medium", or "low"


@app.get("/health", response_class=PlainTextResponse)
def health():
    return "ok"


@app.post("/add-task", response_class=PlainTextResponse)
def add_task(req: TaskRequest, _=Depends(verify_key)):
    list_name = (req.list or "").strip() or DEFAULT_LIST
    priority = PRIORITY_MAP.get((req.priority or "").lower())

    try:
        client = caldav.DAVClient(
            url=CALDAV_URL,
            username=NEXTCLOUD_USERNAME,
            password=NEXTCLOUD_PASSWORD,
        )
        calendars = client.principal().calendars()

        cal = next((c for c in calendars if c.name.lower() == list_name.lower()), None)
        if cal is None:
            # Fall back to default list; note which list was requested
            cal = next((c for c in calendars if c.name.lower() == DEFAULT_LIST.lower()), None)
            if cal is None:
                available = ", ".join(c.name for c in calendars)
                return f"List '{list_name}' not found. Available: {available}"
            list_name = DEFAULT_LIST

        uid = str(uuid.uuid4())
        now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//voice-task-api//EN",
            "BEGIN:VTODO",
            f"UID:{uid}",
            f"DTSTAMP:{now}",
            f"SUMMARY:{req.title}",
            "STATUS:NEEDS-ACTION",
        ]
        if priority is not None:
            lines.append(f"PRIORITY:{priority}")
        lines += ["END:VTODO", "END:VCALENDAR"]

        cal.save_todo("\r\n".join(lines))
        return f"Added '{req.title}' to {list_name}"

    except Exception as e:
        return f"Error adding task: {e}"


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
