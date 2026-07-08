const session = requireRole("admin");
let currentPlayerFilter = "chor";
let chorDataById = {}; // cache of latest chor_progress rows, keyed by chor_id

// ---------- passcode helpers ----------
function getPasscode() {
  return localStorage.getItem("cp_admin_passcode") || "";
}
function setPasscode(v) {
  localStorage.setItem("cp_admin_passcode", v);
}

function checkPasscodeWarning() {
  const el = document.getElementById("passcodeWarning");
  if (!getPasscode()) {
    el.innerHTML = `<div class="penalty-banner" style="font-size:15px;">⚠️ No admin passcode saved on this device yet. Go to Settings → set it (default is <b>change-this-now</b>, then change it) or every override action below will fail.</div>`;
  } else {
    el.innerHTML = "";
  }
}
checkPasscodeWarning();

// ---------- tabs ----------
document.querySelectorAll(".tab-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById("tab-" + btn.dataset.tab).classList.add("active");
    if (btn.dataset.tab === "override") loadOverrideOptions();
  });
});

document.querySelectorAll(".pfilter-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".pfilter-btn").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    currentPlayerFilter = btn.dataset.role;
    loadPlayers();
  });
});

// ---------- overview (card-based live status) ----------
async function loadOverview() {
  const { data, error } = await sb.from("chor_progress").select("*").order("name");

  if (error) {
    document.getElementById("chorCards").innerHTML = `<div class="card"><span class="error-msg">${error.message}</span></div>`;
    return;
  }

  const list = data || [];
  chorDataById = {};
  list.forEach((c) => (chorDataById[c.chor_id] = c));

  const active = list.filter((c) => c.status === "active").length;
  const eliminated = list.filter((c) => c.status === "eliminated").length;
  const winners = list.filter((c) => c.status === "winner").length;
  document.getElementById("overviewCounts").textContent =
    `(${list.length} total — ${active} active, ${eliminated} eliminated, ${winners} won)`;

  document.getElementById("chorCards").innerHTML = list
    .map((c) => {
      const isSafe = c.protected_until && new Date(c.protected_until).getTime() > Date.now();
      const isJailed = c.penalty_until && new Date(c.penalty_until).getTime() > Date.now();
      return `<div class="chor-card">
        <div class="chor-card-head">
          <div>
            <div class="chor-name">${c.name}</div>
            <div class="chor-code muted">${c.code} · ${c.stickers}/${c.total_checkposts} stickers</div>
          </div>
          <div class="chor-badges">
            <span class="badge ${c.status}">${c.status}</span>
            ${isSafe ? '<span class="badge safe">🛡️ safe</span>' : ""}
            ${isJailed ? '<span class="badge vulnerable">🚔 jailed</span>' : ""}
          </div>
        </div>
        <div class="lifelines-control">
          <button class="secondary" onclick="adjustLifelines('${c.chor_id}', -1)">−</button>
          <span class="hearts">${"❤️".repeat(c.lifelines)}${"🖤".repeat(3 - c.lifelines)}</span>
          <button class="secondary" onclick="adjustLifelines('${c.chor_id}', 1)">+</button>
        </div>
        <div class="chor-card-actions">
          <button class="secondary" onclick="adminClearJail('${c.chor_id}')">Release Jail</button>
          <button class="secondary" onclick="adminFullRestore('${c.chor_id}')">Full Restore</button>
          <button class="danger" onclick="adminEliminate('${c.chor_id}')">Eliminate</button>
        </div>
      </div>`;
    })
    .join("") || `<div class="card muted">No chors added yet.</div>`;
}

async function adjustLifelines(chorId, delta) {
  const current = chorDataById[chorId]?.lifelines ?? 0;
  const next = current + delta;
  const { error } = await sb.rpc("admin_set_lifelines", {
    p_admin_passcode: getPasscode(),
    p_chor_id: chorId,
    p_lifelines: next,
  });
  if (error) alert(error.message);
  loadOverview();
}

