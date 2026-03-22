#!/usr/bin/env python3
"""
PC Lab Watch — Dashboard Server v3.0
Flask app that:
  - Serves the web dashboard at /
  - Accepts HTTP POST reports at /api/report  (fallback for agents that can't mount share)
  - Exposes /api/machines and /api/machine/<hostname> REST endpoints
  - Reads/writes a local SQLite DB (lab_watch.db)

Run:
    pip install flask
    python3 lab_watch_server.py

    # Custom DB path / port / bind:
    DB_PATH=/data/lab_watch.db PORT=5000 BIND=0.0.0.0 python3 lab_watch_server.py
"""

import os
import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, request, jsonify, render_template_string, abort

# ── Config ────────────────────────────────────────────────────
DB_PATH  = os.environ.get("DB_PATH",  "lab_watch.db")
PORT     = int(os.environ.get("PORT",  5000))
BIND     = os.environ.get("BIND",     "0.0.0.0")
# How many recent reports to keep per host (older ones are pruned)
KEEP_PER_HOST = int(os.environ.get("KEEP_PER_HOST", 200))

app = Flask(__name__)
_db_lock = threading.Lock()

# ── DB helpers ────────────────────────────────────────────────
def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=10, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")   # safe for concurrent NFS/local writers
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn

def init_db():
    with get_db() as c:
        c.executescript("""
            CREATE TABLE IF NOT EXISTS reports (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                hostname     TEXT    NOT NULL,
                collected_at TEXT    NOT NULL,
                usability    TEXT    NOT NULL,
                payload      TEXT    NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_host_time ON reports(hostname, collected_at);
        """)

def prune_old(conn, hostname):
    """Keep only the N most recent reports per host."""
    conn.execute("""
        DELETE FROM reports WHERE hostname = ? AND id NOT IN (
            SELECT id FROM reports WHERE hostname = ?
            ORDER BY collected_at DESC LIMIT ?
        )
    """, (hostname, hostname, KEEP_PER_HOST))

# ── REST API ──────────────────────────────────────────────────
@app.route("/api/report", methods=["POST"])
def receive_report():
    """Accepts JSON payload POSTed by agents as HTTP fallback."""
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            abort(400, "Invalid JSON")
        hostname     = data.get("hostname", "unknown")
        collected_at = data.get("collected_at", datetime.now(timezone.utc).isoformat())
        usability    = data.get("usability", "UNKNOWN")
        payload      = json.dumps(data)
        with _db_lock:
            with get_db() as conn:
                conn.execute(
                    "INSERT INTO reports (hostname, collected_at, usability, payload) VALUES (?,?,?,?)",
                    (hostname, collected_at, usability, payload)
                )
                prune_old(conn, hostname)
        return jsonify({"status": "ok", "hostname": hostname}), 201
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 500


@app.route("/api/machines")
def api_machines():
    """Returns latest report summary for every known machine."""
    with get_db() as conn:
        rows = conn.execute("""
            SELECT r.hostname, r.collected_at, r.usability, r.payload
            FROM reports r
            INNER JOIN (
                SELECT hostname, MAX(collected_at) AS max_ts
                FROM reports GROUP BY hostname
            ) latest ON r.hostname = latest.hostname AND r.collected_at = latest.max_ts
            ORDER BY r.hostname
        """).fetchall()

    machines = []
    for row in rows:
        try:
            p = json.loads(row["payload"])
        except Exception:
            p = {}
        machines.append({
            "hostname":     row["hostname"],
            "collected_at": row["collected_at"],
            "usability":    row["usability"],
            "data":         p,
        })
    return jsonify(machines)


@app.route("/api/machine/<hostname>")
def api_machine(hostname):
    """Returns last N reports for a specific host (history)."""
    limit = min(int(request.args.get("limit", 50)), 200)
    with get_db() as conn:
        rows = conn.execute("""
            SELECT collected_at, usability, payload
            FROM reports WHERE hostname = ?
            ORDER BY collected_at DESC LIMIT ?
        """, (hostname, limit)).fetchall()
    if not rows:
        abort(404, f"No data for host: {hostname}")
    history = []
    for row in rows:
        try:
            p = json.loads(row["payload"])
        except Exception:
            p = {}
        history.append({"collected_at": row["collected_at"], "usability": row["usability"], "data": p})
    return jsonify({"hostname": hostname, "history": history})


