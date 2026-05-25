# Tasker Setup — Nextcloud Voice Task

This guide covers building the Tasker task that captures your voice and sends it to the Voice Task API, connecting it to Google Home so Gemini can trigger it hands-free, and troubleshooting the permission issues that prevent the handoff from completing.

**Current status:** The Tasker task and home screen shortcut are fully working. The Google Home → Tasker voice handoff is the remaining step and may require some troubleshooting depending on your Android version and Gemini permissions.

---

## What you need

- [Tasker](https://play.google.com/store/apps/details?id=net.dinglisch.android.taskerm) installed ($3.49 one-time)
- The Voice Task API running and reachable over HTTPS (see main README)
- Your API key from the `.env` file
- The [Google Home app](https://play.google.com/store/apps/details?id=com.google.android.apps.chromecast.app) installed on your phone

---

## Phase 1 — Build the Tasker Task

### Step 1 — Create the task

1. Open Tasker.
2. Tap the **Tasks** tab at the bottom.
3. Tap **+** in the bottom right.
4. Name it `Nextcloud Task` and tap the checkmark.

---

### Step 2 — Add the Get Voice action

1. Inside the task, tap **+**.
2. Go to **Input → Get Voice**.
3. Set **Title** to `What's the task?`
4. Leave the variable as the default `%VOICE` — Tasker saves whatever you say into this variable automatically.
5. Tap the back arrow to save.

---

### Step 3 — Add the HTTP Request action

> **Important:** Use **Net → HTTP Request** — NOT the older "HTTP Post" action. The legacy HTTP Post action has a different layout and does not have a clean JSON body field.

1. Tap **+** again and go to **Net → HTTP Request**.
2. At the very top of the screen, set **Method** to `POST`. Do this first — the Body field is hidden until the method is set to POST.
3. Set the **URL** to exactly:
   ```
   https://tasks-api.labos1599.com/add-task
   ```
   No brackets, no doubled `https://https://` — just the plain URL.

4. In the **Headers** field, type exactly these two lines with one Enter between them and no trailing spaces at the end of either line. Tasker is picky about trailing spaces and will silently break the request if they're present:
   ```
   Content-Type: application/json
   X-Api-Key: your-api-key
   ```

5. Scroll down past the Headers field to find the **Body** (or **Body / File**) box. Paste this exactly, including the curly brackets and quotation marks:
   ```json
   {
     "title": "%VOICE",
     "list": "LaBorde Beefalo Farms"
   }
   ```
   When the task runs, Tasker replaces `%VOICE` with whatever you said. If you say "Fix the tractor," it sends `"title": "Fix the tractor"` to the server. Change the `"list"` value to any of your Nextcloud lists, or remove that line entirely to default to Inbox.

6. Tap the back arrow to save.

---

### Step 4 — Add audio confirmation with error handling

Replace the simple Say action with an If/Else block so you know whether the task was saved or something went wrong.

1. Tap **+** → **Task → If**
   - Left box: `%http_response_code`
   - Middle dropdown: `Equals`
   - Right box: `200`

2. Tap **+** → **Alert → Say**
   - Text: `Got it. Added %VOICE to the list.`

3. Tap **+** → **Task → Else**

4. Tap **+** → **Alert → Say**
   - Text: `Sorry, the server failed with code %http_response_code.`

5. Tap **+** → **Task → End If**

---

### Final task order

When you look at the task, the actions should be in this exact order top to bottom:

1. **Get Voice** — captures what you say
2. **HTTP Request** — sends it to Unraid
3. **If** `%http_response_code eq 200`
4. **Say** "Got it. Added %VOICE to the list."
5. **Else**
6. **Say** "Sorry, the server failed with code %http_response_code."
7. **End If**

---

### Step 5 — Test manually

Tap the **play button** next to the task in the Tasks tab. Say a task title when prompted. You should hear the confirmation read back and the task should appear in Planify within a few seconds.

If you get the error voice, check:
- The URL is correct — `https://tasks-api.labos1599.com/add-task`
- The API key matches your `.env` exactly, with no trailing spaces
- The container is running on Unraid (`docker ps`)

---

### Step 6 — Create the home screen shortcut

This is the current working trigger for driving — one tap on your phone mount.

1. In Tasker, long-press the `Nextcloud Task` task.
2. Tap **Create Shortcut**.
3. Place it on a home screen you can reach from your car mount.

One tap → "What's the task?" → answer → confirmation read aloud.

---

## Phase 2 — Connect to Google Home for hands-free voice trigger

When Gemini replaced Google Assistant as the default, it hid the old Routines menu in the Google app. The classic Assistant Routines engine is still running in the background — you access it through the **Google Home app** instead.

1. Open the **Google Home app** (download from Play Store if needed).
2. Tap the **Automations** tab at the bottom (or a **Routines** button near the top).
3. Tap **+ Add** to create a new Personal routine.
4. Tap **Add starter → When I say to Google Assistant** and type your trigger phrase:
   `Update Planify`
5. Tap **Add action → scroll to the bottom → Try adding your own** and type exactly:
   `Run Nextcloud Task in Tasker`
   *(The task name inside this phrase must match the exact name you gave your task in Step 1.)*
6. Tap **Save**.

Now say "Hey Google, update Planify." Gemini recognizes the phrase, matches it to the routine, and hands execution off to Tasker, which pops up its own microphone prompt. Tasker — not Gemini — is what listens to your task so there's no hallucination risk.

---

## Phase 3 — Troubleshooting: "Switches to Tasker but doesn't start the task"

This is a common issue. Google hands the request to Tasker, but Tasker's built-in security blocks external apps from firing tasks by default. There are three fixes to apply.

---

### Fix 1 — Enable Allow External Access in Tasker

1. Open Tasker.
2. Tap the **three dots** in the top right → **Preferences**.
3. Tap the **Misc** tab.
4. Find **Allow External Access** and make sure the box is checked.
5. Tap the back arrow to save.

---

### Fix 2 — Grant the Android system permission

1. Open your phone's **Settings** app.
2. Go to **Apps → All Apps → Tasker**.
3. Tap **Permissions**.
4. Scroll to **Additional Permissions** and look for an option that says **"Allows the application to ask Tasker to run user-defined tasks."**
5. Make sure it is allowed.

---

### Fix 3 — Try alternate voice command wording

Google Assistant's Tasker integration expects a specific phrase pattern. If `Run Nextcloud Task in Tasker` isn't working, go back into the Google Home routine and try one of these instead:

- `Run Nextcloud Task with Tasker`
- `Start Nextcloud Task in Tasker`

---

After applying all three fixes, **reboot your phone** before testing again. Once the permission flags are set, Tasker will have permission to launch the voice capture as soon as Gemini hands it off.

---

## Available task lists

Use the exact name when specifying a list in the Body field:

- **Inbox** (default — used when no list is specified)
- Personal
- Church Projects
- Vet Clinic Projects
- Home Projects
- Home Lab
- Property Holdings/Construction
- LaBorde Beefalo Farms

---

## Summary of the full flow (once voice trigger is working)

```
"Hey Google, update Planify"
        ↓
  Gemini matches the routine
  and hands off to Tasker
        ↓
  Tasker: "What's the task?"
  You say: "Fix the tractor"
        ↓
  Tasker POSTs to voice-task-api
        ↓
  API adds task to Nextcloud
        ↓
  Tasker speaks: "Got it. Added Fix the tractor to the list."
        ↓
  Task appears in Planify + Tasks app
```