async function adminFullRestore(chorId) {
  const { error } = await sb.rpc("admin_set_lifelines", {
    p_admin_passcode: getPasscode(),
    p_chor_id: chorId,
    p_lifelines: 999, // clamped server-side to the configured max
  });
  if (error) { alert(error.message); return; }
  await sb.rpc("admin_clear_jail", { p_admin_passcode: getPasscode(), p_chor_id: chorId });
  loadOverview();
}

async function adminClearJail(chorId) {
  const { error } = await sb.rpc("admin_clear_jail", { p_admin_passcode: getPasscode(), p_chor_id: chorId });
  if (error) alert(error.message);
  loadOverview();
}

async function adminEliminate(chorId) {
  if (!confirm("Eliminate this chor?")) return;
  const { error } = await sb.rpc("admin_eliminate_chor", { p_admin_passcode: getPasscode(), p_chor_id: chorId });
  if (error) alert(error.message);
  loadOverview();
}

// ---------- bulk add players ----------
async function loadCheckpostOptions(selectEl) {
  const { data } = await sb.from("checkposts").select("*").order("order_no");
  selectEl.innerHTML = (data || []).map((c) => `<option value="${c.id}">${c.name}</option>`).join("");
}

document.getElementById("bulkRole").addEventListener("change", (e) => {
  document.getElementById("bulkCheckpost").style.display = e.target.value === "volunteer" ? "block" : "none";
});

document.getElementById("bulkAddBtn").addEventListener("click", async () => {
  const names = document
    .getElementById("bulkNames")
    .value.split("\n")
    .map((n) => n.trim())
    .filter(Boolean);
  const role = document.getElementById("bulkRole").value;
  const checkpostId = document.getElementById("bulkCheckpost").value || null;
  const resultEl = document.getElementById("bulkResult");

  if (names.length === 0) {
    resultEl.innerHTML = `<span class="error-msg">Enter at least one name</span>`;
    return;
  }

  const { data: settings } = await sb.from("game_settings").select("lifelines_default").eq("id", 1).single();
  const lifelinesDefault = settings?.lifelines_default || 3;

  const { data: existingPlayers } = await sb.from("players").select("code");
  const usedCodes = new Set((existingPlayers || []).map((p) => p.code));

  const rows = names.map((name) => ({
    code: codeFromName(name, usedCodes),
    name,
    role,
    lifelines: role === "chor" ? lifelinesDefault : 0,
    assigned_checkpost_id: role === "volunteer" ? checkpostId : null,
  }));

  const btn = document.getElementById("bulkAddBtn");
  btn.disabled = true;
  btn.textContent = `Adding ${rows.length}...`;

  const { data, error } = await sb.from("players").insert(rows).select();

  btn.disabled = false;
  btn.textContent = "Generate Codes & Add All";

  if (error) {
    resultEl.innerHTML = `<span class="error-msg">${error.message}</span>`;
  } else {
    resultEl.innerHTML = `<div class="success-msg">Added ${data.length} players.</div>` +
      `<table><thead><tr><th>Name</th><th>Code</th></tr></thead><tbody>` +
      data.map((p) => `<tr><td>${p.name}</td><td>${p.code}</td></tr>`).join("") +
      `</tbody></table>`;
    document.getElementById("bulkNames").value = "";
  }
  loadPlayers();
});

async function loadPlayers() {
  const errEl = document.getElementById("playersError");
  const emptyEl = document.getElementById("playersEmpty");
  errEl.innerHTML = "";

  const { data: players, error } = await sb
    .from("players")
    .select("*")
    .eq("role", currentPlayerFilter)
    .order("name");

  if (error) {
    errEl.innerHTML = `<span class="error-msg">Could not load players: ${error.message}</span>`;
    document.getElementById("playersTable").innerHTML = "";
    emptyEl.style.display = "none";
    return;
  }

  const list = players || [];

  if (list.length === 0) {
    document.getElementById("playersTable").innerHTML = "";
    emptyEl.style.display = "block";
    return;
  }
  emptyEl.style.display = "none";

  const { data: checkposts } = await sb.from("checkposts").select("id, name");
  const zoneNameById = {};
  (checkposts || []).forEach((c) => (zoneNameById[c.id] = c.name));

  document.getElementById("playersTable").innerHTML = list
    .map(
      (p) => `<tr>
        <td>${p.name}</td>
        <td>${p.code}</td>
        <td>${p.assigned_checkpost_id ? (zoneNameById[p.assigned_checkpost_id] || "—") : "-"}</td>
        <td><button class="secondary" style="width:auto;padding:4px 8px;" onclick="deletePlayer('${p.id}')">Delete</button></td>
      </tr>`
    )
    .join("");
}