@app.route("/api/stats")
def api_stats():
    """Fleet-wide summary counts."""
    with get_db() as conn:
        total = conn.execute("SELECT COUNT(DISTINCT hostname) FROM reports").fetchone()[0]
        rows  = conn.execute("""
            SELECT r.usability, COUNT(*) as cnt
            FROM reports r
            INNER JOIN (
                SELECT hostname, MAX(collected_at) AS max_ts FROM reports GROUP BY hostname
            ) l ON r.hostname=l.hostname AND r.collected_at=l.max_ts
            GROUP BY r.usability
        """).fetchall()
    counts = {r["usability"]: r["cnt"] for r in rows}
    return jsonify({
        "total_machines": total,
        "fully_usable":   counts.get("FULLY_USABLE", 0),
        "degraded":       counts.get("DEGRADED",     0),
        "not_usable":     counts.get("NOT_USABLE",   0),
    })


# ── Dashboard HTML ────────────────────────────────────────────
DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lab Watch — Fleet Dashboard</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=Syne:wght@700;800&display=swap');
:root{
  --bg:#07090f;--surface:#0c1220;--card:#101828;--border:#1c2e4a;
  --accent:#00d4ff;--green:#00ff88;--yellow:#ffc94d;--red:#ff4466;
  --text:#b8cce0;--muted:#3a5070;--glow-a:rgba(0,212,255,.25);
  --glow-g:rgba(0,255,136,.2);--glow-r:rgba(255,68,102,.2);
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'IBM Plex Mono',monospace;min-height:100vh;overflow-x:hidden}
body::before{
  content:'';position:fixed;inset:0;pointer-events:none;
  background:radial-gradient(ellipse 80% 50% at 50% -10%,rgba(0,212,255,.07),transparent);
}

/* ── NAV ── */
nav{
  display:flex;align-items:center;justify-content:space-between;
  padding:14px 28px;border-bottom:1px solid var(--border);
  background:rgba(12,18,32,.85);backdrop-filter:blur(10px);
  position:sticky;top:0;z-index:200;
}
.brand{display:flex;align-items:center;gap:12px}
.brand-icon{width:34px;height:34px;flex-shrink:0}
.brand h1{font-family:'Syne',sans-serif;font-size:1.15rem;letter-spacing:.12em;color:var(--accent);text-shadow:0 0 18px var(--glow-a)}
.brand sub{font-size:.6rem;color:var(--muted);letter-spacing:.2em;display:block;margin-top:-2px}
.nav-right{display:flex;align-items:center;gap:20px}
#clock{font-size:.7rem;color:var(--muted)}
.refresh-btn{
  padding:6px 16px;border:1px solid var(--accent);border-radius:4px;
  background:transparent;color:var(--accent);font-family:inherit;font-size:.72rem;
  cursor:pointer;letter-spacing:.08em;transition:background .15s;
}
.refresh-btn:hover{background:rgba(0,212,255,.08)}
.status-dot{width:8px;height:8px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}

/* ── FLEET BAR ── */
.fleet-bar{
  display:grid;grid-template-columns:repeat(4,1fr);gap:1px;
  background:var(--border);border-bottom:1px solid var(--border);
}
.fleet-stat{
  background:var(--surface);padding:18px 24px;
  display:flex;flex-direction:column;align-items:center;gap:4px;
}
.fleet-stat .num{font-family:'Syne',sans-serif;font-size:2rem;font-weight:800;line-height:1}
.fleet-stat .lbl{font-size:.65rem;letter-spacing:.15em;color:var(--muted)}
.num-total{color:var(--accent);text-shadow:0 0 20px var(--glow-a)}
.num-ok   {color:var(--green); text-shadow:0 0 20px var(--glow-g)}
.num-deg  {color:var(--yellow)}
.num-fail {color:var(--red);   text-shadow:0 0 20px var(--glow-r)}

