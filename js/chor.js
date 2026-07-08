const session = requireRole("chor");
let penaltyTimer = null;
let protectedTimer = null;

document.getElementById("playerName").textContent = session.name;
document.getElementById("codeText").textContent = session.code;

const qrImg = document.getElementById("qrImg");
qrImg.src = `https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=${encodeURIComponent(session.code)}`;
qrImg.onerror = () => {
  document.querySelector(".qr-box").innerHTML =
    '<span style="color:#900;">Could not load QR image — your code above still works, volunteers/police can type it in manually.</span>';
};

const RING_CIRCUMFERENCE = 2 * Math.PI * 52;
const progressArc = document.getElementById("progressArc");
progressArc.style.strokeDasharray = `${RING_CIRCUMFERENCE}`;
progressArc.style.strokeDashoffset = `${RING_CIRCUMFERENCE}`;
progressArc.style.transition = "stroke-dashoffset 0.6s ease";

async function refresh() {
  const { data: player } = await sb.from("players").select("*").eq("id", session.id).single();
  if (!player) return;

  setSession(player);
  renderBanner(player);
  renderHearts(player.lifelines);
  await renderCheckposts(player.id);
  await renderHint(player);
  await renderVouchers(player.id);
}

function renderBanner(player) {
  const el = document.getElementById("statusBanner");
  const now = Date.now();
  const penaltyUntil = player.penalty_until ? new Date(player.penalty_until).getTime() : 0;
  const protectedUntil = player.protected_until ? new Date(player.protected_until).getTime() : 0;

  if (penaltyTimer) clearInterval(penaltyTimer);
  if (protectedTimer) clearInterval(protectedTimer);

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
  if (protectedUntil > now) {
    const tick = () => {
      const left = protectedUntil - Date.now();
      if (left <= 0) {
        el.innerHTML = "";
        clearInterval(protectedTimer);
        return;
      }
      el.innerHTML = `<div class="safe-ticket-banner">🛡️ Safe Ticket active: ${fmtCountdown(left)}</div>`;
    };
    tick();
    protectedTimer = setInterval(tick, 1000);
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

  const collectedIds = new Set((stickers || []).map((s) => s.checkpost_id));
  const list = checkposts || [];
  const collected = list.filter((c) => collectedIds.has(c.id));
  const lockedCount = list.length - collected.length;

  const offset = list.length > 0
    ? RING_CIRCUMFERENCE * (1 - collected.length / list.length)
    : RING_CIRCUMFERENCE;
  progressArc.style.strokeDashoffset = `${offset}`;
  document.getElementById("progressLabel").textContent = `${collected.length}/${list.length}`;

  let html = collected
    .map((c) => `<div class="list-item"><span>✅ ${c.name}</span><span class="badge stamped">Collected</span></div>`)
    .join("");

  if (lockedCount > 0) {
    html += `<div class="locked-row">${"🔒".repeat(Math.min(lockedCount, 10))} ${lockedCount} zone${lockedCount === 1 ? "" : "s"} still to find</div>`;
  }

  document.getElementById("checkpostList").innerHTML = html || `<p class="muted">No zones collected yet — go find your first Safe Zone!</p>`;
}

async function renderHint(player) {
  const el = document.getElementById("hintText");

  if (player.status === "winner") {
    el.innerHTML = `🏆 You've found every zone — passport complete!`;
    return;
  }

  if (!player.next_hint_checkpost_id) {
    const { count } = await sb
      .from("stickers")
      .select("id", { count: "exact", head: true })
      .eq("chor_id", player.id);

    if (!count) {
      el.innerHTML = `Head out and find your first Safe Zone to get your first clue!`;
    } else {
      el.innerHTML = `No more clues needed — you're almost done, go finish your passport!`;
    }
    return;
  }

  const { data: cp } = await sb
    .from("checkposts")
    .select("hint_text")
    .eq("id", player.next_hint_checkpost_id)
    .maybeSingle();

  el.innerHTML = cp?.hint_text
    ? cp.hint_text
    : `A clue hasn't been written for your next zone yet — ask a volunteer for a pointer!`;
}

async function renderVouchers(chorId) {
  const { data } = await sb
    .from("stickers")
    .select("*, checkposts(name, voucher_text)")
    .eq("chor_id", chorId);

  const vouchers = (data || []).filter((s) => s.checkposts?.voucher_text);
  const card = document.getElementById("voucherCard");

  if (vouchers.length === 0) {
    card.style.display = "none";
    return;
  }

  card.style.display = "block";
  document.getElementById("voucherList").innerHTML = vouchers
    .map(
      (v) => `<div class="voucher-chip" style="margin-bottom:8px;">
        <div style="font-weight:700;">${v.checkposts.name}</div>
        <div>${v.checkposts.voucher_text}</div>
      </div>`
    )
    .join("");
}

refresh();
setInterval(refresh, 4000);
