// ============================================================
// FILL THESE IN with your Supabase project values
// Project Settings > API
// ============================================================
const SUPABASE_URL = "https://xjjfhmmokjvajmmwpcqe.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhqamZobW1va2p2YWptbXdwY3FlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0MzExNDcsImV4cCI6MjA5OTAwNzE0N30.5v1WfHdQm4Wxx5Fq0GHg2fvlxAC52BbdYz-aAws1heo";

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