/* ── SEARCH / FILTER ── */
.toolbar{display:flex;align-items:center;gap:12px;padding:16px 28px;flex-wrap:wrap}
.search-wrap{position:relative;flex:1;min-width:180px}
.search-wrap input{
  width:100%;background:var(--card);border:1px solid var(--border);border-radius:5px;
  padding:8px 12px 8px 32px;color:var(--text);font-family:inherit;font-size:.78rem;
  outline:none;transition:border-color .15s;
}
.search-wrap input:focus{border-color:var(--accent)}
.search-wrap::before{content:'⌕';position:absolute;left:10px;top:50%;transform:translateY(-50%);color:var(--muted);font-size:.9rem}
.filter-btns{display:flex;gap:6px;flex-shrink:0}
.filter-btn{
  padding:6px 14px;border-radius:4px;border:1px solid var(--border);
  background:transparent;color:var(--muted);font-family:inherit;font-size:.7rem;
  letter-spacing:.08em;cursor:pointer;transition:all .15s;
}
.filter-btn:hover,.filter-btn.active{border-color:var(--accent);color:var(--accent);background:rgba(0,212,255,.05)}
.filter-btn.f-ok.active  {border-color:var(--green); color:var(--green)}
.filter-btn.f-deg.active {border-color:var(--yellow);color:var(--yellow)}
.filter-btn.f-fail.active{border-color:var(--red);   color:var(--red)}

/* ── GRID ── */
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:16px;padding:0 28px 28px}

/* ── MACHINE CARD ── */
.mc{
  background:var(--card);border:1px solid var(--border);border-radius:8px;
  overflow:hidden;cursor:pointer;
  transition:border-color .2s,box-shadow .2s,transform .15s;
  animation:fadeIn .35s ease both;
}
@keyframes fadeIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.mc:hover{transform:translateY(-2px);box-shadow:0 8px 32px rgba(0,0,0,.4)}
.mc.u-FULLY_USABLE:hover {border-color:var(--green); box-shadow:0 4px 24px var(--glow-g)}
.mc.u-DEGRADED:hover     {border-color:var(--yellow);box-shadow:0 4px 24px rgba(255,201,77,.2)}
.mc.u-NOT_USABLE:hover   {border-color:var(--red);   box-shadow:0 4px 24px var(--glow-r)}

.mc-top{
  display:flex;align-items:center;justify-content:space-between;
  padding:12px 14px;border-bottom:1px solid var(--border);
  background:rgba(0,0,0,.15);
}
.mc-host{font-family:'Syne',sans-serif;font-size:.9rem;font-weight:700;letter-spacing:.06em;color:#d0e8ff}
.mc-badge{font-size:.62rem;font-weight:600;letter-spacing:.1em;padding:3px 9px;border-radius:3px}
.b-FULLY_USABLE{background:rgba(0,255,136,.1);color:var(--green);border:1px solid rgba(0,255,136,.3)}
.b-DEGRADED    {background:rgba(255,201,77,.1);color:var(--yellow);border:1px solid rgba(255,201,77,.3)}
.b-NOT_USABLE  {background:rgba(255,68,102,.1);color:var(--red);  border:1px solid rgba(255,68,102,.3)}
.b-UNKNOWN     {background:rgba(58,80,112,.2); color:var(--muted);border:1px solid var(--border)}

.mc-body{padding:12px 14px}

.metrics{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:10px}
.metric{background:rgba(0,0,0,.2);border-radius:4px;padding:7px 9px}
.metric .mk{font-size:.58rem;letter-spacing:.12em;color:var(--muted);margin-bottom:3px}
.metric .mv{font-size:.8rem;color:var(--text)}

.bars{display:flex;flex-direction:column;gap:5px;margin-bottom:10px}
.bar-row{display:flex;align-items:center;gap:8px}
.bar-row .bl{font-size:.6rem;color:var(--muted);width:28px;flex-shrink:0}
.bar-track{flex:1;height:4px;background:rgba(255,255,255,.05);border-radius:2px;overflow:hidden}
.bar-fill{height:100%;border-radius:2px;transition:width .5s ease}
.bg{background:var(--green)}.by{background:var(--yellow)}.br{background:var(--red)}
.bar-row .bv{font-size:.6rem;color:var(--muted);width:32px;text-align:right;flex-shrink:0}

.mc-footer{
  display:flex;justify-content:space-between;align-items:center;
  padding:7px 14px;border-top:1px solid var(--border);
  background:rgba(0,0,0,.1);font-size:.6rem;color:var(--muted);
}
.iface-dots{display:flex;gap:4px}
.iface-dot{width:6px;height:6px;border-radius:50%}
.iface-up  {background:var(--green);box-shadow:0 0 5px var(--green)}
.iface-down{background:var(--muted)}

.issues-strip{display:flex;flex-wrap:wrap;gap:4px;padding:0 14px 10px}
.issue-chip{
  font-size:.58rem;padding:2px 7px;border-radius:3px;
  background:rgba(255,201,77,.07);color:var(--yellow);border:1px solid rgba(255,201,77,.15);
}
.issue-chip.crit{background:rgba(255,68,102,.07);color:var(--red);border-color:rgba(255,68,102,.2)}

/* ── DETAIL MODAL ── */
#modal{
  display:none;position:fixed;inset:0;z-index:500;
  background:rgba(0,0,0,.7);backdrop-filter:blur(4px);
  align-items:flex-start;justify-content:center;overflow-y:auto;padding:40px 16px;
}
#modal.open{display:flex}
#modal-box{
  background:var(--surface);border:1px solid var(--border);border-radius:10px;
  width:100%;max-width:700px;overflow:hidden;
  animation:slideUp .2s ease;
}
@keyframes slideUp{from{transform:translateY(20px);opacity:0}to{transform:none;opacity:1}}
#modal-header{
  display:flex;justify-content:space-between;align-items:center;
  padding:16px 20px;border-bottom:1px solid var(--border);background:rgba(0,0,0,.2);
}
#modal-title{font-family:'Syne',sans-serif;font-size:1.1rem;color:var(--accent)}
#modal-close{background:none;border:none;color:var(--muted);font-size:1.2rem;cursor:pointer;padding:4px 8px}
#modal-close:hover{color:var(--text)}
#modal-body{padding:20px;overflow-y:auto;max-height:75vh}

