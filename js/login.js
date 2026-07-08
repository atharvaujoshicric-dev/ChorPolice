const codeInput = document.getElementById("codeInput");
const loginBtn = document.getElementById("loginBtn");
const err = document.getElementById("err");

// If already logged in, bounce straight to the right page
(function autoRedirect() {
  const s = getSession();
  if (s) goToRole(s.role);
})();

function goToRole(role) {
  const map = {
    chor: "chor.html",
    police: "police.html",
    volunteer: "volunteer.html",
    admin: "admin.html",
  };
  window.location.href = map[role] || "index.html";
}

async function doLogin() {
  err.style.display = "none";
  const code = codeInput.value.trim().toUpperCase();
  if (!code) return;

  if (SUPABASE_URL.includes("YOUR_SUPABASE_URL") || SUPABASE_ANON_KEY.includes("YOUR_SUPABASE_ANON_KEY")) {
    err.textContent = "Setup incomplete: js/supabaseClient.js still has placeholder URL/key. Edit that file with your real Supabase project values.";
    err.style.display = "block";
    return;
  }

  loginBtn.disabled = true;
  loginBtn.textContent = "Checking...";

  const { data, error } = await sb.from("players").select("*").eq("code", code).maybeSingle();

  loginBtn.disabled = false;
  loginBtn.textContent = "Login";

  if (error) {
    err.textContent = "Server error: " + error.message;
    err.style.display = "block";
    return;
  }
  if (!data) {
    err.textContent = `No player found with code "${code}". Check the code, or ask admin to confirm it exists in the players table.`;
    err.style.display = "block";
    return;
  }

  setSession(data);
  goToRole(data.role);
}

loginBtn.addEventListener("click", doLogin);
codeInput.addEventListener("keydown", (e) => { if (e.key === "Enter") doLogin(); });
