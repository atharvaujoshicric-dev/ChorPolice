const session = requireRole("chor");
let penaltyTimer = null;

document.getElementById("playerName").textContent = session.name;
document.getElementById("codeText").textContent = session.code;

const qrImg = document.getElementById("qrImg");
qrImg.src = `https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=${encodeURIComponent(session.code)}`;
qrImg.onerror = () => {
  document.querySelector(".qr-box").innerHTML =
    '<span style="color:#900;">Could not load QR image — your code above still works, volunteers/police can type it in manually.</span>';
};

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
    el.innerHTML = `<div class="winner-banner">🏆 You collected all 10 stickers — you won!</div>`;
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
      el.innerHTML = `<div class="penalty-banner">🚔 In jail: ${fmtCountdown(left)}</div>`;
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
  const { data: stickers } = await sb.from("stickers").select("*").eq("chor_id", chorId);

  const collected = new Set((stickers || []).map((s) => s.checkpost_id));
  const list = checkposts || [];
  document.getElementById("progressCount").textContent = `${collected.size} / ${list.length} stickers`;

  document.getElementById("checkpostList").innerHTML = list
    .map((c) => {
      const got = collected.has(c.id);
      return `<div class="list-item"><span>${c.name}</span><span class="badge ${got ? "stamped" : "none"}">${
        got ? "Collected ✅" : "Not visited"
      }</span></div>`;
    })
    .join("");
}

refresh();
setInterval(refresh, 4000);