.detail-section{margin-bottom:20px}
.detail-section h3{font-size:.65rem;letter-spacing:.18em;color:var(--muted);margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid var(--border)}
.kv-grid{display:grid;grid-template-columns:1fr 1fr;gap:4px}
.kv-row{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid rgba(255,255,255,.03)}
.kv-k{color:var(--muted);font-size:.72rem}
.kv-v{color:var(--text);font-size:.72rem;text-align:right;word-break:break-word;max-width:55%}

.history-spark{margin-top:6px;display:flex;align-items:flex-end;gap:3px;height:28px}
.spark-bar{width:8px;border-radius:2px 2px 0 0;flex-shrink:0}

/* empty state */
.empty{text-align:center;padding:80px 20px;color:var(--muted)}
.empty .ei{font-size:2.5rem;margin-bottom:12px;opacity:.3}
.empty p{font-size:.8rem;letter-spacing:.05em}

@media(max-width:600px){
  nav{padding:10px 14px}
  .fleet-bar{grid-template-columns:repeat(2,1fr)}
  #grid{padding:0 14px 20px;grid-template-columns:1fr}
  .toolbar{padding:10px 14px}
}
</style>
</head>
<body>
<nav>
  <div class="brand">
    <svg class="brand-icon" viewBox="0 0 34 34" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect x="2" y="7" width="30" height="18" rx="2.5" stroke="#00d4ff" stroke-width="1.4"/>
      <polyline points="9,21 13,14 17,18 21,11 25,21" stroke="#00ff88" stroke-width="1.4" fill="none" stroke-linejoin="round"/>
      <line x1="11" y1="29" x2="23" y2="29" stroke="#00d4ff" stroke-width="1.4"/>
    </svg>
    <div><h1>LAB WATCH</h1><sub>FLEET MONITOR</sub></div>
  </div>
  <div class="nav-right">
    <div class="status-dot" id="live-dot" title="Live"></div>
    <span id="clock"></span>
    <button class="refresh-btn" onclick="loadData()">↻ REFRESH</button>
  </div>
</nav>

<div class="fleet-bar">
  <div class="fleet-stat"><span class="num num-total" id="stat-total">—</span><span class="lbl">TOTAL MACHINES</span></div>
  <div class="fleet-stat"><span class="num num-ok"    id="stat-ok">—</span><span class="lbl">FULLY USABLE</span></div>
  <div class="fleet-stat"><span class="num num-deg"   id="stat-deg">—</span><span class="lbl">DEGRADED</span></div>
  <div class="fleet-stat"><span class="num num-fail"  id="stat-fail">—</span><span class="lbl">NOT USABLE</span></div>
</div>