async function deletePlayer(id) {
  if (!confirm("Delete this player?")) return;
  await sb.from("players").delete().eq("id", id);
  loadPlayers();
  loadOverview();
}

// ---------- checkposts ----------
document.getElementById("addCheckpostBtn").addEventListener("click", async () => {
  const name = document.getElementById("newCheckpostName").value.trim();
  const order = parseInt(document.getElementById("newCheckpostOrder").value) || 0;
  const hint = document.getElementById("newCheckpostHint").value.trim() || null;
  const voucher = document.getElementById("newCheckpostVoucher").value.trim() || null;
  if (!name) return;
  await sb.from("checkposts").insert({ name, order_no: order, hint_text: hint, voucher_text: voucher });
  document.getElementById("newCheckpostName").value = "";
  document.getElementById("newCheckpostOrder").value = "";
  document.getElementById("newCheckpostHint").value = "";
  document.getElementById("newCheckpostVoucher").value = "";
  loadCheckposts();
  loadCheckpostOptions(document.getElementById("bulkCheckpost"));
});

async function loadCheckposts() {
  const { data } = await sb.from("checkposts").select("*").order("order_no");
  document.getElementById("checkpostsList").innerHTML = (data || [])
    .map(
      (c) => `<div class="zone-card">
        <div class="zone-card-head">
          <div>
            <div class="zname">#${c.order_no} — ${c.name}</div>
            <div class="zone-card-meta">${c.hint_text ? "🔎 " + c.hint_text : "No hint set"}${c.voucher_text ? " · 🎁 " + c.voucher_text : ""}</div>
          </div>
          <div class="zone-card-actions">
            <button class="secondary" onclick="toggleZoneEdit('${c.id}')">Edit</button>
            <button class="danger" onclick="deleteCheckpost('${c.id}')">Delete</button>
          </div>
        </div>
        <div class="zone-edit-panel" id="zedit-${c.id}">
          <input id="zname-${c.id}" value="${c.name.replace(/"/g, '&quot;')}" placeholder="Name" />
          <input id="zorder-${c.id}" type="number" value="${c.order_no}" placeholder="Order" />
          <textarea id="zhint-${c.id}" rows="2" placeholder="Hint">${c.hint_text || ""}</textarea>
          <input id="zvoucher-${c.id}" value="${c.voucher_text ? c.voucher_text.replace(/"/g, '&quot;') : ""}" placeholder="Voucher / coupon" />
          <button class="success" onclick="saveZoneEdit('${c.id}')">Save</button>
        </div>
      </div>`
    )
    .join("") || `<p class="muted">No Safe Zones yet — add one above.</p>`;
}

function toggleZoneEdit(id) {
  document.getElementById("zedit-" + id).classList.toggle("open");
}

async function saveZoneEdit(id) {
  const name = document.getElementById(`zname-${id}`).value.trim();
  const order_no = parseInt(document.getElementById(`zorder-${id}`).value) || 0;
  const hint_text = document.getElementById(`zhint-${id}`).value.trim() || null;
  const voucher_text = document.getElementById(`zvoucher-${id}`).value.trim() || null;
  const { error } = await sb.from("checkposts").update({ name, order_no, hint_text, voucher_text }).eq("id", id);
  if (error) alert(error.message);
  loadCheckposts();
}

async function deleteCheckpost(id) {
  if (!confirm("Delete this Safe Zone? Related stickers will also be removed.")) return;
  await sb.from("checkposts").delete().eq("id", id);
  loadCheckposts();
  loadCheckpostOptions(document.getElementById("bulkCheckpost"));
}

