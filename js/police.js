const session = requireRole("police");
document.getElementById("playerName").textContent = session.name;

let html5QrCode = null;
let scanning = false;
let pendingChor = null;

// debounce — camera can fire the same code repeatedly per second
const COOLDOWN_MS = 4000;
let lastCode = null;
let lastCodeAt = 0;

async function onScanSuccess(decodedText) {
  const code = decodedText.trim().toUpperCase();
  const now = Date.now();
  if (code === lastCode && now - lastCodeAt < COOLDOWN_MS) return;
  lastCode = code;
  lastCodeAt = now;

  await stopScan();
  await lookupChor(code);
}

async function lookupChor(rawCode) {
  const code = rawCode.trim().toUpperCase();
  if (!code) return;

  const { data, error } = await sb.from("players").select("*").eq("code", code).eq("role", "chor").maybeSingle();

  if (error || !data) {
    document.getElementById("resultBox").innerHTML = `<span class="error-msg">"${code}" is not a valid chor code.</span>`;
    return;
  }

  pendingChor = data;
  document.getElementById("confirmCard").style.display = "block";
  document.getElementById("confirmInfo").innerHTML = `
    <div class="list-item"><span>Name</span><span>${data.name}</span></div>
    <div class="list-item"><span>Lifelines</span><span>${"❤️".repeat(data.lifelines)}${"🖤".repeat(3 - data.lifelines)}</span></div>
    <div class="list-item"><span>Status</span><span class="badge ${data.status}">${data.status}</span></div>
  `;
}

async function startScan() {
  if (scanning) return;
  document.getElementById("reader").style.display = "block";
  document.getElementById("startScanBtn").style.display = "none";
  document.getElementById("stopScanBtn").style.display = "block";

  html5QrCode = new Html5Qrcode("reader");
  scanning = true;
  try {
    await html5QrCode.start({ facingMode: "environment" }, { fps: 10, qrbox: 220 }, onScanSuccess);
  } catch (e) {
    document.getElementById("resultBox").textContent = "Camera error: " + e;
  }
}

async function stopScan() {
  if (html5QrCode && scanning) {
    await html5QrCode.stop();
    html5QrCode.clear();
  }
  scanning = false;
  document.getElementById("reader").style.display = "none";
  document.getElementById("startScanBtn").style.display = "block";
  document.getElementById("stopScanBtn").style.display = "none";
}

async function confirmCatch() {
  if (!pendingChor) return;
  document.getElementById("confirmBtn").disabled = true;

  const { data, error } = await sb.rpc("catch_chor", {
    p_chor_id: pendingChor.id,
    p_police_id: session.id,
  });

  document.getElementById("confirmBtn").disabled = false;
  document.getElementById("confirmCard").style.display = "none";

  const resultBox = document.getElementById("resultBox");
  if (error) {
    resultBox.innerHTML = `<span class="error-msg">${error.message}</span>`;
  } else {
    const r = data[0];
    if (r.status === "eliminated") {
      resultBox.innerHTML = `<div class="eliminated-banner">${r.name} used their last life — ELIMINATED</div>`;
    } else {
      resultBox.innerHTML = `<div class="penalty-banner">${r.name} caught! 2 min jail. Lifelines left: ${r.lifelines}</div>`;
    }
  }
  pendingChor = null;
}

document.getElementById("startScanBtn").addEventListener("click", startScan);
document.getElementById("stopScanBtn").addEventListener("click", stopScan);
document.getElementById("confirmBtn").addEventListener("click", confirmCatch);
document.getElementById("cancelBtn").addEventListener("click", () => {
  pendingChor = null;
  document.getElementById("confirmCard").style.display = "none";
});

document.getElementById("manualLookupBtn").addEventListener("click", () => {
  const input = document.getElementById("manualCode");
  if (!input.value.trim()) return;
  lookupChor(input.value);
  input.value = "";
});
document.getElementById("manualCode").addEventListener("keydown", (e) => {
  if (e.key === "Enter") document.getElementById("manualLookupBtn").click();
});
