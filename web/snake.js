// Snake -- the browser frontend for the Zig/WASM simulation core.
//
// The .wasm is platform-agnostic and knows nothing about browsers. Everything
// in this file is the "frontend shell" (the web counterpart of main.zig):
// load the module, drive it (init / tick / setDirection), and draw whatever
// state it reports back. The core is never touched.

const WIDTH = 64; // must match core.GRID_WIDTH
const HEIGHT = 32; // must match core.GRID_HEIGHT
const CELL = 16; // px per grid cell (internal resolution; CSS scales it down)
const STEP_MS = 110; // simulation tick interval

// Wire contract: tick() returns @intFromEnum(core.GameState). This object MUST
// mirror the variant order declared in core.zig's GameState enum.
const STATE = { FOOD_ATE: 0, RUNNING: 1, PAUSED: 2, OVER: 3 };

// Byte codes core.Snake.setDirection expects (i/j/k/l = 105/106/107/108). The
// host translates friendly keys into the core's existing key protocol.
const KEY = { UP: 105, LEFT: 106, DOWN: 107, RIGHT: 108 };

const canvas = document.getElementById("board");
const ctx = canvas.getContext("2d");
const scoreEl = document.getElementById("score");
const overlay = document.getElementById("overlay");
const errorEl = document.getElementById("error");

canvas.width = WIDTH * CELL;
canvas.height = HEIGHT * CELL;

let wasm = null;
let running = false;
let lastStep = 0;

async function boot() {
  // Note: file:// cannot fetch a .wasm -- this must be served over http.
  const res = await fetch("snake-wasm.wasm");
  const bytes = await res.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes);
  wasm = instance.exports;

  wireInput();
  newGame();
  requestAnimationFrame(loop);
}

function newGame() {
  // init takes a u64 seed -> JS BigInt. The host supplies the entropy the
  // freestanding module has no clock to generate itself.
  wasm.init(BigInt(Date.now()));
  running = true;
  overlay.classList.add("hidden");
  canvas.focus();
}

function loop(now) {
  requestAnimationFrame(loop);
  if (running && now - lastStep >= STEP_MS) {
    lastStep = now;
    if (wasm.tick() === STATE.OVER) {
      running = false;
      overlay.classList.remove("hidden");
    }
  }
  render();
}

function render() {
  ctx.fillStyle = "#0d1117";
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // IMPORTANT: re-read the pointer, the length, AND rebuild the memory view
  // every single frame. The body's ArrayList can reallocate when the snake
  // grows (the pointer moves), and wasm can grow its linear memory (which
  // detaches memory.buffer and kills any view over the old one). Caching any
  // of these across a tick is the classic silent wasm bug -- a frozen or
  // scrambled snake with no error.
  const len = wasm.getSnakeLength();
  const ptr = wasm.getSnakePtr();
  const body = new Uint8Array(wasm.memory.buffer, ptr, len * 2);

  drawCell(wasm.getFoodPosX(), wasm.getFoodPosY(), "#f85149");

  // Body index 0 is the head; draw tail-first so the head sits on top.
  for (let i = len - 1; i >= 0; i--) {
    drawCell(body[i * 2], body[i * 2 + 1], i === 0 ? "#56d364" : "#2ea043");
  }

  scoreEl.textContent = wasm.getScore();
}

function drawCell(x, y, color) {
  ctx.fillStyle = color;
  ctx.fillRect(x * CELL, y * CELL, CELL - 1, CELL - 1);
}

function wireInput() {
  const map = {
    ArrowUp: KEY.UP, KeyW: KEY.UP, KeyI: KEY.UP,
    ArrowLeft: KEY.LEFT, KeyA: KEY.LEFT, KeyJ: KEY.LEFT,
    ArrowDown: KEY.DOWN, KeyS: KEY.DOWN, KeyK: KEY.DOWN,
    ArrowRight: KEY.RIGHT, KeyD: KEY.RIGHT, KeyL: KEY.RIGHT,
  };
  // Listen on the canvas, not window: the game only consumes keys while it has
  // focus, so it never hijacks page scrolling or the rest of the site.
  canvas.addEventListener("keydown", (e) => {
    const code = map[e.code];
    if (code !== undefined) {
      e.preventDefault();
      wasm.setDirection(code);
    } else if (e.code === "Space" || e.code === "Enter") {
      e.preventDefault();
      if (!running) newGame();
    }
  });
}

boot().catch((err) => {
  errorEl.textContent =
    "Failed to load the game: " + err.message +
    " -- are you serving over http (not file://)?";
});
