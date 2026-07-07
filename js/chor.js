const session = requireRole("chor");
let penaltyTimer = null;

document.getElementById("playerName").textContent = session.name;
document.getElementById("codeText").textContent = session.code;
QRCode.toCanvas(document.getElementById("qrCanvas"), session.code, { width: 200, margin: 1 });

async function refresh() {
  const { data: player } = await sb.from("players").select("*").eq("id", session.id).single();
  if (!player) return;

  setSession(player);
  renderBanner(player);
  renderHearts(player.lifelines);
  await renderCheckposts(player.id);
}

function renderBanner(player) {
  const el = document.getElementById("statusBanner");
  const now = Date.now();
  const penaltyUntil = player.penalty_until ? new Date(player.penalty_until).getTime() : 0;

  if (penaltyTimer) clearInterval(penaltyTimer);

  if (player.status === "eliminated") {
    el.innerHTML = `<div class="eliminated-banner">❌ You've been eliminated</div>`;
    return;
  }
  if (player.status === "winner") {
    el.innerHTML = `<div class="winner-banner">🏆 You won the game!</div>`;
    return;
  }
  if (penaltyUntil > now) {
    const tick = () => {
      const left = penaltyUntil - Date.now();
      if (left <= 0) {
        el.innerHTML = "";
        clearInterval(penaltyTimer);
        refresh();
        return;
      }
      el.innerHTML = `<div class="penalty-banner">🚔 Caught! Wait here: ${fmtCountdown(left)}</div>`;
    };
    tick();
    penaltyTimer = setInterval(tick, 1000);
    return;
  }
  el.innerHTML = "";
}

function renderHearts(lifelines) {
  const total = 3;
  let out = "";
  for (let i = 0; i < total; i++) out += i < lifelines ? "❤️" : "🖤";
  document.getElementById("hearts").textContent = out;
}

async function renderCheckposts(chorId) {
  const { data: checkposts } = await sb.from("checkposts").select("*").order("order_no");
  const { data: visits } = await sb.from("checkpost_visits").select("*").eq("chor_id", chorId);

  const visitMap = {};
  (visits || []).forEach((v) => (visitMap[v.checkpost_id] = v.status));

  const list = checkposts || [];
  const stamped = list.filter((c) => visitMap[c.id] === "stamped").length;
  document.getElementById("progressCount").textContent = `${stamped} / ${list.length} stamped`;

  document.getElementById("checkpostList").innerHTML = list
    .map((c) => {
      const st = visitMap[c.id] || "none";
      const label = { safe: "Safe (no stamp)", stamped: "Stamped ✅", vulnerable: "Visited (no stamp)", none: "Not visited" }[st];
      return `<div class="list-item"><span>${c.name}</span><span class="badge ${st}">${label}</span></div>`;
    })
    .join("");
}

refresh();
setInterval(refresh, 4000);
