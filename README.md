# ALPHA Run Club, Pune — Chor vs Police Live Game System

10 Safe Zones each give one unique sticker. A chor has 3 lifelines,
2-minute jail per catch, and can resume from **any** Safe Zone after
release. Collect all 10 stickers to win. Every scan-in grants a real,
enforced **Safe Ticket** — police literally cannot catch a chor while
it's active. After each zone, the chor is routed to a different next
zone via a rotating hint system, with an optional voucher/coupon
reward per zone.

## 1. Supabase setup
1. Create a project at https://supabase.com
2. **SQL Editor** → paste all of `sql/schema.sql` → Run.
   (Safe to re-run — it's all `create or replace` / `add column if not exists`, so it upgrades an older deployment in place without losing data.)
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

## 4. Set up the event
1. Login with **`ADMIN1`** → change this code immediately (Supabase Table Editor → `players` → edit that row's `code`).
2. **Safe Zones tab** → add all 10 zones. For each you can optionally set:
   - **Hint** — the clue shown to whichever chor gets routed here next (e.g. "Look for the store with a giant shoe outside"). Leave blank and the chor just sees a generic "ask a volunteer" message.
   - **Voucher/coupon** — shown to a chor the moment they collect this zone's sticker (e.g. a discount code). Leave blank for no reward.
   - Both are editable any time via **Edit** on each zone's card.
3. **Players tab → Bulk add** → paste one name per line, pick role, hit **Generate Codes & Add All**.
4. **Print Cards tab** → pick a role → **Load Cards** → **Print** for physical badges.
5. **Settings tab** → jail time, lifelines, and the **Safe Ticket protection window** (default 90s).

## 5. How each role uses it live
- **Chor**: sees a progress ring (X/10), their QR + code, a **Next Clue** card (the hint for wherever they're routed next — not the full zone list, so it stays a hunt), any vouchers earned, and a big green **Safe Ticket** banner with a live countdown whenever they're protected.
- **Safe Zone Volunteer**: scans every chor who walks in. Each scan **grants a Safe Ticket** (so they genuinely can't be caught for the protection window) and awards that zone's sticker if new. Shows live "currently protected" headcount at the zone.
- **Police**: scanning a chor who currently holds a Safe Ticket is **rejected outright** with a clear "🛡️ Safe Ticket active" message — catching only works when the ticket has expired and they're not already in jail.
- **Admin**: Live Status shows a 🛡️ safe badge next to any currently-protected chor, plus Release/Restore/Eliminate overrides, full catch/sticker logs with Undo, and Settings.

## 6. How the hint/routing system works
When a chor collects (or re-scans) a sticker at Zone A, the system:
1. Grants/refreshes their Safe Ticket.
2. Picks one of their **not-yet-collected** zones to send them to next, rotating through a per-zone cursor — so if 10 chors leave Zone A around the same time, they get spread across different next zones instead of all piling into the same one.
3. Shows that zone's **hint text** on the chor's own passport (not its name), and shows any **voucher** for the zone they just left if it was newly collected.

The very first zone a chor visits isn't hint-routed (nothing to route from yet) — announce your starting zones however you like at kickoff.

## 7. Admin-only overrides (rule-affecting actions)
Every rule-bending action is restricted to Admin and enforced **server-side** — the database functions re-check that the caller's player id has `role = 'admin'` before doing anything, not just hidden in the UI:
- **Undo any catch**, **Release** from jail, **Restore** an eliminated chor, **Eliminate** manually, **Reset Progress**, **Full Wipe**.

## 8. About "DELETE requires a WHERE clause"
This error comes from Supabase's **Table Editor**, not our app — its "delete all rows" button calls the REST API without a filter, and PostgREST refuses that on purpose as a safety guard. It's not a sign anything is broken.
Use the app's own buttons instead (Settings tab):
- **Reset Progress** — keeps all players & zones, wipes stickers/catches/lifelines/hints. Good between rounds.
- **Full Wipe — Delete Everyone & Zones** — deletes every player except the admin login and every Safe Zone. Good for starting a completely new event. Requires typing `DELETE` to confirm.
Both run as proper database functions, so they aren't affected by the REST guard.

## 9. About the double-scan fix
Camera QR scanners fire their callback many times per second while a code is in view. Fixed two ways:
- **Client-side cooldown**: the same code is ignored for 4 seconds after a scan.
- **Server-side idempotency**: awarding a sticker twice is a safe no-op, and catching an already-jailed or currently-protected chor is rejected — so a slipped-through duplicate can't cause harm.

## 10. Winning / elimination
- A chor **wins** automatically on collecting all 10 stickers.
- A chor is **eliminated** automatically after their 3rd catch (0 lifelines left).

## Notes
- Login is a simple 6-character code per person, no passwords — fine for a trusted live event, not a public-security deployment.
- Mobile-first throughout: big tap targets, no accidental input zoom, works one-handed while walking.
- Branded for **Alpha Run Club, Pune** with a bold gradient wordmark. Want an actual logo image instead of the text wordmark, or a different accent color? Easy to drop in.
