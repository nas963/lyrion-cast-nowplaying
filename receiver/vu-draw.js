/*
 * VU meter drawing, shared by Material Skin (plugin VUMeter) and the Cast receiver (lyrion-cast-nowplaying,
 * receiver/vu-draw.js is a copy of this file: keep them the same).
 *
 *   var m = VUDraw.create(canvas, { style: "needles" | "bars" | "scope" | "spectrum", ref: "auto" | -14, delay: 60,
 *                                   accent: "#e0835a" });
 *   m.push(frame)      frame from the VU service: { t: ms, p: [peakL, peakR], r: [rmsL, rmsR], on: 0|1 } (0..1 of
 *                      full scale). t is when the service took the levels (its wall clock). The frame is shown at
 *                      t + (90th percentile of the travel time in the last 8 s) + `delay`: the same distance to the music
 *                      for every frame, whatever the path (SSE, Cast batches) and the clock difference to the server.
 *                      A frame without t is shown on arrival + `delay`.
 *   m.stats()          { lag: median travel time ms (incl. clock difference), min, max, base: the one used (90th pct), n }
 *   m.set({ ... })     change options
 *   m.stop()           stop drawing
 *
 * Needles: classic VU instruments, linear voltage scale -20..+3 VU, 0 VU = `ref` dBFS RMS, needle with
 * VU ballistics (about 300 ms to the reading, slight overshoot), red lamp at -0.1 dBFS (clipping).
 * ref "auto": 0 VU follows the loudness of the recording (rises within seconds when the music gets louder,
 * falls over about a minute), so loud passages sit around 0 VU on loud and quiet masters alike and the
 * dynamics within a piece still show.
 * Bars: LED-style bars -60..0 dBFS, RMS with fast attack and slow release, peak hold mark.
 * Scope: L and R over 20 ms (2 ms/div), triggered on a rising zero crossing of L (service, frame.sc), with
 * automatic vertical gain shown as a readout. Spectrum: 48 log bands 20 Hz..20 kHz in dBFS (service,
 * frame.sp, FFT), -80..0 dB, fast attack, slow fall, peak caps. Both need the service to be asked for them
 * (mode=scope / mode=spectrum, see VUDraw.mode()).
 * Frames are shown `delay` ms after they arrive (the DAC plays them a little later than they are sent).
 */
