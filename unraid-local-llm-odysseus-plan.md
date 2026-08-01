# Local LLM + Odysseus on Unraid — Full Plan

*Written 2026-07-09*

**The short version:** Run Ollama as a standard Unraid Docker container with the GPU passed through, deploy Odysseus via Docker Compose pointed at Ollama's OpenAI-compatible endpoint, and expose it on the LAN so Tailscale picks it up. Start on the 1070 Ti with 7–8B models today; upgrade to a **used RTX 3090 24GB (~$700)** for the best price-per-VRAM, keeping the 1070 Ti in the box for Jellyfin transcoding.

Odysseus (PewDiePie's self-hosted AI workspace) is fully open source (MIT), ships as a Docker Compose stack, and supports any OpenAI-compatible backend — including Ollama — so it slots into Unraid cleanly.

---

## Phase 1 — GPU groundwork on Unraid (30 min)

1. **Update Unraid** to a current 7.x release (Settings → Update OS).
2. **Install the Nvidia Driver plugin** (ich777's, from Community Apps).
3. **Pick the driver branch carefully:** the 1070 Ti is Pascal, and NVIDIA moved Pascal to the legacy **580.xx branch** — the *last* driver series that supports it. In the plugin settings, select a 580-series driver rather than "latest," or a future driver bump will silently break the card.
4. Reboot, then verify: `nvidia-smi` in the Unraid terminal should show the 1070 Ti. Note the GPU UUID it prints — some container templates want it.
5. If Jellyfin already uses the GPU for transcoding, nothing changes — NVENC transcoding and LLM inference can share the card simultaneously; they only compete for VRAM (a transcode uses a few hundred MB).

## Phase 2 — Ollama container (30 min)

Why Ollama rather than Odysseus's built-in "Cookbook" model serving: on Unraid, a separate Ollama container is easier to manage, restart, and update through the normal Unraid UI, and it's the setup Odysseus's own docs describe. Also, **vLLM is off the table on the 1070 Ti** (it requires compute capability 7.0+; Pascal is 6.1) — Ollama/llama.cpp is the correct backend for this card.

1. Install **Ollama** from Community Apps.
2. In the template: add `--gpus=all` to Extra Parameters (or set `NVIDIA_VISIBLE_DEVICES` to the GPU UUID), confirm port `11434`, and point the models path at a share with real disk space — models are 4–20GB each (e.g. `/mnt/user/appdata/ollama`).
3. Pull a starter model sized for 8GB VRAM:

   ```
   docker exec ollama ollama pull qwen3:8b
   ```

4. Sanity-check GPU inference: `docker exec ollama ollama run qwen3:8b "hello"` — then check `nvidia-smi` shows the process on the GPU. On the 1070 Ti expect roughly 20–30 tokens/sec on an 8B Q4 model — genuinely usable.

**Models that fit in 8GB now:** Qwen3 8B, Llama 3.1 8B, Gemma 3 4B/12B-Q3, Phi-4-mini — all at Q4 quantization. This tier is fine for chat, summarization, and light coding help; it will feel limited for complex reasoning.

## Phase 3 — Odysseus (1–2 hours)

Unraid's GUI doesn't do Compose natively, so install the **Compose Manager plugin** (Community Apps) first. Odysseus's docs specifically note that stack-manager UIs should use its bundled single-file variants, which simplifies things:

1. In a share (e.g. `/mnt/user/appdata/odysseus`):

   ```
   git clone https://github.com/pewdiepie-archdaemon/odysseus.git
   cd odysseus && cp .env.example .env
   ```

2. Edit `.env`:
   - `APP_BIND=0.0.0.0` — required so the UI is reachable over LAN/Tailscale (default is localhost-only)
   - `APP_PORT=7000` (change if something on the server already uses 7000)
   - Leave `AUTH_ENABLED=true`
   - `ALLOWED_ORIGINS` — add the URLs you'll actually browse from (LAN IP and Tailscale hostname), or the UI will hit CORS errors
3. Create a Compose Manager stack pointing at the repo. Since GPU serving lives in the Ollama container, the **base `docker-compose.yml` is enough** — the `gpu-nvidia` variant is only needed for Odysseus's built-in Cookbook serving.
4. `docker compose up -d --build` (or start via Compose Manager). First build takes a while.
5. Get the temp admin password: `docker compose logs odysseus`. Log in at `http://SERVER-IP:7000` as `admin`, change the password, and in `data/auth.json` **disable open signup**.
6. **Connect the backend:** Settings → Model configuration → add an OpenAI-compatible endpoint: `http://SERVER-IP:11434/v1` (use the Unraid host IP, not localhost — Odysseus runs in its own container network). The Ollama models should appear.
7. The stack also brings up SearXNG (web search, :8080), ChromaDB (RAG/memory, :8100), and ntfy (notifications, :8091) — all localhost-bound by default, which is what you want; they're consumed through the authenticated UI.

Remote access (Tailscale already handled separately): once `APP_BIND=0.0.0.0` is set, `http://<tailscale-ip-or-magicdns>:7000` just works. One quirk: browsers block the clipboard API on plain-HTTP non-localhost origins, so copy buttons in the UI won't work over a raw LAN IP — Tailscale Serve (HTTPS) fixes that if it bothers you.

## Phase 4 — GPU upgrade

For LLM inference, two numbers dominate: **VRAM capacity** (decides which models fit at all) and **memory bandwidth** (decides tokens/sec). Market as of mid-2026:

| Card | VRAM / bandwidth | Price | What it unlocks |
|---|---|---|---|
| Used **RTX 3090** | 24GB / 936 GB/s | ~$700 | 27–32B models at Q4 (Qwen3 32B, Gemma 3 27B) |
| New **RTX 5060 Ti 16GB** | 16GB / 448 GB/s | ~$449 | 14B class comfortably; warranty; 180W |
| New **RTX 5090** | 32GB / 1.8 TB/s | ~$2,000+ | 32B at high quant + huge context, fastest by far |

**Recommendation: the used RTX 3090.** The jump from 8B-class to 30B-class models is the single biggest capability step in local LLMs — 30B models are where coding help and reasoning start feeling genuinely good — and the 3090 is the only card that gets there for under $1,000. Its bandwidth (936 GB/s) still beats everything below the 5090, and inference is bandwidth-bound. The 5060 Ti is the safer, cheaper, warrantied pick but caps out at 14B-class; the 5090 is the no-compromise pick if $2K is on the table. A second used 3090 later (48GB total, 70B models) is a proven upgrade path that llama.cpp/Ollama handle natively. Skip the used 4090 — same 24GB, barely more bandwidth, hundreds more.

**Server checklist before buying a 3090:**

- **PSU:** 350W TDP with sharp transient spikes — a quality 850W+ unit if the 1070 Ti stays in alongside it, 750W if it's a straight swap. Needs 2–3× 8-pin PCIe connectors.
- **Physical fit:** most 3090s are 3-slot, ~31cm cards. Measure the case; blower-style models (EVGA/Gigabyte Turbo) suit rack cases better but run loud.
- **Cooling:** in an enclosed server, watch VRAM temps under sustained inference (the 3090's rear VRAM runs hot). Set a power limit — `nvidia-smi -pl 280` costs ~5% performance and drops heat substantially. Worth doing as a matter of course.
- **Keep the 1070 Ti** for Jellyfin if slot/PSU headroom allows — it isolates transcoding from LLM VRAM entirely. If not, one 3090 happily does both jobs.
- **Driver note:** mixing the Pascal card and the 3090 in one box is fine on the 580 branch, but once the 1070 Ti eventually comes out, move to current drivers.

**Post-upgrade models (24GB):** Qwen3 32B Q4, Gemma 3 27B Q4, GPT-OSS-20B (fits fully with room for big context), Qwen3-Coder-30B-A3B (MoE — very fast tokens/sec for coding). At that point also revisit vLLM for higher throughput; the 3090 (compute 8.6) supports it.

## Suggested order of operations

1. Do Phases 1–3 **now on the 1070 Ti** — the entire software stack is identical after the upgrade, so everything is debugged and daily-driven before spending GPU money.
2. Watch used 3090 prices (eBay ~$650–750; local listings often less). Test with `nvidia-smi` stress + a memtest_vulkan run on arrival.
3. Swap the card, `ollama pull qwen3:32b`, done — Odysseus doesn't change at all.

## Sources

- [Odysseus GitHub repo](https://github.com/pewdiepie-archdaemon/odysseus) and its [setup docs](https://github.com/pewdiepie-archdaemon/odysseus/blob/main/docs/setup.md)
- [Odysseus project page](https://pewdiepie-archdaemon.github.io/odysseus/)
- [Community setup guide](https://www.cybernotes.tech/p/setup-guide-odysseus-from-pewdiepie)
- [Used 3090 vs 5060 Ti 2026 pricing](https://www.compute-market.com/blog/used-rtx-3090-vs-rtx-5060-ti-local-ai-2026)
- [Dual 5060 Ti vs 3090 LLM testing](https://www.hardware-corner.net/guides/dual-rtx-5060-ti-16gb-vs-rtx-3090-llm/)
- [3090 vs 5060 Ti per-dollar comparison](https://craftrigs.com/comparisons/rtx-3090-vs-rtx-5060-ti-local-llm/)