// ---------- manual override ----------
async function loadOverrideOptions() {
  const { data: chors } = await sb.from("players").select("id, name, code").eq("role", "chor").order("name");
  const chorOptions = (chors || []).map((c) => `<option value="${c.id}">${c.name} (${c.code})</option>`).join("");
  document.getElementById("overrideCatchChor").innerHTML = chorOptions;
  document.getElementById("overrideStickerChor").innerHTML = chorOptions;

  const { data: zones } = await sb.from("checkposts").select("id, name").order("order_no");
  document.getElementById("overrideStickerZone").innerHTML = (zones || [])
    .map((z) => `<option value="${z.id}">${z.name}</option>`)
    .join("");
}

document.getElementById("overrideCatchBtn").addEventListener("click", async () => {
  const chorId = document.getElementById("overrideCatchChor").value;
  if (!chorId) return;
  if (!confirm("Manually catch this chor? This is logged like any other catch.")) return;
  const { data, error } = await sb.rpc("admin_manual_catch", { p_admin_passcode: getPasscode(), p_chor_id: chorId });
  const msg = document.getElementById("overrideCatchMsg");
  msg.innerHTML = error ? `<span class="error-msg">${error.message}</span>` : `<span class="success-msg">${data[0].name} caught manually.</span>`;
  loadOverview();
});

document.getElementById("overrideStickerBtn").addEventListener("click", async () => {
  const chorId = document.getElementById("overrideStickerChor").value;
  const zoneId = document.getElementById("overrideStickerZone").value;
  if (!chorId || !zoneId) return;
  const { data, error } = await sb.rpc("admin_manual_award_sticker", {
    p_admin_passcode: getPasscode(),
    p_chor_id: chorId,
    p_checkpost_id: zoneId,
  });
  const msg = document.getElementById("overrideStickerMsg");
  msg.innerHTML = error
    ? `<span class="error-msg">${error.message}</span>`
    : `<span class="success-msg">${data[0].newly_awarded ? "Sticker awarded" : "Already had this sticker"} for ${data[0].chor_name}.</span>`;
  loadOverview();
});

// ---------- print cards ----------
document.getElementById("loadPrintBtn").addEventListener("click", async () => {
  const role = document.getElementById("printRole").value;
  const { data } = await sb.from("players").select("*").eq("role", role).order("name");

  document.getElementById("printArea").innerHTML = (data || [])
    .map(
      (p) => `<div class="print-card">
        <img width="140" height="140" src="https://api.qrserver.com/v1/create-qr-code/?size=140x140&data=${encodeURIComponent(p.code)}" />
        <div class="pname">${p.name}</div>
        <div class="pcode">${p.code}</div>
        <div style="font-size:11px;color:#555;">${p.role}</div>
      </div>`
    )
    .join("") || "<p>No players in this role yet.</p>";
});

document.getElementById("doPrintBtn").addEventListener("click", () => window.print());

// ---------- logs ----------
async function loadLogs() {
  const { data: catches } = await sb
    .from("catches")
    .select("*, chor:chor_id(name), police:police_id(name)")
    .order("caught_at", { ascending: false })
    .limit(100);

  document.getElementById("catchesTable").innerHTML = (catches || [])
    .map(
      (c) => `<tr>
        <td>${new Date(c.caught_at).toLocaleTimeString()}</td>
        <td>${c.chor?.name || "-"}</td>
        <td>${c.police?.name || "-"}</td>
        <td>${c.resulted_in_elimination ? "Eliminated" : "Jailed"}</td>
        <td><button class="secondary" style="width:auto;padding:4px 8px;" onclick="undoCatch('${c.id}')">Undo</button></td>
      </tr>`
    )
    .join("");

  const { data: stickers } = await sb
    .from("stickers")
    .select("*, chor:chor_id(name), checkposts(name)")
    .order("collected_at", { ascending: false })
    .limit(150);

  document.getElementById("visitsTable").innerHTML = (stickers || [])
    .map(
      (v) => `<tr>
        <td>${new Date(v.collected_at).toLocaleTimeString()}</td>
        <td>${v.chor?.name || "-"}</td>
        <td>${v.checkposts?.name || "-"}</td>
      </tr>`
    )
    .join("");
}

