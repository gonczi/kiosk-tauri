const okButton = document.getElementById("ok-btn");
const result = document.getElementById("result");
const clockCanvas = document.getElementById("analog-clock");
const digitalClock = document.getElementById("clock-digital");

const invoke = window.__TAURI__?.core?.invoke;

function drawClockFace(ctx, radius) {
  const rimGradient = ctx.createRadialGradient(0, 0, radius * 0.1, 0, 0, radius);
  rimGradient.addColorStop(0, "#fefefe");
  rimGradient.addColorStop(0.7, "#f6f8fc");
  rimGradient.addColorStop(1, "#d9e4f2");

  ctx.beginPath();
  ctx.arc(0, 0, radius, 0, Math.PI * 2);
  ctx.fillStyle = rimGradient;
  ctx.fill();

  ctx.lineWidth = radius * 0.08;
  ctx.strokeStyle = "#2f4f78";
  ctx.stroke();

  ctx.beginPath();
  ctx.arc(0, 0, radius * 0.06, 0, Math.PI * 2);
  ctx.fillStyle = "#2f4f78";
  ctx.fill();
}

function drawTicks(ctx, radius) {
  for (let i = 0; i < 60; i += 1) {
    const angle = (i * Math.PI) / 30;
    ctx.save();
    ctx.rotate(angle);

    const isHourTick = i % 5 === 0;
    ctx.beginPath();
    ctx.moveTo(0, -radius * 0.86);
    ctx.lineTo(0, -radius * (isHourTick ? 0.72 : 0.78));
    ctx.lineWidth = isHourTick ? radius * 0.04 : radius * 0.015;
    ctx.strokeStyle = isHourTick ? "#1f3959" : "#6b84a3";
    ctx.stroke();

    ctx.restore();
  }
}

function drawHand(ctx, angle, length, width, color) {
  ctx.save();
  ctx.rotate(angle);
  ctx.beginPath();
  ctx.moveTo(0, length * 0.15);
  ctx.lineTo(0, -length);
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.strokeStyle = color;
  ctx.stroke();
  ctx.restore();
}

function drawClock(now = new Date()) {
  if (!(clockCanvas instanceof HTMLCanvasElement)) {
    return;
  }

  const ctx = clockCanvas.getContext("2d");
  if (!ctx) {
    return;
  }

  const radius = clockCanvas.width / 2;

  ctx.clearRect(0, 0, clockCanvas.width, clockCanvas.height);
  ctx.save();
  ctx.translate(radius, radius);

  drawClockFace(ctx, radius * 0.9);
  drawTicks(ctx, radius * 0.9);

  const second = now.getSeconds() + now.getMilliseconds() / 1000;
  const minute = now.getMinutes() + second / 60;
  const hour = (now.getHours() % 12) + minute / 60;

  const hourAngle = (hour * Math.PI) / 6;
  const minuteAngle = (minute * Math.PI) / 30;
  const secondAngle = (second * Math.PI) / 30;

  drawHand(ctx, hourAngle, radius * 0.45, radius * 0.06, "#1d3557");
  drawHand(ctx, minuteAngle, radius * 0.65, radius * 0.04, "#305c8c");
  drawHand(ctx, secondAngle, radius * 0.7, radius * 0.015, "#d93f2f");

  ctx.beginPath();
  ctx.arc(0, 0, radius * 0.035, 0, Math.PI * 2);
  ctx.fillStyle = "#d93f2f";
  ctx.fill();

  ctx.restore();

  if (digitalClock) {
    digitalClock.textContent = now.toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  }
}

function startClock() {
  drawClock();
  setInterval(() => {
    drawClock();
  }, 1000 / 30);
}

startClock();

okButton?.addEventListener("click", async () => {
  if (!result) {
    return;
  }

  if (typeof invoke !== "function") {
    result.textContent = "Tauri backend is not available";
    result.hidden = false;
    console.error("window.__TAURI__.core.invoke is unavailable", window.__TAURI__);
    return;
  }

  try {
    const message = await invoke("ok_pressed");
    result.textContent = String(message);
    result.hidden = false;
  } catch (error) {
    result.textContent = "Backend call failed";
    result.hidden = false;
    console.error(error);
  }
});
