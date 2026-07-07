# Chor Police — Live Game System

## 1. Supabase setup
1. Create a project at https://supabase.com
2. Go to **SQL Editor** → paste the entire contents of `sql/schema.sql` → Run.
3. Go to **Project Settings → API** → copy your **Project URL** and **anon public key**.

## 2. Configure the app
Open `js/supabaseClient.js` and replace:
```js
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

## 3. Deploy to GitHub Pages
1. Push this whole folder to a GitHub repo.
2. Repo → **Settings → Pages** → Source: `main` branch, root folder.
3. Your site will be live at `https://<username>.github.io/<repo>/`.
4. **Important:** camera-based QR scanning requires HTTPS — GitHub Pages already serves over HTTPS, so this works out of the box.

## 4. Run the game
1. Login with code **ADMIN1** on the site → go to **Admin**.
2. **Checkposts tab** → add all checkposts.
3. **Players tab** → add all chors, police, and checkpost volunteers (assign each volunteer to one checkpost). Each gets an auto-generated login code — write these on paper/cards to hand out, or read from the Players table.
4. **Settings tab** → confirm group size (default 10), penalty seconds (default 120), lifelines (default 3).
5. Hand each participant their code:
   - **Chor** → logs in on their own phone at the site → sees their personal QR + lifelines + checkpost progress.
   - **Police** → logs in → scans a chor's QR to catch them.
   - **Volunteer** → logs in → sees their assigned checkpost → scans every chor who arrives, then taps **Finalize Group** once done:
     - 1 chor scanned → Safe (no stamp)
     - exactly 10 scanned together → Stamped (counts toward winning)
     - any other number → no stamp (police can catch them)
   - **Admin** → watch the **Live Status** tab for real-time standings, and **Catch Log** for history.

## 5. Winning
A chor automatically becomes a **winner** the moment they've been stamped at every checkpost.
A chor is automatically **eliminated** after their 3rd catch (0 lifelines left).

## Notes
- To reset between rounds/events: Admin → Settings tab → **Reset Game** (keeps all players & checkposts, wipes progress).
- Security: this uses simple code-based login (no passwords) with a permissive Supabase anon policy — fine for a trusted live event. Don't reuse this schema for anything requiring strong security.
