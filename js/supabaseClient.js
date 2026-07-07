// ============================================================
// FILL THESE IN with your Supabase project values
// Project Settings > API
// ============================================================
const SUPABASE_URL = "https://kbjdfojyydatsqmrrnnf.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtiamRmb2p5eWRhdHNxbXJybm5mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0MTUzNDYsImV4cCI6MjA5ODk5MTM0Nn0.LQPinoL7kXF52i-8TdC68_zrv8Q9MjA3yqQprfuBouE";

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

function genCode(len = 6) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let out = "";
  for (let i = 0; i < len; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}