<div class="toolbar">
  <div class="search-wrap"><input type="text" id="search" placeholder="SEARCH HOSTNAME..." oninput="renderGrid()"></div>
  <div class="filter-btns">
    <button class="filter-btn active" data-f="ALL"          onclick="setFilter('ALL',this)">ALL</button>
    <button class="filter-btn f-ok"   data-f="FULLY_USABLE" onclick="setFilter('FULLY_USABLE',this)">OK</button>
    <button class="filter-btn f-deg"  data-f="DEGRADED"     onclick="setFilter('DEGRADED',this)">DEGRADED</button>
    <button class="filter-btn f-fail" data-f="NOT_USABLE"   onclick="setFilter('NOT_USABLE',this)">FAULT</button>
  </div>
</div>

<div id="grid"></div>

<!-- Detail Modal -->
<div id="modal">
  <div id="modal-box">
    <div id="modal-header">
      <span id="modal-title">—</span>
      <button id="modal-close" onclick="closeModal()">✕</button>
    </div>
    <div id="modal-body"></div>
  </div>
</div>

<script>
let machines = [];
let activeFilter = 'ALL';
let refreshTimer;

// ── Clock ──────────────────────────────────────────────────
(function tick(){
  document.getElementById('clock').textContent = new Date().toUTCString().replace('GMT','UTC');
  setTimeout(tick, 1000);
})();

// ── Data load ──────────────────────────────────────────────
async function loadData() {
  try {
    const [mRes, sRes] = await Promise.all([
      fetch('/api/machines'), fetch('/api/stats')
    ]);
    machines = await mRes.json();
    const stats = await sRes.json();
    document.getElementById('stat-total').textContent = stats.total_machines;
    document.getElementById('stat-ok').textContent    = stats.fully_usable;
    document.getElementById('stat-deg').textContent   = stats.degraded;
    document.getElementById('stat-fail').textContent  = stats.not_usable;
    renderGrid();
    document.getElementById('live-dot').style.background = 'var(--green)';
  } catch(e) {
    console.error(e);
    document.getElementById('live-dot').style.background = 'var(--red)';
  }
}

// ── Render ─────────────────────────────────────────────────
function renderGrid() {
  const q = document.getElementById('search').value.toLowerCase();
  const filtered = machines.filter(m => {
    const matchFilter = activeFilter === 'ALL' || m.usability === activeFilter;
    const matchSearch = !q || m.hostname.toLowerCase().includes(q);
    return matchFilter && matchSearch;
  });

  const grid = document.getElementById('grid');
  if (!filtered.length) {
    grid.innerHTML = '<div class="empty" style="grid-column:1/-1"><div class="ei">◎</div><p>NO MACHINES MATCH FILTER</p></div>';
    return;
  }

  grid.innerHTML = filtered.map((m, i) => buildCard(m, i)).join('');
}

function barColor(pct) {
  return pct >= 90 ? 'br' : pct >= 75 ? 'by' : 'bg';
}

function barHtml(label, pct) {
  const p = Math.min(100, Math.round(pct || 0));
  return `<div class="bar-row">
    <span class="bl">${label}</span>
    <div class="bar-track"><div class="bar-fill ${barColor(p)}" style="width:${p}%"></div></div>
    <span class="bv">${p}%</span>
  </div>`;
}

