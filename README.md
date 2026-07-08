# ALPHA Run Club, Pune — Chor vs Police Live Game System

10 Safe Zones each give one unique sticker. A chor has 3 lifelines,
2-minute jail per catch, and can resume from **any** Safe Zone after
release. Collect all 10 stickers to win. Every genuinely new sticker
grants a real, enforced **Safe Ticket** — police literally cannot
catch a chor while it's active. After each zone, the chor is routed
to a different next zone via a rotating hint system, with an optional
voucher/coupon reward per zone.

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
3. Live at `https://<username>.github.io/<repo>/`.

## 4. First admin login — set your passcode (do this before anything else)
1. Login with **`ADMIN1`** → change this code in Supabase Table Editor (`players` table → that row → `code`).
2. Go to **Settings tab → 🔐 Admin Passcode**. Type `change-this-now` into "Passcode used by this browser" → **Save on This Device**.
3. Immediately set your own private passcode in "Change passcode" below it, and save it somewhere safe (a password manager, not a shared doc).
4. Every destructive action (undo, eliminate, reset, wipe, manual overrides) requires this passcode, checked **on the server** — see the Security section below for why this matters. If you ever see "Not authorized: invalid admin passcode," redo step 2 on that device.

## 5. Set up the event
1. **Safe Zones tab** → add all 10 zones, each optionally with a **Hint** (shown to whoever's routed here next) and a **Voucher/coupon** (shown once collected). Both editable any time.
2. **Players tab → Bulk add** → paste one name per line, pick role, hit **Generate Codes & Add All**. Codes are `ALPHA-XXX` (first 3 letters of first name; auto-numbered on collisions, e.g. `ALPHA-ROH`, `ALPHA-ROH2`).
3. **Print Cards tab** → pick a role → **Load Cards** → **Print** for physical badges.
4. **Settings tab** → jail time, lifelines, and the Safe Ticket protection window (default 90s).

## 6. How each role uses it live
- **Chor**: progress ring (X/10), QR + code, a **Next Clue** card, any vouchers earned, and a big green **Safe Ticket** banner with a live countdown whenever protected.
- **Safe Zone Volunteer**: scans every chor's QR. Camera-only — no manual code entry, so a sticker can never be awarded without an actual scan. A genuinely new sticker grants a Safe Ticket; re-scanning an already-collected zone does not (see Security below for why).
- **Police**: scans a chor's QR to catch them. Camera-only, same reason. A chor holding an active Safe Ticket cannot be caught at all — the attempt is rejected with a clear message.
- **Admin**: Live Status is now a card per chor with a **lifelines stepper** (−/+ for precise adjustment, not just full reset), Release Jail, Full Restore, and Eliminate. A **Manual Override** tab covers genuine camera failures (see below). Full catch/sticker logs with Undo.

## 7. Security — what was fixed and why it matters
This system uses simple code-based login (no passwords, no real user accounts) for speed at a live event. That convenience comes with real trust tradeoffs, and a review turned up several concrete ways it could be abused. All are now fixed server-side (not just hidden in the UI, since a technically-minded participant could otherwise call the underlying functions directly):

- **A chor could self-award every sticker.** The sticker function didn't check who was calling it — anyone could call it directly with any zone id and win instantly with zero visits. Now it verifies the caller is the actual volunteer assigned to that specific zone.
- **A chor could "catch" (eliminate) a rival.** The catch function didn't verify the caller was really police — anyone could call it directly claiming to be police. Now it verifies the caller's account actually has the police role.
- **Admin actions were "protected" only by a guessable ID.** Since the players table is open (needed for login lookups), anyone could look up the admin's id and call admin-only functions directly. Now every admin action requires a hidden passcode stored in a table nobody can read via the API — only the database functions themselves can check it.
- **Safe Ticket could be farmed for free.** Every scan used to refresh the protection window, so a chor could keep getting rescanned at a zone they'd already collected and stay permanently uncatchable. Now protection is only granted on a genuinely new sticker.
- **Manual code entry let people skip the physical scan.** Removed entirely from Police and Volunteer — both are camera-only now. A genuine camera failure goes through Admin's Manual Override tab instead, which is passcode-protected and logged exactly like a normal scan.

**Residual limitations, honestly stated:** this is still not a fully authenticated system. Two people could still share one chor's code and QR between two phones (there's no way to stop that without real accounts), and anyone with physical access to an admin's unlocked device could read the passcode out of that browser's local storage. For a friendly community run, this is a reasonable trust level; if you ever need this fully locked down, the real fix is migrating to Supabase Auth with per-person accounts, which is a bigger change than fits this quick-turnaround architecture.

## 8. About "DELETE requires a WHERE clause"
This error comes from Supabase's **Table Editor**, not our app — its "delete all rows" button calls the REST API without a filter, and PostgREST refuses that on purpose as a safety guard. Use the app's own Settings tab buttons instead (Reset Progress / Full Wipe), which run as proper database functions and aren't affected by that guard.

## 9. About the double-scan fix
Camera QR scanners fire their callback many times per second while a code is in view. Fixed two ways: a client-side 4-second cooldown ignoring repeat scans of the same code, and server-side idempotency (awarding a sticker twice, or catching an already-jailed/protected chor, is safely rejected/no-op).

## 10. Winning / elimination
- A chor **wins** automatically on collecting all 10 stickers.
- A chor is **eliminated** automatically after their 3rd catch (0 lifelines left), or manually via Admin.

## Notes
- Mobile-first throughout: big tap targets, no accidental input zoom, works one-handed while walking.
- Branded for **Alpha Run Club, Pune** with a bold gradient wordmark.
