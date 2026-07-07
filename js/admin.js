const session = requireRole("admin");

// ---------- tabs ----------
document.querySelectorAll(".tab-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById("tab-" + btn.dataset.tab).classList.add("active");
  });
});

// ---------- overview ----------
async function loadOverview() {
  const { data } = await sb.from("chor_progress").select("*").order("name");
  document.getElementById("chorTable").innerHTML = (data || [])
    .map(
      (c) => `<tr>
        <td>${c.name}</td>
        <td>${c.code}</td>
        <td><span class="badge ${c.status}">${c.status}</span></td>
        <td>${"❤️".repeat(c.lifelines)}${"🖤".repeat(3 - c.lifelines)}</td>
        <td>${c.stamps} / ${c.total_checkposts}</td>
      </tr>`
    )
    .join("");
}

// ---------- players ----------
async function loadCheckpostOptions() {
  const { data } = await sb.from("checkposts").select("*").order("order_no");
  const sel = document.getElementById("newCheckpost");
  sel.innerHTML = (data || []).map((c) => `<option value="${c.id}">${c.name}</option>`).join("");
}

document.getElementById("newRole").addEventListener("change", (e) => {
  document.getElementById("newCheckpost").style.display = e.target.value === "volunteer" ? "block" : "none";
});

document.getElementById("addPlayerBtn").addEventListener("click", async () => {
  const name = document.getElementById("newName").value.trim();
  const role = document.getElementById("newRole").value;
  const checkpostId = document.getElementById("newCheckpost").value || null;
  const resultEl = document.getElementById("newPlayerResult");

  if (!name) { resultEl.innerHTML = `<span class="error-msg">Enter a name</span>`; return; }

  const code = genCode();
  const { data: settings } = await sb.from("game_settings").select("lifelines_default").eq("id", 1).single();

  const insertObj = {
    code,
    name,
    role,
    lifelines: role === "chor" ? (settings?.lifelines_default || 3) : 0,
    assigned_checkpost_id: role === "volunteer" ? checkpostId : null,
  };

  const { data, error } = await sb.from("players").insert(insertObj).select().single();

  if (error) {
    resultEl.innerHTML = `<span class="error-msg">${error.message}</span>`;
  } else {
    resultEl.innerHTML = `<div class="success-msg">Added ${data.name} — code: <b>${data.code}</b></div>`;
    document.getElementById("newName").value = "";
  }
  loadPlayers();
});

async function loadPlayers() {
  const { data } = await sb.from("players").select("*, checkposts(name)").order("role").order("name");
  document.getElementById("playersTable").innerHTML = (data || [])
    .filter((p) => p.role !== "admin")
    .map(
      (p) => `<tr>
        <td>${p.name}</td>
        <td>${p.role}</td>
        <td>${p.code}</td>
        <td>${p.checkposts ? p.checkposts.name : "-"}</td>
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
  if (!name) return;
  await sb.from("checkposts").insert({ name, order_no: order });
  document.getElementById("newCheckpostName").value = "";
  document.getElementById("newCheckpostOrder").value = "";
  loadCheckposts();
  loadCheckpostOptions();
});

async function loadCheckposts() {
  const { data } = await sb.from("checkposts").select("*").order("order_no");
  document.getElementById("checkpostsTable").innerHTML = (data || [])
    .map(
      (c) => `<tr>
        <td>${c.order_no}</td>
        <td>${c.name}</td>
        <td><button class="secondary" style="width:auto;padding:4px 8px;" onclick="deleteCheckpost('${c.id}')">Delete</button></td>
      </tr>`
    )
    .join("");
}

async function deleteCheckpost(id) {
  if (!confirm("Delete this checkpost? Related visits will also be removed.")) return;
  await sb.from("checkposts").delete().eq("id", id);
  loadCheckposts();
  loadCheckpostOptions();
}

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
        <td>${c.resulted_in_elimination ? "Eliminated" : "Penalty"}</td>
      </tr>`
    )
    .join("");

  const { data: visits } = await sb
    .from("checkpost_visits")
    .select("*, chor:chor_id(name), checkposts(name)")
    .order("visited_at", { ascending: false })
    .limit(100);

  document.getElementById("visitsTable").innerHTML = (visits || [])
    .map(
      (v) => `<tr>
        <td>${new Date(v.visited_at).toLocaleTimeString()}</td>
        <td>${v.chor?.name || "-"}</td>
        <td>${v.checkposts?.name || "-"}</td>
        <td>${v.group_size}</td>
        <td><span class="badge ${v.status}">${v.status}</span></td>
      </tr>`
    )
    .join("");
}

// ---------- settings ----------
async function loadSettings() {
  const { data } = await sb.from("game_settings").select("*").eq("id", 1).single();
  if (!data) return;
  document.getElementById("setGroupSize").value = data.group_size_required;
  document.getElementById("setPenaltySeconds").value = data.penalty_seconds;
  document.getElementById("setLifelines").value = data.lifelines_default;
}

document.getElementById("saveSettingsBtn").addEventListener("click", async () => {
  const group_size_required = parseInt(document.getElementById("setGroupSize").value) || 10;
  const penalty_seconds = parseInt(document.getElementById("setPenaltySeconds").value) || 120;
  const lifelines_default = parseInt(document.getElementById("setLifelines").value) || 3;

  const { error } = await sb
    .from("game_settings")
    .update({ group_size_required, penalty_seconds, lifelines_default })
    .eq("id", 1);

  const msg = document.getElementById("settingsMsg");
  msg.innerHTML = error
    ? `<span class="error-msg">${error.message}</span>`
    : `<span class="success-msg">Saved!</span>`;
});

document.getElementById("resetGameBtn").addEventListener("click", async () => {
  if (!confirm("This wipes ALL stamps, catches, and resets lifelines. Continue?")) return;
  await sb.rpc("reset_game");
  loadOverview();
  loadLogs();
});

// ---------- init ----------
function loadAll() {
  loadOverview();
  loadPlayers();
  loadCheckposts();
  loadCheckpostOptions();
  loadLogs();
  loadSettings();
}
loadAll();
setInterval(() => { loadOverview(); loadLogs(); }, 6000);