function buildCard(m, idx) {
  const d = m.data || {};
  const cpu  = d.cpu  || {};
  const ram  = d.ram  || {};
  const stor = d.storage || {};
  const net  = d.network || {};
  const sys  = d.system  || {};

  // Issues across all components
  let allIssues = [];
  ['cpu','ram','storage','network','gpu'].forEach(k => {
    const c = d[k] || {};
    (c.issues || []).forEach(i => allIssues.push({t:i, crit:/NOT_USABLE|FAIL|critical/i.test(i)}));
    (c.devices || []).forEach(dev => (dev.issues||[]).forEach(i => allIssues.push({t:i, crit:true})));
  });

  // Network interfaces
  const ifaceDots = (net.interfaces || []).map(n =>
    `<div class="iface-dot ${n.state==='up'?'iface-up':'iface-down'}" title="${n.iface}: ${n.state}"></div>`
  ).join('');

  // Disk usage (first FS of first device)
  let diskPct = null;
  const devs = stor.devices || [];
  if (devs.length && devs[0].fs && devs[0].fs.length) diskPct = devs[0].fs[0].used_pct;

  const ts = m.collected_at ? m.collected_at.replace('T',' ').replace('Z','') : '—';
  const delay = `animation-delay:${idx*0.04}s`;

  return `<div class="mc u-${m.usability||'UNKNOWN'}" style="${delay}" onclick="openDetail('${m.hostname}')">
  <div class="mc-top">
    <span class="mc-host">${esc(m.hostname)}</span>
    <span class="mc-badge b-${m.usability||'UNKNOWN'}">${m.usability||'UNKNOWN'}</span>
  </div>
  <div class="mc-body">
    <div class="metrics">
      <div class="metric"><div class="mk">OS</div><div class="mv" style="font-size:.68rem">${esc((sys.os||'—').split(' ').slice(0,3).join(' '))}</div></div>
      <div class="metric"><div class="mk">UPTIME</div><div class="mv">${sys.uptime_h!=null?sys.uptime_h+'h':'—'}</div></div>
      <div class="metric"><div class="mk">CPU TEMP</div><div class="mv">${cpu.temp_c!=null&&cpu.temp_c!='null'?cpu.temp_c+'°C':'—'}</div></div>
      <div class="metric"><div class="mk">RAM</div><div class="mv">${ram.total_gb!=null?ram.total_gb+' GB':'—'}</div></div>
    </div>
    <div class="bars">
      ${barHtml('CPU', cpu.cpu_pct)}
      ${barHtml('RAM', ram.used_pct)}
      ${diskPct!=null?barHtml('DSK', diskPct):''}
    </div>
  </div>
  ${allIssues.length ? `<div class="issues-strip">${allIssues.slice(0,3).map(i=>`<span class="issue-chip${i.crit?' crit':''}">${esc(i.t)}</span>`).join('')}${allIssues.length>3?`<span class="issue-chip">+${allIssues.length-3}</span>`:''}</div>` : ''}
  <div class="mc-footer">
    <span>${ts} UTC</span>
    <div class="iface-dots">${ifaceDots}</div>
  </div>
</div>`;
}

// ── Filter ─────────────────────────────────────────────────
function setFilter(f, btn) {
  activeFilter = f;
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  renderGrid();
}

// ── Detail Modal ───────────────────────────────────────────
async function openDetail(hostname) {
  document.getElementById('modal-title').textContent = hostname;
  document.getElementById('modal-body').innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">Loading…</div>';
  document.getElementById('modal').classList.add('open');

  try {
    const res = await fetch(`/api/machine/${hostname}?limit=20`);
    const data = await res.json();
    renderDetail(data);
  } catch(e) {
    document.getElementById('modal-body').innerHTML = '<div style="color:var(--red);padding:20px">Failed to load</div>';
  }
}

