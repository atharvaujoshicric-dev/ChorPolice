// ============================================================
// FILL THESE IN with your Supabase project values
// Project Settings > API
// ============================================================
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------- shared helpers ----------
function getSession() {
  const raw = localStorage.getItem("cp_player");
  return raw ? JSON.parse(raw) : null;
}

function setSession(player) {
  localStorage.setItem("cp_player", JSON.stringify(player));
}

function clearSession() {
  localStorage.removeItem("cp_player");
}

function requireRole(role) {
  const s = getSession();
  if (!s || s.role !== role) {
    window.location.href = "index.html";
    return null;
  }
  return s;
}

function logout() {
  clearSession();
  window.location.href = "index.html";
}

function fmtCountdown(msLeft) {
  if (msLeft <= 0) return "0:00";
  const totalSec = Math.ceil(msLeft / 1000);
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function codeFromName(name, usedCodes) {
  usedCodes = usedCodes || new Set();
  const firstWord = (name || "").trim().split(/\s+/)[0] || "XXX";
  let letters = firstWord.replace(/[^a-zA-Z]/g, "").toUpperCase().slice(0, 3);
  while (letters.length < 3) letters += "X";

  const base = `ALPHA-${letters}`;
  let code = base;
  let n = 2;
  while (usedCodes.has(code)) {
    code = `${base}${n}`;
    n++;
  }
  usedCodes.add(code);
  return code;
}
