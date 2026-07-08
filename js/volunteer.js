const session = requireRole("volunteer");
document.getElementById("playerName").textContent = session.name;

let html5QrCode = null;
let scanning = false;
let busy = false; // prevents overlapping calls while a scan is being processed

// scan cooldown/debounce — the camera library can fire the same
// decoded code many times per second while the QR stays in frame,
// this was the cause of "double scanning". Ignore repeats of the
// same code within COOLDOWN_MS.
const COOLDOWN_MS = 4000;
let lastCode = null;
let lastCodeAt = 0;

let recent = []; // {name, time, awarded}

async function loadCheckpost() {
  if (!session.assigned_checkpost_id) {
    document.getElementById("checkpostName").textContent = "No safe zone assigned — ask admin";
    return;
  }
  const { data } = await sb.from("checkposts").select("*").eq("id", session.assigned_checkpost_id).single();
  document.getElementById("checkpostName").textContent = data ? data.name : "Unknown zone";
}
loadCheckpost();

function renderRecent() {
  document.getElementById("recentList").innerHTML = recent
    .slice(0, 8)
    .map(
      (r) =>
        `<div class="list-item"><span>${r.name}</span><span class="badge ${r.awarded ? "stamped" : "none"}">${
          r.awarded ? "Sticker awarded" : "Already had it"
        }</span></div>`
    )
    .join("") || "Nothing yet.";
}

async function processCode(rawCode) {
  if (busy) return;
  const code = rawCode.trim().toUpperCase();
  if (!code) return;

  const now = Date.now();
  if (code === lastCode && now - lastCodeAt < COOLDOWN_MS) return; // debounce duplicate scan
  lastCode = code;
  lastCodeAt = now;

  if (!session.assigned_checkpost_id) {
    document.getElementById("resultBox").innerHTML = `<span class="error-msg">You have no safe zone assigned. Ask the admin.</span>`;
    return;
  }

  busy = true;
  const resultBox = document.getElementById("resultBox");
  resultBox.innerHTML = `<span class="muted">Looking up ${code}...</span>`;

  const { data: chor, error: lookupErr } = await sb
    .from("players")
    .select("*")
    .eq("code", code)
    .eq("role", "chor")
    .maybeSingle();

  if (lookupErr || !chor) {
    resultBox.innerHTML = `<span class="error-msg">"${code}" is not a valid chor code.</span>`;
    busy = false;
    return;
  }

  const { data, error } = await sb.rpc("collect_sticker", {
    p_chor_id: chor.id,
    p_checkpost_id: session.assigned_checkpost_id,
  });

  if (error) {
    resultBox.innerHTML = `<span class="error-msg">${chor.name}: ${error.message}</span>`;
    busy = false;
    return;
  }

  const r = data[0];
  if (r.newly_awarded) {
    resultBox.innerHTML = `<div class="success-msg" style="font-size:18px;">✅ ${r.chor_name} — sticker awarded! (${r.total_stickers}/${r.total_checkposts})</div>`;
  } else {
    resultBox.innerHTML = `<div class="muted" style="font-size:16px;">ℹ️ ${r.chor_name} already collected this zone's sticker. (${r.total_stickers}/${r.total_checkposts})</div>`;
  }
  if (r.chor_status === "winner") {
    resultBox.innerHTML += `<div class="winner-banner" style="margin-top:10px;">🏆 ${r.chor_name} just completed all zones!</div>`;
  }

  recent.unshift({ name: r.chor_name, time: Date.now(), awarded: r.newly_awarded });
  renderRecent();
  busy = false;
}

async function startScan() {
  if (scanning) return;
  document.getElementById("reader").style.display = "block";
  document.getElementById("startScanBtn").style.display = "none";
  document.getElementById("stopScanBtn").style.display = "block";

  html5QrCode = new Html5Qrcode("reader");
  scanning = true;
  try {
    await html5QrCode.start(
      { facingMode: "environment" },
      { fps: 10, qrbox: 220 },
      (decodedText) => processCode(decodedText)
    );
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

document.getElementById("startScanBtn").addEventListener("click", startScan);
document.getElementById("stopScanBtn").addEventListener("click", stopScan);
document.getElementById("manualAddBtn").addEventListener("click", () => {
  const input = document.getElementById("manualCode");
  if (!input.value.trim()) return;
  processCode(input.value);
  input.value = "";
});
document.getElementById("manualCode").addEventListener("keydown", (e) => {
  if (e.key === "Enter") document.getElementById("manualAddBtn").click();
});