function renderDetail(data) {
  const latest = data.history[0]?.data || {};
  const cpu  = latest.cpu  || {};
  const ram  = latest.ram  || {};
  const stor = latest.storage || {};
  const gpu  = latest.gpu  || {};
  const net  = latest.network || {};
  const sys  = latest.system  || {};

  let html = '';

  // System
  html += section('SYSTEM', [
    ['OS', sys.os], ['Kernel', sys.kernel], ['Board', sys.board],
    ['BIOS', sys.bios], ['Uptime', sys.uptime_h+'h'], ['Boot', sys.boot_time],
    ['Root', sys.root?'Yes':'No']
  ]);

  // CPU
  html += section('CPU', [
    ['Model', cpu.model], ['Arch', cpu.arch],
    ['Cores / Threads', `${cpu.cores} / ${cpu.threads}`],
    ['Freq', cpu.freq_mhz+'MHz'],
    ['Load Avg', `${cpu.load1} / ${cpu.load5} / ${cpu.load15}`],
    ['Utilization', cpu.cpu_pct+'%'],
    ['Temperature', cpu.temp_c!=null&&cpu.temp_c!='null'?cpu.temp_c+'°C':'N/A'],
    ['Status', cpu.status]
  ]);

  // RAM
  html += section('MEMORY', [
    ['Total', ram.total_gb+' GB'], ['Available', ram.avail_gb+' GB'],
    ['Used', ram.used_pct+'%'], ['Swap', ram.swap_gb+' GB'], ['Status', ram.status]
  ]);

  // Storage
  let storRows = [['Status', stor.status]];
  (stor.devices||[]).forEach(d => {
    storRows.push([`/dev/${d.dev}`, `${d.size_gb}GB ${d.rotational==1?'HDD':'SSD'}`]);
    storRows.push(['  SMART', d.smart_ok===true?'PASSED':d.smart_ok===false?'FAILED':'N/A']);
    (d.fs||[]).forEach(f => storRows.push([`  ${f.mount}`, `${f.used_pct}% of ${f.total_gb}GB`]));
  });
  html += section('STORAGE', storRows);

  // GPU
  let gpuRows = [['Status', gpu.status]];
  (gpu.devices||[]).forEach(g => {
    gpuRows.push(['Device', `${g.vendor} ${g.name}`]);
    if (g.temp_c!=null) gpuRows.push(['Temp', g.temp_c+'°C']);
    if (g.util_pct!=null) gpuRows.push(['Util', g.util_pct+'%']);
  });
  html += section('GPU', gpuRows);

  // Network
  let netRows = [['Status', net.status]];
  (net.interfaces||[]).forEach(n => {
    netRows.push([n.iface, n.state+' '+(n.ip||'')]);
    if (n.speed_mbps&&n.speed_mbps!='null') netRows.push(['  Speed', n.speed_mbps+' Mbps']);
    netRows.push(['  MAC', n.mac]);
  });
  html += section('NETWORK', netRows);

  // History sparkline (usability over time)
  const hist = data.history.slice().reverse();
  const colorMap = {FULLY_USABLE:'var(--green)',DEGRADED:'var(--yellow)',NOT_USABLE:'var(--red)',UNKNOWN:'var(--muted)'};
  const sparks = hist.map(h => {
    const col = colorMap[h.usability]||'var(--muted)';
    return `<div class="spark-bar" style="height:${h.usability==='FULLY_USABLE'?'100':h.usability==='DEGRADED'?'60':'30'}%;background:${col};flex:1" title="${h.collected_at}: ${h.usability}"></div>`;
  }).join('');
  html += `<div class="detail-section">
    <h3>HISTORY (last ${hist.length} reports)</h3>
    <div class="history-spark">${sparks}</div>
  </div>`;

  // Issues
  let issueList = [];
  ['cpu','ram','storage','network','gpu'].forEach(k => {
    const c = latest[k]||{};
    (c.issues||[]).forEach(i => issueList.push(i));
    (c.devices||[]).forEach(d=>(d.issues||[]).forEach(i=>issueList.push(i)));
  });
  if (issueList.length) {
    html += `<div class="detail-section"><h3>ACTIVE ISSUES</h3>
      ${issueList.map(i=>`<div style="color:var(--yellow);font-size:.72rem;padding:4px 0;border-bottom:1px solid rgba(255,201,77,.08)">⚠ ${esc(i)}</div>`).join('')}
    </div>`;
  }

  document.getElementById('modal-body').innerHTML = html;
}

function section(title, rows) {
  const rowsHtml = rows.map(([k,v]) =>
    `<div class="kv-row"><span class="kv-k">${esc(k)}</span><span class="kv-v">${esc(v!=null?String(v):'—')}</span></div>`
  ).join('');
  return `<div class="detail-section"><h3>${title}</h3>${rowsHtml}</div>`;
}

function closeModal() { document.getElementById('modal').classList.remove('open'); }
document.getElementById('modal').addEventListener('click', e => { if(e.target===document.getElementById('modal')) closeModal(); });
document.addEventListener('keydown', e => { if(e.key==='Escape') closeModal(); });

function esc(s) {
  return String(s??'—').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Auto-refresh every 60s ─────────────────────────────────
loadData();
refreshTimer = setInterval(loadData, 60000);
</script>
</body>
</html>"""

@app.route("/")
def dashboard():
    return render_template_string(DASHBOARD_HTML)

# ── Entry point ───────────────────────────────────────────────
if __name__ == "__main__":
    print(f"""
╔══════════════════════════════════════════╗
║    PC Lab Watch — Server v3.0            ║
╠══════════════════════════════════════════╣
║  DB      : {DB_PATH:<30} ║
║  Binding : {BIND}:{PORT:<25} ║
║  Dashboard: http://{BIND}:{PORT}/         ║
╚══════════════════════════════════════════╝
""")
    init_db()
    app.run(host=BIND, port=PORT, debug=False, threaded=True)