(function (root) {
    'use strict';

    var VU_MARKS = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3];
    var VU_LABELS = { "-20": "20", "-10": "10", "-7": "7", "-5": "5", "-3": "3", "0": "0", "3": "+3" };
    var BAR_MARKS = [-60, -40, -30, -20, -12, -6, -3, 0];
    // dBFS -> 0..1 along the bar (more room near the top)
    var BAR_SCALE = [[-60, 0], [-30, 0.2], [-18, 0.45], [-6, 0.8], [0, 1]];
    var SWING = 48 * Math.PI / 180;     // needle swing to each side

    function db(v) { return v > 1e-6 ? 20 * Math.log10(v) : -120; }

    function barPos(d) {
        if (d <= BAR_SCALE[0][0]) { return 0; }
        for (var i = 1; i < BAR_SCALE.length; ++i) {
            var a = BAR_SCALE[i - 1], b = BAR_SCALE[i];
            if (d <= b[0]) { return a[1] + (b[1] - a[1]) * (d - a[0]) / (b[0] - a[0]); }
        }
        return 1;
    }

    // VU reading (dB re 0 VU) -> 0..1 along the dial: linear in voltage, +3 VU at the end
    function vuPos(d) {
        var v = Math.pow(10, d / 20) / Math.pow(10, 3 / 20);
        return Math.max(0, Math.min(1.04, v));
    }

    function Meter(canvas, opts) {
        this.c = canvas;
        this.o = { style: "needles", ref: "auto", delay: 60, accent: "#e0835a" };
        this.level = null;      // ref "auto": followed loudness, dB RMS
        this.queue = [];
        this.cur = { p: [0, 0], r: [0, 0], on: 0 };
        this.ch = [this.channel(), this.channel()];
        this.last = 0;
        this.running = true;
        this.set(opts || {});
        var self = this;
        var raf = root.requestAnimationFrame || function (f) { return setTimeout(function () { f(Date.now()); }, 33); };
        function loop() {
            if (!self.running) { return; }
            try { self.frame(); } catch (e) { if (root.console) { console.warn("VU:", e); } }
            raf(loop);
        }
        raf(loop);
    }

    Meter.prototype.channel = function () {
        return { x: 0, v: 0, lamp: 0, bar: -120, peak: -120, peakAt: 0 };
    };

    Meter.prototype.set = function (o) {
        for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k) && o[k] !== undefined) { this.o[k] = o[k]; } }
        this.key = "";
    };

    Meter.prototype.stop = function () { this.running = false; };

    Meter.prototype.stats = function () {
        var w = (this.travel || []).map(function (x) { return x[1]; }).sort(function (a, b) { return a - b; });
        if (!w.length) { return { n: 0 }; }
        return { n: w.length, lag: w[Math.floor(w.length / 2)], min: w[0], base: this.base, max: w[w.length - 1] };
    };

    Meter.prototype.push = function (f) {
        if (!f || !f.p || !f.r) { return; }
        var now = Date.now(), q = this.queue, at = now;
        if (f.t) {
            // travel time (+ clock difference) of the last 8 s; its 90th percentile is the base for every
            // frame, so nearly all frames are on time and the distance to the music stays the same
            var d = now - f.t, w = this.travel || (this.travel = []);
            w.push([now, d]);
            while (w.length && now - w[0][0] > 8000) { w.shift(); }
            if (!this.baseAt || now - this.baseAt > 500 || d > this.base + 400) {
                var s = w.map(function (x) { return x[1]; }).sort(function (a, b) { return a - b; });
                this.base = s[Math.min(s.length - 1, Math.floor(s.length * 0.9))];
                this.baseAt = now;
            }
            at = f.t + this.base;
        }
        if (q.length && q[q.length - 1].t > at) { at = q[q.length - 1].t; }
        q.push({ t: at, f: f });
        if (this.queue.length > 120) { this.queue.splice(0, this.queue.length - 120); }
    };

    Meter.prototype.frame = function () {
        var now = Date.now();
        var dt = this.last ? Math.min(0.1, (now - this.last) / 1000) : 0;
        this.last = now;
        var due = now - (+this.o.delay || 0);
        while (this.queue.length && this.queue[0].t <= due) { this.cur = this.queue.shift().f; }
        // no frames for a while (pause, connection lost): fall back to rest
        if (!this.queue.length && this.lastFrame && now - this.lastFrame > 1500) { this.cur = { p: [0, 0], r: [0, 0], on: 0 }; }
        if (this.queue.length) { this.lastFrame = now; }
        var on = !!this.cur.on;
        if (on) { this.follow(Math.max(+this.cur.r[0] || 0, +this.cur.r[1] || 0), dt); }
        if ("spectrum" == this.o.style) { this.updateSpectrum(on ? this.cur.sp : null, dt, now); }
        if ("scope" == this.o.style) { this.updateScope(on ? this.cur.sc : null, dt); }
        for (var i = 0; i < 2; ++i) { this.update(this.ch[i], on ? +this.cur.r[i] || 0 : 0, on ? +this.cur.p[i] || 0 : 0, dt, now); }
        this.draw(now);
    };

    // ref "auto": loudness envelope, up with ~3 s, down with ~60 s (silence and pauses are left out)
    Meter.prototype.follow = function (rms, dt) {
        var d = db(rms);
        if (d < -50 || !dt) { return; }
        if (this.level === null) { this.level = d; return; }
        var tau = d > this.level ? 3 : 60;
        this.level += (d - this.level) * (1 - Math.exp(-dt / tau));
    };

    Meter.prototype.ref = function () {
        if ("auto" != this.o.ref) { return +this.o.ref || -14; }
        if (this.level === null) { return -14; }
        return Math.max(-30, Math.min(-3, this.level + 1));
    };

    Meter.prototype.update = function (c, rms, peak, dt, now) {
        // needle: damped spring towards the VU reading (99% in ~300 ms, ~1.5% overshoot)
        var target = rms > 0 ? vuPos(db(rms) - this.ref()) : 0;
        var w = 13, z = 0.78;
        var steps = Math.max(1, Math.ceil(dt / 0.004)), h = dt / steps;
        for (var s = 0; s < steps; ++s) {
            var acc = w * w * (target - c.x) - 2 * z * w * c.v;
            c.v += acc * h;
            c.x += c.v * h;
        }
        if (c.x < -0.02) { c.x = -0.02; c.v = 0; }
        if (c.x > 1.06) { c.x = 1.06; c.v = 0; }
        if (peak >= 0.9886) { c.lamp = now + 500; }      // -0.1 dBFS: at or next to clipping
        // bars: fast attack, release 24 dB/s; peak hold 1.5 s then falls 20 dB/s
        var d = db(rms), pd = db(peak);
        c.bar = d > c.bar ? d : Math.max(d, c.bar - 24 * dt);
        if (pd >= c.peak) { c.peak = pd; c.peakAt = now; }
        else if (now - c.peakAt > 1500) { c.peak = Math.max(pd, c.peak - 20 * dt); }
    };

    // spectrum: per band attack at once, release 30 dB/s; peak caps hold 1.2 s, then fall 20 dB/s
    Meter.prototype.updateSpectrum = function (sp, dt, now) {
        var s = this.spec;
        var n = sp && sp.length ? sp.length : (s ? s.v.length : 0);
        if (!n) { return; }
        if (!s || s.v.length != n) { s = this.spec = { v: [], pk: [], at: [] }; for (var i = 0; i < n; ++i) { s.v.push(-100); s.pk.push(-100); s.at.push(0); } }
        for (var j = 0; j < n; ++j) {
            var d = sp ? +sp[j] : -100;
            s.v[j] = d > s.v[j] ? d : Math.max(d, s.v[j] - 30 * dt);
            if (s.v[j] >= s.pk[j]) { s.pk[j] = s.v[j]; s.at[j] = now; }
            else if (now - s.at[j] > 1200) { s.pk[j] = Math.max(s.v[j], s.pk[j] - 20 * dt); }
        }
        if (this.cur && this.cur.rate) { this.rate = +this.cur.rate; }
    };

    // scope: automatic gain from the peak of the picture (up fast, down over ~4 s), in steps of 2x
    Meter.prototype.updateScope = function (sc, dt) {
        if (sc && sc[0]) { this.trace = sc; }
        else if (!sc) { this.trace = null; }
        var pk = 0;
        if (this.trace) {
            for (var c = 0; c < 2; ++c) { for (var i = 0; i < this.trace[c].length; ++i) { pk = Math.max(pk, Math.abs(this.trace[c][i])); } }
        }
        var env = this.scopeEnv || 0;
        env = pk > env ? pk : env + (pk - env) * (1 - Math.exp(-dt / 4));
        this.scopeEnv = env;
        var gain = 1;
        while (gain < 64 && env * gain * 2 < 900) { gain *= 2; }
        this.gain = gain;
    };

    Meter.prototype.size = function () {
        var c = this.c, W = c.clientWidth, H = c.clientHeight, r = root.devicePixelRatio || 1;
        if (!W || !H) { return null; }
        if (c.width !== Math.round(W * r) || c.height !== Math.round(H * r)) {
            c.width = Math.round(W * r);
            c.height = Math.round(H * r);
        }
        var g = c.getContext("2d");
        g.setTransform(r, 0, 0, r, 0, 0);
        return { g: g, W: W, H: H };
    };

    Meter.prototype.draw = function (now) {
        var s = this.size();
        if (!s) { return; }
        s.g.clearRect(0, 0, s.W, s.H);
        if ("bars" == this.o.style) { this.drawBars(s, now); }
        else if ("scope" == this.o.style) { this.drawScope(s); }
        else if ("spectrum" == this.o.style) { this.drawSpectrum(s); }
        else { this.drawNeedles(s, now); }
    };

    function rrect(g, x, y, w, h, r) {
        g.beginPath();
        if (g.roundRect) { g.roundRect(x, y, w, h, r); return; }
        g.moveTo(x + r, y); g.lineTo(x + w - r, y); g.quadraticCurveTo(x + w, y, x + w, y + r);
        g.lineTo(x + w, y + h - r); g.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
        g.lineTo(x + r, y + h); g.quadraticCurveTo(x, y + h, x, y + h - r);
        g.lineTo(x, y + r); g.quadraticCurveTo(x, y, x + r, y);
    }

    Meter.prototype.drawNeedles = function (s, now) {
        var g = s.g, gap = Math.max(8, s.W * 0.03);
        var mw = Math.min((s.W - gap) / 2, s.H * 1.9), mh = Math.min(s.H, mw / 1.9);
        var x0 = (s.W - 2 * mw - gap) / 2, y0 = (s.H - mh) / 2;
        for (var i = 0; i < 2; ++i) { this.face(g, x0 + i * (mw + gap), y0, mw, mh, this.ch[i], i ? "R" : "L", now); }
    };

    Meter.prototype.face = function (g, x, y, w, h, c, name, now) {
        var red = "#ff4b3a";
        var px = x + w / 2, py = y + h * 1.18, R = h * 0.98;
        g.save();
        rrect(g, x, y, w, h, Math.min(10, h * 0.08));
        g.fillStyle = "rgba(10,10,12,0.55)";
        g.fill();
        g.strokeStyle = "rgba(255,255,255,0.14)";
        g.lineWidth = 1;
        g.stroke();
        g.clip();
        function ang(p) { return -SWING + 2 * SWING * p; }
        function pt(a, r) { return [px + r * Math.sin(a), py - r * Math.cos(a)]; }
        // scale arc: white up to 0 VU, red above
        var p0 = vuPos(0), ra = R * 0.8;
        g.lineCap = "butt";
        g.lineWidth = Math.max(1, h * 0.012);
        g.strokeStyle = "rgba(255,255,255,0.6)";
        g.beginPath();
        g.arc(px, py, ra, -Math.PI / 2 + ang(vuPos(-20)), -Math.PI / 2 + ang(p0));
        g.stroke();
        g.lineWidth = Math.max(2, h * 0.045);
        g.strokeStyle = red;
        g.beginPath();
        g.arc(px, py, ra + g.lineWidth / 2 - h * 0.006, -Math.PI / 2 + ang(p0), -Math.PI / 2 + ang(1));
        g.stroke();
        // ticks and numbers
        var fs = Math.max(8, Math.round(h * 0.1));
        g.font = "500 " + fs + "px Roboto, Arial, sans-serif";
        g.textAlign = "center";
        g.textBaseline = "middle";
        for (var k = 0; k < VU_MARKS.length; ++k) {
            var m = VU_MARKS[k], a = ang(vuPos(m)), big = VU_LABELS[String(m)] !== undefined;
            var t1 = pt(a, ra), t2 = pt(a, ra + h * (big ? 0.09 : 0.055));
            g.strokeStyle = m > 0 ? red : "rgba(255,255,255,0.75)";
            g.lineWidth = Math.max(1, h * 0.012);
            g.beginPath(); g.moveTo(t1[0], t1[1]); g.lineTo(t2[0], t2[1]); g.stroke();
            if (big && w > 120) {
                var tp = pt(a, ra + h * 0.17);
                g.fillStyle = m > 0 ? red : "rgba(255,255,255,0.8)";
                g.fillText(VU_LABELS[String(m)], tp[0], tp[1]);
            }
        }
        g.fillStyle = "rgba(255,255,255,0.55)";
        g.font = "600 " + Math.round(fs * 1.15) + "px Roboto, Arial, sans-serif";
        g.fillText("VU", px, y + h * 0.66);
        g.font = "500 " + fs + "px Roboto, Arial, sans-serif";
        g.textAlign = "left";
        g.fillText(name, x + h * 0.07, y + h * 0.88);
        // peak lamp
        var lit = now < c.lamp, lr = Math.max(2.5, h * 0.035);
        g.beginPath();
        g.arc(x + w - h * 0.09, y + h * 0.86, lr, 0, 2 * Math.PI);
        g.fillStyle = lit ? red : "rgba(255,75,58,0.18)";
        if (lit) { g.shadowColor = red; g.shadowBlur = lr * 3; }
        g.fill();
        g.shadowBlur = 0;
        // needle
        var na = ang(Math.max(-0.02, Math.min(1.06, c.x))), tip = pt(na, R * 0.97), base = pt(na, h * 0.3);
        g.strokeStyle = this.o.accent;
        g.lineWidth = Math.max(1.5, h * 0.016);
        g.lineCap = "round";
        g.shadowColor = "rgba(0,0,0,0.6)";
        g.shadowBlur = 3;
        g.beginPath(); g.moveTo(base[0], base[1]); g.lineTo(tip[0], tip[1]); g.stroke();
        g.restore();
    };

    Meter.prototype.drawBars = function (s, now) {
        var g = s.g, W = s.W, H = s.H;
        var fs = Math.max(9, Math.min(22, Math.round(H * 0.2)));
        var lab = fs * 1.4, scaleH = fs * 1.5;
        var bh = Math.max(4, (H - scaleH - 6) / 2), x0 = lab, bw = W - lab - fs * 0.6;
        var seg = Math.max(2, Math.round(bh * 0.3)), step = seg + 2;
        var n = Math.max(10, Math.floor(bw / step));
        g.font = "500 " + fs + "px Roboto, Arial, sans-serif";
        g.textBaseline = "middle";
        for (var i = 0; i < 2; ++i) {
            var c = this.ch[i], y = i * (bh + 6);
            g.textAlign = "left";
            g.fillStyle = "rgba(255,255,255,0.6)";
            g.fillText(i ? "R" : "L", 0, y + bh / 2);
            var lit = barPos(c.bar) * n, pk = Math.min(n - 1, Math.floor(barPos(c.peak) * n));
            for (var k = 0; k < n; ++k) {
                var p = (k + 0.5) / n, col = p > barPos(-3) ? "#ff4b3a" : p > barPos(-12) ? "#f5c542" : this.o.accent;
                var on = k < lit || (k == pk && c.peak > -60);
                g.globalAlpha = on ? 1 : 0.13;
                g.fillStyle = col;
                rrect(g, x0 + k * (bw / n), y, Math.max(2, bw / n - (step - seg)), bh, Math.min(2, seg / 3));
                g.fill();
            }
            g.globalAlpha = 1;
        }
        // scale under the bars
        var sy = 2 * bh + 6 + scaleH / 2 + 1;
        g.textAlign = "center";
        g.fillStyle = "rgba(255,255,255,0.55)";
        for (var m = 0; m < BAR_MARKS.length; ++m) {
            var xm = x0 + barPos(BAR_MARKS[m]) * bw;
            if (bw < 220 && (BAR_MARKS[m] == -40 || BAR_MARKS[m] == -3)) { continue; }
            g.fillText(String(BAR_MARKS[m]), Math.min(W - fs, Math.max(x0 + fs / 2, xm)), sy);
        }
    };

    function panel(g, x, y, w, h) {
        rrect(g, x, y, w, h, Math.min(10, h * 0.06));
        g.fillStyle = "rgba(10,10,12,0.55)";
        g.fill();
        g.strokeStyle = "rgba(255,255,255,0.14)";
        g.lineWidth = 1;
        g.stroke();
    }

    Meter.prototype.drawScope = function (s) {
        var g = s.g, W = s.W, H = s.H, fs = Math.max(9, Math.min(18, Math.round(H * 0.075)));
        panel(g, 0.5, 0.5, W - 1, H - 1);
        var px = Math.round(fs * 0.8), top = Math.round(fs * 0.6), bottom = Math.round(fs * 1.9);
        var x0 = px, y0 = top, w = W - 2 * px, h = H - top - bottom, cy = y0 + h / 2;
        // graticule 10 x 8 divisions, centre lines with small ticks
        g.lineWidth = 1;
        g.strokeStyle = "rgba(255,255,255,0.09)";
        g.beginPath();
        for (var i = 0; i <= 10; ++i) { var gx = Math.round(x0 + i * w / 10) + 0.5; g.moveTo(gx, y0); g.lineTo(gx, y0 + h); }
        for (var j = 0; j <= 8; ++j) { var gy = Math.round(y0 + j * h / 8) + 0.5; g.moveTo(x0, gy); g.lineTo(x0 + w, gy); }
        g.stroke();
        g.strokeStyle = "rgba(255,255,255,0.22)";
        g.beginPath();
        g.moveTo(x0, Math.round(cy) + 0.5); g.lineTo(x0 + w, Math.round(cy) + 0.5);
        g.moveTo(Math.round(x0 + w / 2) + 0.5, y0); g.lineTo(Math.round(x0 + w / 2) + 0.5, y0 + h);
        for (var k = 0; k <= 50; ++k) {
            var tx = Math.round(x0 + k * w / 50) + 0.5, ty = Math.round(y0 + k * h / 40) + 0.5;
            g.moveTo(tx, cy - 3); g.lineTo(tx, cy + 3);
            if (k <= 40) { g.moveTo(x0 + w / 2 - 3, ty); g.lineTo(x0 + w / 2 + 3, ty); }
        }
        g.stroke();
        var cols = [this.o.accent, "rgba(255,255,255,0.8)"], tr = this.trace, gain = this.gain || 1;
        g.save();
        g.beginPath(); g.rect(x0, y0, w, h); g.clip();
        g.lineJoin = "round";
        for (var c = 1; c >= 0; --c) {
            g.strokeStyle = cols[c];
            g.lineWidth = Math.max(1.2, h * 0.008);
            g.shadowColor = cols[c];
            g.shadowBlur = 4;
            g.beginPath();
            var n = tr && tr[c] ? tr[c].length : 0;
            if (!n) { g.moveTo(x0, cy); g.lineTo(x0 + w, cy); }
            for (var p = 0; p < n; ++p) {
                var x = x0 + p * w / (n - 1), y = cy - tr[c][p] / 1000 * gain * h / 2;
                if (p) { g.lineTo(x, y); } else { g.moveTo(x, y); }
            }
            g.stroke();
        }
        g.restore();
        // readouts
        g.shadowBlur = 0;
        g.font = "500 " + fs + "px Roboto, Arial, sans-serif";
        g.textBaseline = "middle";
        var ry = H - bottom / 2;
        g.textAlign = "left";
        g.fillStyle = cols[0]; g.fillText("L", x0, ry);
        g.fillStyle = cols[1]; g.fillText("R", x0 + fs * 1.2, ry);
        g.fillStyle = "rgba(255,255,255,0.6)";
        g.fillText("2 ms/div", x0 + fs * 3, ry);
        g.textAlign = "right";
        // vertical: one division = 1/4 of full scale / gain
        var dbdiv = 20 * Math.log10(0.25 / gain);
        g.fillText((gain > 1 ? "\u00d7" + gain + "  " : "") + dbdiv.toFixed(0) + " dBFS/div", x0 + w, ry);
    };

    var SPEC_FREQS = [[50, "50"], [100, "100"], [200, "200"], [500, "500"], [1000, "1k"], [2000, "2k"], [5000, "5k"], [10000, "10k"], [20000, "20k"]];

    Meter.prototype.drawSpectrum = function (s) {
        var g = s.g, W = s.W, H = s.H, fs = Math.max(9, Math.min(18, Math.round(H * 0.075)));
        panel(g, 0.5, 0.5, W - 1, H - 1);
        var left = Math.round(fs * 2.4), right = Math.round(fs * 0.8), top = Math.round(fs * 0.7), bottom = Math.round(fs * 1.9);
        var x0 = left, y0 = top, w = W - left - right, h = H - top - bottom, floor = -80;
        function yOf(d) { return y0 + h * Math.min(1, Math.max(0, d / floor)); }
        g.font = "500 " + fs + "px Roboto, Arial, sans-serif";
        g.textBaseline = "middle";
        g.lineWidth = 1;
        for (var d = 0; d >= floor; d -= 10) {
            var yy = Math.round(yOf(d)) + 0.5;
            g.strokeStyle = d == 0 ? "rgba(255,75,58,0.35)" : "rgba(255,255,255,0.08)";
            g.beginPath(); g.moveTo(x0, yy); g.lineTo(x0 + w, yy); g.stroke();
            if (d % 20 == 0) {
                g.textAlign = "right";
                g.fillStyle = "rgba(255,255,255,0.55)";
                g.fillText(String(d), x0 - fs * 0.4, yy);
            }
        }
        var sp = this.spec, rate = this.rate || 44100, topF = Math.min(20000, rate / 2 * 0.95);
        function xOf(f) { return x0 + w * Math.log(f / 20) / Math.log(topF / 20); }
        g.textAlign = "center";
        g.fillStyle = "rgba(255,255,255,0.55)";
        for (var k = 0; k < SPEC_FREQS.length; ++k) {
            var f = SPEC_FREQS[k][0];
            if (f > topF * 1.01) { continue; }
            var fx = xOf(f);
            g.strokeStyle = "rgba(255,255,255,0.08)";
            g.beginPath(); g.moveTo(Math.round(fx) + 0.5, y0); g.lineTo(Math.round(fx) + 0.5, y0 + h); g.stroke();
            if (w > 260 || k % 2 == 0) { g.fillText(SPEC_FREQS[k][1], Math.min(x0 + w - fs, Math.max(x0 + fs, fx)), H - bottom / 2); }
        }
        if (!sp) { return; }
        var n = sp.v.length, bw = w / n, gap = Math.max(1, Math.round(bw * 0.2));
        for (var i = 0; i < n; ++i) {
            var x = x0 + i * bw, v = sp.v[i], yv = yOf(v);
            if (v > floor) {
                var grad = g.createLinearGradient(0, y0 + h, 0, y0);
                grad.addColorStop(0, this.o.accent);
                grad.addColorStop(0.75, this.o.accent);
                grad.addColorStop(0.9, "#f5c542");
                grad.addColorStop(1, "#ff4b3a");
                g.fillStyle = grad;
                g.fillRect(Math.round(x + gap / 2), yv, Math.max(1, Math.round(bw - gap)), y0 + h - yv);
            }
            if (sp.pk[i] > floor) {
                g.fillStyle = "rgba(255,255,255,0.85)";
                g.fillRect(Math.round(x + gap / 2), Math.round(yOf(sp.pk[i])) - 1, Math.max(1, Math.round(bw - gap)), 2);
            }
        }
    };

    root.VUDraw = {
        // what to ask the service for (?mode=): the scope and the spectrum need extra data
        mode: function (style) { return "scope" == style || "spectrum" == style ? style : ""; },
        create: function (canvas, opts) { return new Meter(canvas, opts); },
        db: db,
        vuPos: vuPos,
        barPos: barPos
    };
})(typeof window !== "undefined" ? window : this);
