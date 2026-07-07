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

  loginBtn.disabled = true;
  loginBtn.textContent = "Checking...";

  const { data, error } = await sb.from("players").select("*").eq("code", code).maybeSingle();

  loginBtn.disabled = false;
  loginBtn.textContent = "Login";

  if (error || !data) {
    err.textContent = "Invalid code. Please check with the admin.";
    err.style.display = "block";
    return;
  }

  setSession(data);
  goToRole(data.role);
}

loginBtn.addEventListener("click", doLogin);
codeInput.addEventListener("keydown", (e) => { if (e.key === "Enter") doLogin(); });
