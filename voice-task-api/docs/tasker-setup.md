# Tasker Setup — Voice Task Creation

This guide sets up a hands-free flow where you say "Hey Google, add a task," Tasker captures your voice, and the task appears in Nextcloud within seconds.

---

## What you need

- [Tasker](https://play.google.com/store/apps/details?id=net.dinglisch.android.taskerm) installed ($3.49 one-time — worth it)
- The Voice Task API running and reachable over HTTPS (see main README)
- Your API key from the `.env` file
- Your API endpoint URL (e.g. `https://tasks-api.yourdomain.com/add-task`)

---

## Part 1 — Create the Tasker Task

1. Open Tasker.
2. Tap the **Tasks** tab at the bottom.
3. Tap the **+** button in the bottom right.
4. Name the task `Add Nextcloud Task` and tap the checkmark.

You're now in the task editor. Add the following actions in order:

---

### Action 1 — Capture the task title by voice

1. Tap **+** to add an action.
2. Choose **Input → Get Voice**.
3. Set these fields:
   - **Title:** `What's the task?`
   - **Variable:** `%taskTitle`
   - **Timeout:** `10` seconds
4. Tap the back arrow to save.

---

### Action 2 — POST to the API

1. Tap **+** to add another action.
2. Choose **Net → HTTP Request**.
3. Fill in:
   - **Method:** `POST`
   - **URL:** `https://tasks-api.yourdomain.com/add-task`
   - **Headers:** tap the field and add two headers:
     - `Content-Type` : `application/json`
     - `X-Api-Key` : `paste-your-api-key-here`
   - **Body:** `{"title": "%taskTitle"}`
   - **Variable Name:** `%httpResult`
4. Tap back to save.

> **Tip:** To add tasks to a specific list, change the body to:
> `{"title": "%taskTitle", "list": "Farm"}`
> Replace `Farm` with your list name. Or skip it and let the API use your default list.

---

### Action 3 — Read the confirmation aloud

1. Tap **+** to add another action.
2. Choose **Alert → Say**.
3. Set **Text** to `%httpResult`.
4. Leave everything else at default.
5. Tap back.

Your task now has three actions. Tap the back arrow to exit the task editor.

---

## Part 2 — Test the task manually

1. In the Tasks tab, tap the **play button** next to `Add Nextcloud Task`.
2. Say a task title when the voice prompt appears (e.g. "Pick up feed").
3. You should hear Tasker say `Added 'Pick up feed' to Tasks` (or whatever your default list is).
4. Open Planify — the task should be there.

If you get an error read back, check:
- The URL is correct and HTTPS is working
- The API key matches exactly what's in your `.env`
- The container is running (`docker ps` on Unraid)

---

## Part 3 — Connect to Google Assistant (hands-free trigger)

This lets you say "Hey Google, add a task" while driving without touching your phone.

### Option A — Google Assistant Routine (simplest)

1. Open the Google app on your phone.
2. Tap your profile picture → **Settings → Google Assistant → Routines**.
3. Tap **+** to create a new routine.
4. **Starter:** type `add a task` (or `add task`, whatever feels natural to say).
5. **Action:** tap **Add action → Try adding your own → Open app**.
6. Choose the **Tasker** shortcut you'll create in the next step.

### Creating the Tasker shortcut (required for Option A)

1. In Tasker, long-press the `Add Nextcloud Task` task.
2. Tap **Create Shortcut**.
3. Android will ask where to place it — add it to your home screen.
4. The shortcut icon appears on your home screen. This is what the Google Assistant routine will launch.

---

### Option B — Android App Shortcut on car mount screen

If you have a phone mount in your car, put the Tasker shortcut on an easy-to-reach home screen. One tap → voice prompt → done. No "Hey Google" needed.

This is the most reliable option because it works regardless of Google Assistant's connection state.

---

## Part 4 — Adding to a specific list by voice (optional, advanced)

If you regularly add tasks to different lists (e.g. Farm, Home Lab, Shopping), you can add a second voice prompt for the list name.

After Action 1 (Get Voice for title), add another **Get Voice** action:
- **Title:** `Which list? Say skip for default.`
- **Variable:** `%taskList`
- **Timeout:** `7` seconds

Then change Action 2's body to:
```
{"title": "%taskTitle", "list": "%taskList"}
```

If you say "skip," the API receives `list: "skip"` which doesn't match any real list name, so it falls back to your `DEFAULT_LIST`. If you say a valid list name, it goes there.

> **Driving note:** Two voice prompts adds friction. For most people, a single prompt with a fixed default list is the better experience while driving. Use the two-prompt version only if you genuinely need multiple lists hands-free.

---

## Summary of the full flow

```
"Hey Google, add a task"
        ↓
  Google Assistant Routine
  launches Tasker shortcut
        ↓
  Tasker: "What's the task?"
  You say: "Call the vet"
        ↓
  Tasker POSTs to voice-task-api
        ↓
  API adds task to Nextcloud
        ↓
  Tasker speaks: "Added 'Call the vet' to Tasks"
        ↓
  Task appears in Planify + Tasks app
```
