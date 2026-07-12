// Tron -- server-authoritative multiplayer client.
//
// Unlike snake.js, this file runs NO simulation. The Zig server (see
// src/session.zig's Session.startGame and src/core.zig's TronGame) owns the
// only authoritative tick. This file has exactly two jobs: send keypresses
// up over the WebSocket, and render whatever delta the server broadcasts
// down. See the project's tron-server-authoritative memory for why.

const WIDTH = 128; // must match core.GRID_WIDTH
const HEIGHT = 96; // must match core.GRID_HEIGHT
const CELL = 8; // px per grid cell (internal resolution; CSS scales it down)
const N_SNAKES = 5; // must match core.TronGame.n_snakes

// Byte codes core.setDirection expects (i/j/k/l = 105/106/107/108).
const KEY = { UP: 105, LEFT: 106, DOWN: 107, RIGHT: 108 };

// Fixed spawn layout -- must mirror TronGame.init()'s corner/center placement
// exactly. The wire protocol only ever sends *deltas* (next head cell +
// death), never a full snapshot, so the client has to already know where
// every snake starts and grow its body from there.
const SPAWN = [
  { x: 0, y: 0 }, // a: gridCorner(.down)  -> top_left
  { x: WIDTH - 1, y: HEIGHT - 1 }, // b: gridCorner(.up)    -> bottom_right
  { x: WIDTH - 1, y: 0 }, // c: gridCorner(.left)  -> top_right
  { x: 0, y: HEIGHT - 1 }, // d: gridCorner(.right) -> bottom_left
  { x: Math.floor(WIDTH / 2), y: Math.floor(HEIGHT / 2) }, // e: gridCenter()
];

const COLORS = ["#56d364", "#f85149", "#58a6ff", "#d29922", "#bc8cff"];

const canvas = document.getElementById("board");
const ctx = canvas.getContext("2d");
const overlay = document.getElementById("overlay");
const overlayTitle = document.getElementById("overlay-title");
const overlayBody = document.getElementById("overlay-body");
const statusEl = document.getElementById("status");
const errorEl = document.getElementById("error");

canvas.width = WIDTH * CELL;
canvas.height = HEIGHT * CELL;

let myIdx = null;
let gotIdx = false;
let started = false;

const bodies = SPAWN.map((pos) => [pos]); // bodies[i] = [{x,y}, ...], head first
const dead = new Array(N_SNAKES).fill(false);

function connect() {
  const ws = new WebSocket(`ws://${location.host}/`);
  ws.binaryType = "arraybuffer";

  ws.onopen = () => {
    setStatus("connected -- waiting for players...");
  };

  ws.onmessage = (event) => {
    // Text frames carry JSON control messages (countdown, game result).
    // Binary frames carry everything performance-sensitive (idx, deltas).
    // The two never collide -- WebSocket tags every frame with its opcode,
    // so `event.data` arrives as a string for text and an ArrayBuffer (per
    // `ws.binaryType`) for binary, regardless of byte length.
    if (typeof event.data === "string") {
      handleControlMessage(JSON.parse(event.data));
      return;
    }

    const bytes = new Uint8Array(event.data);

    if (!gotIdx) {
      // First frame the server ever sends: one byte, your snake index.
      myIdx = bytes[0];
      gotIdx = true;
      setStatus(`you are player ${myIdx + 1}`, COLORS[myIdx]);
      return;
    }

    if (!started) {
      started = true;
      overlay.classList.add("hidden");
    }

    applyDeltas(bytes);
    render();
  };

  ws.onclose = () => setStatus("disconnected", "var(--danger)");
  ws.onerror = () => {
    errorEl.textContent = "Connection error -- is the server running?";
  };

  wireInput(ws);
}

// Wire format: 4 bytes per snake, N_SNAKES snakes back to back.
//   byte 0: header (bit0 has_death, bit1 has_killer, bit2 has_pos)
//   byte 1: killer snake index (only meaningful if has_killer)
//   byte 2: next head x       (only meaningful if has_pos)
//   byte 3: next head y       (only meaningful if has_pos)
// Must mirror core.zig's Delta.encode exactly.
function applyDeltas(bytes) {
  for (let i = 0; i < N_SNAKES; i++) {
    if (dead[i]) continue;
    const off = i * 4;
    const header = bytes[off];
    const hasDeath = (header & 0b001) !== 0;
    const hasPos = (header & 0b100) !== 0;

    // Order matters: draw the crash-site head before freezing the snake, so
    // a snake that dies by colliding still shows exactly where it happened
    // instead of stopping one cell short.
    if (hasPos) bodies[i].unshift({ x: bytes[off + 2], y: bytes[off + 3] });
    if (hasDeath) dead[i] = true;
  }
}

function render() {
  ctx.fillStyle = "#0d1117";
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  for (let i = 0; i < N_SNAKES; i++) drawSnake(i);
}

function drawSnake(i) {
  const body = bodies[i];
  ctx.fillStyle = COLORS[i];
  ctx.globalAlpha = dead[i] ? 0.25 : 1;
  for (const { x, y } of body) {
    ctx.fillRect(x * CELL, y * CELL, CELL - 1, CELL - 1);
  }
  ctx.globalAlpha = 1;

  if (i === myIdx && !dead[i]) {
    const head = body[0];
    ctx.strokeStyle = "#e6edf3";
    ctx.lineWidth = 1;
    ctx.strokeRect(head.x * CELL + 0.5, head.y * CELL + 0.5, CELL - 2, CELL - 2);
  }
}

function handleControlMessage(msg) {
  if (typeof msg.countdown === "number") {
    overlayTitle.textContent = `starting in ${msg.countdown}...`;
    overlayBody.textContent = "get ready";
  }
}

function setStatus(text, color) {
  statusEl.textContent = text;
  statusEl.style.color = color || "var(--muted)";
}

function wireInput(ws) {
  const map = {
    ArrowUp: KEY.UP, KeyW: KEY.UP, KeyI: KEY.UP,
    ArrowLeft: KEY.LEFT, KeyA: KEY.LEFT, KeyJ: KEY.LEFT,
    ArrowDown: KEY.DOWN, KeyS: KEY.DOWN, KeyK: KEY.DOWN,
    ArrowRight: KEY.RIGHT, KeyD: KEY.RIGHT, KeyL: KEY.RIGHT,
  };
  canvas.addEventListener("keydown", (e) => {
    const code = map[e.code];
    if (code === undefined) return;
    e.preventDefault();
    if (ws.readyState === WebSocket.OPEN) ws.send(new Uint8Array([code]));
  });
}

canvas.tabIndex = 0;
canvas.addEventListener("click", () => canvas.focus());
render();
connect();
