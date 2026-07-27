// Tron -- server-authoritative multiplayer client.
//
// Unlike snake.js, this file runs NO simulation. The Zig server (see
// src/session.zig's Session.startGame and src/games.zig's TronGame) owns the
// only authoritative tick. This file has exactly two jobs: send keypresses
// up over the WebSocket, and render whatever delta the server broadcasts
// down. See the project's tron-server-authoritative memory for why.

const WIDTH = 128; // must match core.GRID_WIDTH
const HEIGHT = 96; // must match core.GRID_HEIGHT
const CELL = 8; // px per grid cell (internal resolution; CSS scales it down)
// Byte codes core.setDirection expects (i/j/k/l = 105/106/107/108).
const KEY = { UP: 105, LEFT: 106, DOWN: 107, RIGHT: 108 };

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
let initialized = false;
let started = false;
let lastSequence = 0;
let resyncPending = false;

let bodies = []; // bodies[i] = [{x,y}, ...], head first
let dead = [];

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
      const msg = JSON.parse(event.data);
      if (msg.kind === "init") initializeMatch(msg);
      else if (msg.kind === "resync") applySnapshot(msg);
      else handleControlMessage(msg);
      return;
    }

    const bytes = new Uint8Array(event.data);

    if (!initialized) {
      errorEl.textContent = "Received a game frame before match initialization.";
      return;
    }

    if (bytes.length !== 4 + bodies.length * 4) {
      errorEl.textContent = "Received a malformed game frame.";
      return;
    }

    const sequence = new DataView(bytes.buffer, bytes.byteOffset, 4)
      .getUint32(0, false);
    if (resyncPending) return;
    if (sequence <= lastSequence) return;
    if (sequence !== lastSequence + 1) {
      requestResync(ws);
      return;
    }

    if (!started) {
      started = true;
      overlay.classList.add("hidden");
    }

    applyDeltas(bytes);
    lastSequence = sequence;
    render();
  };

  ws.onclose = () => setStatus("disconnected", "var(--danger)");
  ws.onerror = () => {
    errorEl.textContent = "Connection error -- is the server running?";
  };

  wireInput(ws);
}

function initializeMatch(msg) {
  if (!Array.isArray(msg.snakes) || !Number.isInteger(msg.snake_idx)) {
    errorEl.textContent = "Received an invalid match initialization message.";
    return;
  }

  const initialBodies = new Array(msg.snakes.length);
  for (const snake of msg.snakes) {
    if (
      !Number.isInteger(snake.idx) ||
      snake.idx < 0 ||
      snake.idx >= initialBodies.length ||
      !Number.isInteger(snake.x) ||
      !Number.isInteger(snake.y)
    ) {
      errorEl.textContent = "Received an invalid snake snapshot.";
      return;
    }
    initialBodies[snake.idx] = [{ x: snake.x, y: snake.y }];
  }

  if (
    initialBodies.some((body) => body === undefined) ||
    msg.snake_idx < 0 ||
    msg.snake_idx >= initialBodies.length
  ) {
    errorEl.textContent = "Received an incomplete match initialization message.";
    return;
  }

  myIdx = msg.snake_idx;
  bodies = initialBodies;
  dead = new Array(bodies.length).fill(false);
  lastSequence = 0;
  resyncPending = false;
  initialized = true;
  setStatus(`you are player ${myIdx + 1}`, COLORS[myIdx]);
  render();
}

function applySnapshot(msg) {
  if (!Number.isInteger(msg.sequence) || !Array.isArray(msg.snakes)) {
    errorEl.textContent = "Received an invalid resync snapshot.";
    return;
  }

  const nextBodies = new Array(msg.snakes.length);
  const nextDead = new Array(msg.snakes.length);
  for (const snake of msg.snakes) {
    if (
      !Number.isInteger(snake.idx) ||
      snake.idx < 0 ||
      snake.idx >= nextBodies.length ||
      typeof snake.is_dead !== "boolean" ||
      !Array.isArray(snake.body) ||
      snake.body.length === 0 ||
      snake.body.some(
        (pos) =>
          !Number.isInteger(pos.x) ||
          !Number.isInteger(pos.y),
      )
    ) {
      errorEl.textContent = "Received an invalid resync snapshot.";
      return;
    }
    nextBodies[snake.idx] = snake.body.map(({ x, y }) => ({ x, y }));
    nextDead[snake.idx] = snake.is_dead;
  }

  if (nextBodies.some((body) => body === undefined)) {
    errorEl.textContent = "Received an incomplete resync snapshot.";
    return;
  }

  bodies = nextBodies;
  dead = nextDead;
  lastSequence = msg.sequence;
  resyncPending = false;
  render();
}

function requestResync(ws) {
  if (resyncPending) return;
  resyncPending = true;
  ws.send(JSON.stringify({ kind: "resync" }));
}

// Wire format: 4-byte big-endian sequence, then 4 bytes per snake.
// Each delta contains a header (bit0 has_death, bit1 has_killer, bit2 has_pos),
// followed by killer index, next head x, and next head y.
// Must mirror core.zig's Delta.encode exactly.
function applyDeltas(bytes) {
  for (let i = 0; i < bodies.length; i++) {
    if (dead[i]) continue;
    const off = 4 + i * 4;
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

  for (let i = 0; i < bodies.length; i++) drawSnake(i);
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

  if (typeof msg.winner === "number") {
    // winner === snake count is the server's tie-broadcast sentinel --
    // see Session.startGame's dead_count == n_snakes branch in session.zig.
    const isTie = msg.winner === bodies.length;
    const isWinner = !isTie && msg.winner === myIdx;

    overlayTitle.textContent = isTie ? "draw" : isWinner ? "you won" : "you lost";
    overlayBody.textContent = isTie
      ? "everyone crashed on the same tick"
      : isWinner
        ? "last snake standing"
        : `player ${msg.winner + 1} won`;
    overlay.classList.remove("hidden");
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
