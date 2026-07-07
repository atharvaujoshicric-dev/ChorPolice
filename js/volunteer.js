const session = requireRole("volunteer");
document.getElementById("playerName").textContent = session.name;

let pending = []; // {id, name, code}
let html5QrCode = null;
let scanning = false;

async function loadCheckpost() {
  if (!session.assigned_checkpost_id) {
    document.getElementById("checkpostName").textContent = "No checkpost assigned — ask admin";
    return;
  }
  const { data } = await sb.from("checkposts").select("*").eq("id", session.assigned_checkpost_id).single();
  document.getElementById("checkpostName").textContent = data ? data.name : "Unknown checkpost";
}
loadCheckpost();

function renderPending() {
  document.getElementById("pendingCount").textContent = pending.length;
  document.getElementById("pendingList").innerHTML = pending
    .map(
      (p, i) =>
        `<span class="pending-chip">${p.name} <button onclick="removePending(${i})">✕</button></span>`
    )
    .join("");
  document.getElementById("finalizeBtn").disabled = pending.length === 0;
}

function removePending(i) {
  pending.splice(i, 1);
  renderPending();
}

async function onScanSuccess(decodedText) {
  const code = decodedText.trim().toUpperCase();
  if (pending.find((p) => p.code === code)) return; // already added

  const { data, error } = await sb.from("players").select("*").eq("code", code).eq("role", "chor").maybeSingle();
  const msg = document.getElementById("scanMsg");

  if (error || !data) {
    msg.textContent = `⚠️ "${code}" is not a valid chor code.`;
    return;
  }
  if (data.status !== "active") {
    msg.textContent = `⚠️ ${data.name} is ${data.status}, cannot check in.`;
    return;
  }

  pending.push({ id: data.id, name: data.name, code: data.code });
  msg.textContent = `✅ Added ${data.name}`;
  renderPending();
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
      onScanSuccess
    );
  } catch (e) {
    document.getElementById("scanMsg").textContent = "Camera error: " + e;
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

async function finalizeGroup() {
  if (!session.assigned_checkpost_id) {
    alert("You have no checkpost assigned. Ask the admin.");
    return;
  }
  const chorIds = pending.map((p) => p.id);
  document.getElementById("finalizeBtn").disabled = true;
  document.getElementById("finalizeBtn").textContent = "Processing...";

  const { data, error } = await sb.rpc("finalize_checkpost_group", {
    p_checkpost_id: session.assigned_checkpost_id,
    p_chor_ids: chorIds,
  });

  document.getElementById("finalizeBtn").textContent = "Finalize Group";

  const resultBox = document.getElementById("resultBox");
  if (error) {
    resultBox.innerHTML = `<span class="error-msg">${error.message}</span>`;
  } else {
    resultBox.innerHTML = data
      .map((r) => `<div class="list-item"><span>${r.name}</span><span class="badge ${r.status}">${r.status}</span></div>`)
      .join("");
  }

  pending = [];
  renderPending();
}

document.getElementById("startScanBtn").addEventListener("click", startScan);
document.getElementById("stopScanBtn").addEventListener("click", stopScan);
document.getElementById("finalizeBtn").addEventListener("click", finalizeGroup);
document.getElementById("clearBtn").addEventListener("click", () => { pending = []; renderPending(); });
