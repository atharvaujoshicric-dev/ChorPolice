# ALPHA — Chor vs Police — Live Game System

Matches the official event blueprint: 10 Safe Zones each give one unique
sticker, zones hold up to 10 chors at a time (staff-enforced), a chor has
3 lifelines total, 2-minute jail per catch, and can resume from **any**
Safe Zone after release. Collect all 10 stickers to win.

## 1. Supabase setup
1. Create a project at https://supabase.com
2. **SQL Editor** → paste all of `sql/schema.sql` → Run.
   (Safe to re-run — it cleans up the old v1 schema automatically if you had it.)
3. **Project Settings → API** → copy your **Project URL** and **anon public key**.

## 2. Configure the app
Edit `js/supabaseClient.js`:
```js
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

## 3. Deploy to GitHub Pages
1. Push the folder to a GitHub repo.
2. Repo → **Settings → Pages** → Source: `main` branch, root.
3. Live at `https://<username>.github.io/<repo>/`. HTTPS is automatic, which QR camera scanning requires.

## 4. Set up the event (fast path for ~200 people)
1. Login with **`ADMIN1`** → change this code immediately (Supabase Table Editor → `players` → edit that row's `code`).
2. **Safe Zones tab** → add all 10 zones.
3. **Players tab → Bulk add** → paste one name per line, pick role (Chor / Police / Volunteer — for volunteers also pick their zone), hit **Generate Codes & Add All**. Do this once for your 180 chors, once for 20 police, and once per zone for volunteers.
4. **Print Cards tab** → pick a role → **Load Cards** → **Print**. Gives you a grid of name + code + QR per person, ready to cut into badges/wristbands before the event — no need to hand out codes verbally.
5. **Settings tab** → confirm jail time (default 120s) and lifelines (default 3).

## 5. How each role uses it live
- **Chor**: logs in on their own phone → sees their QR, remaining lifelines, and which of the 10 zones they've collected.
- **Safe Zone Volunteer**: logs in → sees their assigned zone → taps **Start Scanning** and just keeps scanning every chor who walks in. Each scan instantly awards that zone's sticker (or says "already collected" if they've been there before) — no extra steps, no batching. Being first/alone at a zone is always safe and always gets the sticker; the UI just labels it "Safe ticket — first one in" vs "Safe — arrived with others" for clarity. Staff still physically enforce the 10-person cap by eye.
- **Police**: logs in → scans a chor caught outside a Safe Zone → confirms the catch. Lifelines drop, 2-minute jail starts automatically on the chor's own phone. Police can no longer undo a catch themselves (see below).
- **Admin**: **Live Status** for real-time standings and quick per-chor overrides, **Logs** for full catch/sticker history with the ability to undo any catch.

## 6. Admin-only overrides (rule-affecting actions)
Anything that can bypass the normal rules is restricted to Admin, and enforced **server-side** (not just hidden in the UI — the database functions themselves re-check that the caller's player id has `role = 'admin'` before doing anything):
- **Undo any catch** (Logs tab → Undo button) — restores the chor's life and clears jail, no time limit, works on any catch by any officer.
- **Release** — clear a chor's jail time immediately.
- **Restore** — bring an eliminated chor back to active with full lifelines (keeps their collected stickers).
- **Eliminate** — force-eliminate a chor manually.
- **Reset Game** — wipes all progress event-wide.

Police used to have a self-service "undo my last catch" button — that's been removed; only Admin can undo now.

## 7. About the double-scan fix
Camera QR scanners fire their callback many times per second while a code
is in view, which was causing the same scan to be processed repeatedly.
Fixed two ways:
- **Client-side cooldown**: the same code is ignored for 4 seconds after a successful scan.
- **Server-side idempotency**: awarding a sticker twice for the same chor+zone is a safe no-op (unique constraint), and catching an already-jailed chor is rejected — so even if a duplicate slips through, nothing bad happens.

## 8. Winning / elimination
- A chor **wins** automatically the moment they've collected all 10 stickers.
- A chor is **eliminated** automatically after their 3rd catch (0 lifelines left).
- **Reset Game** (Settings tab) wipes all progress but keeps every player's code — useful for a second round.

## Notes
- Login is a simple 6-character code per person, no passwords — fine for a trusted live event, not for a public-security deployment.
- Everything is mobile-first: big tap targets, no accidental zoom on inputs, works fine one-handed while walking around a mall.
- Branded for **Alpha Run Club, Pune** — every screen shows the club name and a CHOR vs POLICE wordmark. Want a different accent color or an actual logo image instead of the wordmark? Easy to drop in — just say the word.
