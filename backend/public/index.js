class Chart {
  canvas;
  chartData;
  chartLen = 0;

  static dotTooltip = document.getElementById("dot-chart");

  constructor(canvasElement, bufferSize) {
    this.canvas = canvasElement;
    this.chartData = new Float32Array(bufferSize);

    this.canvas.addEventListener("mousemove", (e) => this.updateTooltip(e));
  }

  updateTooltip(e) {
    const mx = Math.max.apply(null, this.chartData) + 10;
    const w = this.canvas.width;
    const h = this.canvas.height;

    let hit = false;
    for (let i = 0; i < this.chartLen; i++) {
      const y = h - (h / mx) * this.chartData[i];
      const x = (w / this.chartLen) * i;

      if (Math.abs(y - e.offsetY) < 20 && Math.abs(x - e.offsetX) < 20) {
        const dataStr = String(this.chartData[i]);
        const rect = this.canvas.getBoundingClientRect();

        Chart.dotTooltip.style.left = rect.left + x + "px";
        Chart.dotTooltip.style.top = rect.top + y + "px";
        Chart.dotTooltip.innerText = dataStr;

        hit = true;
        break;
      }
    }
    if (!hit) {
      Chart.dotTooltip.style.left = "-200px";
    }
  }

  pushValue(value) {
    if (this.chartLen < this.chartData.length) {
      this.chartData[this.chartLen] = value;
      this.chartLen += 1;
    } else {
      for (let i = 0; i < this.chartData.length - 1; i++)
        this.chartData[i] = this.chartData[i + 1];
      this.chartData[this.chartData.length - 1] = value;
    }
  }

  update() {
    const mx =
      Math.max.apply(null, this.chartData.slice(0, this.chartLen)) + 10;
    const w = this.canvas.width;
    const h = this.canvas.height;

    if (!this.canvas.getContext || this.chartLen <= 0) return;
    Chart.dotTooltip.style.left = "-200px";

    const ctx = this.canvas.getContext("2d");
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = "red";
    ctx.lineWidth = 2;

    let y = h - (h / mx) * this.chartData[0];
    let x = 0;
    ctx.moveTo(x, y);
    ctx.beginPath();

    for (let i = 0; i < this.chartLen; i++) {
      y = h - (h / mx) * this.chartData[i];
      x = (w / this.chartLen) * i;

      ctx.lineTo(x, y);
      ctx.fillStyle = "#65737e";
      ctx.strokeStyle = "#65737e";
      ctx.stroke();

      ctx.beginPath();
      ctx.arc(x, y, 3, 0, 2 * Math.PI, false);
      ctx.fill();
      ctx.stroke();

      ctx.beginPath();
      ctx.moveTo(x, y);
    }
  }
}

function makeCharts() {
  const charts = {};
  const chartContainers = document.getElementsByClassName("chart-container");
  for (let i = 0; i < chartContainers.length; i++) {
    const container = chartContainers[i];
    const canvas = container.getElementsByClassName("chart")[0];

    canvas.width = container.offsetWidth;
    canvas.height = container.offsetHeight;

    const bufSize = container.getAttribute("data-buffer") ?? 16;
    const chart = new Chart(canvas, bufSize);

    if (container.id) {
      charts[container.id] = chart;
    }

    charts[i] = chart;
  }
  return charts;
}

const connectionStatus = document.getElementById("connection-status");

const ws = new WebSocket("ws://127.0.0.1:3000");

const charts = makeCharts();
const temperatureChart = charts["temperature-chart"];
const inverseChart = charts["inverse-chart"];

ws.onmessage = function (e) {
  temperatureChart.pushValue(e.data);
  inverseChart.pushValue(255 - Number(e.data));
  temperatureChart.update();
  inverseChart.update();
  return false;
};

ws.onclose = function () {
  connectionStatus.innerHTML = "Disconnected";
  connectionStatus.style.color = "#bf4955";
};

ws.onopen = function () {
  connectionStatus.innerHTML = "Connected";
  connectionStatus.style.color = "#77b780";
};