async function undoCatch(catchId) {
  const { data, error } = await sb.rpc("admin_undo_catch", { p_admin_passcode: getPasscode(), p_catch_id: catchId });
  if (error) { alert(error.message); return; }
  alert(`Undone — ${data[0].chor_name} is back in the game.`);
  loadLogs();
  loadOverview();
}

// ---------- settings: passcode ----------
document.getElementById("adminPasscodeInput").value = getPasscode();

document.getElementById("savePasscodeBtn").addEventListener("click", () => {
  setPasscode(document.getElementById("adminPasscodeInput").value.trim());
  document.getElementById("passcodeMsg").innerHTML = `<span class="success-msg">Saved on this device.</span>`;
  checkPasscodeWarning();
});

document.getElementById("changePasscodeBtn").addEventListener("click", async () => {
  const oldP = getPasscode();
  const newP = document.getElementById("newPasscodeInput").value.trim();
  if (!newP) return;
  const { error } = await sb.rpc("admin_set_passcode", { p_old_passcode: oldP, p_new_passcode: newP });
  const msg = document.getElementById("passcodeMsg");
  if (error) {
    msg.innerHTML = `<span class="error-msg">${error.message}</span>`;
  } else {
    setPasscode(newP);
    document.getElementById("adminPasscodeInput").value = newP;
    document.getElementById("newPasscodeInput").value = "";
    msg.innerHTML = `<span class="success-msg">Passcode changed and saved on this device.</span>`;
    checkPasscodeWarning();
  }
});

// ---------- settings: game settings ----------
async function loadSettings() {
  const { data } = await sb.from("game_settings").select("*").eq("id", 1).single();
  if (!data) return;
  document.getElementById("setPenaltySeconds").value = data.penalty_seconds;
  document.getElementById("setLifelines").value = data.lifelines_default;
  document.getElementById("setSafeGrace").value = data.safe_zone_grace_seconds;
}

document.getElementById("saveSettingsBtn").addEventListener("click", async () => {
  const penalty_seconds = parseInt(document.getElementById("setPenaltySeconds").value) || 120;
  const lifelines_default = parseInt(document.getElementById("setLifelines").value) || 3;
  const safe_zone_grace_seconds = parseInt(document.getElementById("setSafeGrace").value) || 90;

  const { error } = await sb
    .from("game_settings")
    .update({ penalty_seconds, lifelines_default, safe_zone_grace_seconds })
    .eq("id", 1);

  const msg = document.getElementById("settingsMsg");
  msg.innerHTML = error
    ? `<span class="error-msg">${error.message}</span>`
    : `<span class="success-msg">Saved!</span>`;
});

document.getElementById("resetGameBtn").addEventListener("click", async () => {
  if (!confirm("This wipes ALL stickers, catches, and resets lifelines. Continue?")) return;
  const { error } = await sb.rpc("reset_game", { p_admin_passcode: getPasscode() });
  if (error) alert(error.message);
  loadOverview();
  loadLogs();
});

document.getElementById("fullWipeBtn").addEventListener("click", async () => {
  const sure = prompt('This deletes EVERY player (except admin) and EVERY Safe Zone. Type "DELETE" to confirm.');
  if (sure !== "DELETE") return;
  const { error } = await sb.rpc("admin_full_wipe", { p_admin_passcode: getPasscode() });
  if (error) {
    alert(error.message);
  } else {
    alert("Everything wiped. Start adding fresh Safe Zones and players.");
    loadAll();
  }
});

// ---------- init ----------
function loadAll() {
  loadOverview();
  loadPlayers();
  loadCheckposts();
  loadCheckpostOptions(document.getElementById("bulkCheckpost"));
  loadLogs();
  loadSettings();
}
loadAll();
setInterval(() => { loadOverview(); loadLogs(); }, 6000);
