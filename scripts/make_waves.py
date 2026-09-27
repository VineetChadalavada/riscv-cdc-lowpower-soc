"""minisoc -- draw waveform figures for the docs, from the real simulations.

    python scripts/make_waves.py            all figures
    python scripts/make_waves.py fifo       figures whose name contains "fifo"

Every figure in docs/waves/ comes out of an actual simulation run, not a
drawing: for each one this script

  1. re-runs an existing simulation snapshot (built by scripts/run_sim.ps1,
     so run that first) with a Tcl script that records just the signals the
     figure needs into a VCD file;
  2. finds the moment worth looking at by searching the recording -- "the
     first write the UART stalls", "the cycle power goes off" -- rather than
     by hard-coded times, so the figure follows the RTL if it changes;
  3. draws it as SVG, with markers and measured latencies.

No third-party packages: the VCD reader and the SVG writer are below.
"""

import os
import re
import subprocess
import sys
from html import escape

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "docs", "waves")
XSIM = os.path.join(os.environ.get("XILINX_VIVADO", r"C:\Xilinx\Vivado\2021.1"), "bin", "xsim.bat")


# ===========================================================================
# VCD reading
# ===========================================================================
def read_vcd(path):
    """Return {full.signal.name: [(time_ps, value_str), ...]}.

    value_str is a string of '0'/'1'/'x'/'z', most significant bit first.
    """
    ids = {}            # vcd id -> list of names (one id can have several)
    widths = {}
    scope = []
    changes = {}
    t = 0
    scale = 1
    with open(path) as f:
        text = f.read()
    tokens = iter(text.split())
    for tok in tokens:
        if tok == "$timescale":
            spec = []
            for tok2 in tokens:
                if tok2 == "$end":
                    break
                spec.append(tok2)
            m = re.match(r"(\d+)\s*([munpf]?s)", "".join(spec))
            unit = {"s": 10**12, "ms": 10**9, "us": 10**6, "ns": 10**3, "ps": 1, "fs": 0.001}[m.group(2)]
            scale = int(m.group(1)) * unit
        elif tok == "$scope":
            next(tokens)
            scope.append(next(tokens))
            next(tokens)
        elif tok == "$upscope":
            scope.pop()
            next(tokens)
        elif tok == "$var":
            _kind, width, vid, name = next(tokens), int(next(tokens)), next(tokens), next(tokens)
            for tok2 in tokens:
                if tok2 == "$end":
                    break
            full = ".".join(scope + [name])
            ids.setdefault(vid, []).append(full)
            widths[full] = width
            changes[full] = []
        elif tok.startswith("$"):
            if tok in ("$dumpvars", "$dumpall", "$dumpon", "$dumpoff", "$end"):
                continue
            for tok2 in tokens:        # skip other sections ($comment, $date, ...)
                if tok2 == "$end":
                    break
        elif tok[0] == "#":
            t = int(tok[1:]) * scale
        elif tok[0] in "bB":
            val, vid = tok[1:].lower(), next(tokens)
            for name in ids.get(vid, []):
                changes[name].append((t, val.rjust(widths[name], val[0] if val[0] in "xz" else "0")))
        elif tok[0] in "01xzXZ":
            val, vid = tok[0].lower(), tok[1:]
            for name in ids.get(vid, []):
                changes[name].append((t, val))
    return changes


class Wave:
    """One signal's history, with the lookups the figures need."""

    def __init__(self, name, changes):
        self.name = name
        self.ch = changes

    def at(self, t):
        v = self.ch[0][1] if self.ch else "x"
        for tc, vc in self.ch:
            if tc > t:
                break
            v = vc
        return v

    def edges(self, kind, after=0, value=None):
        """Times of rising/falling edges, value changes, or reaching a value."""
        out = []
        prev = None
        for t, v in self.ch:
            if prev is not None and t > after:
                if kind == "rise" and prev == "0" and v == "1":
                    out.append(t)
                elif kind == "fall" and prev == "1" and v == "0":
                    out.append(t)
                elif kind == "change" and v != prev:
                    out.append(t)
                elif kind == "value" and v != prev and to_int(v) == value:
                    out.append(t)
            prev = v
        return out


def to_int(v):
    return None if any(c in "xz" for c in v) else int(v, 2)


# ===========================================================================
# SVG drawing
# ===========================================================================
LABEL_W, WAVE_W, ROW_H, TOP = 190, 860, 30, 64
C_TEXT, C_WAVE, C_CLK, C_X, C_GRID = "#1f2328", "#0969da", "#6e7781", "#cf222e", "#d0d7de"
C_MARK, C_SPAN, C_GROUP = "#8250df", "#1a7f37", "#57606a"


def fmt_value(v, style, enum=None):
    if any(c in "xz" for c in v):
        return "X"
    n = int(v, 2)
    if style == "hex":
        return f"{n:x}"
    if style == "dec":
        return str(n)
    if style == "ascii":
        return repr(chr(n))[1:-1] if 32 <= n < 127 else f"{n:02x}"
    if style == "enum":
        return enum.get(n, str(n))
    if style == "gray":                 # show a Gray-coded value as the number it stands for
        b = 0
        while n:
            b ^= n
            n >>= 1
        return str(b)
    return str(n)


def draw(fig, waves, t0, t1, markers, spans, path):
    rows = fig["signals"]
    height = TOP + ROW_H * len(rows) + 46
    width = LABEL_W + WAVE_W + 20
    xs = lambda t: LABEL_W + (t - t0) * WAVE_W / (t1 - t0)
    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
             f'viewBox="0 0 {width} {height}" font-family="Consolas, Menlo, monospace" font-size="12">')
    o.append(f'<rect width="{width}" height="{height}" fill="#ffffff"/>')
    o.append(f'<text x="12" y="22" font-size="15" font-weight="bold" fill="{C_TEXT}" '
             f'font-family="Segoe UI, Helvetica, Arial, sans-serif">{escape(fig["title"])}</text>')
    if fig.get("subtitle"):
        o.append(f'<text x="12" y="40" font-size="12" fill="{C_GROUP}" '
                 f'font-family="Segoe UI, Helvetica, Arial, sans-serif">{escape(fig["subtitle"])}</text>')

    # time grid
    step = nice_step((t1 - t0) / 10)
    g = (t0 // step + 1) * step
    ybot = TOP + ROW_H * len(rows)
    while g < t1:
        x = xs(g)
        o.append(f'<line x1="{x:.1f}" y1="{TOP - 6}" x2="{x:.1f}" y2="{ybot}" stroke="{C_GRID}" stroke-width="0.6"/>')
        o.append(f'<text x="{x:.1f}" y="{ybot + 14}" text-anchor="middle" fill="{C_GROUP}" font-size="10">'
                 f'{g / 1000:g} ns</text>')
        g += step

    # rows
    for i, row in enumerate(rows):
        label, key, style = row[0], row[1], row[2]
        y = TOP + i * ROW_H
        hi, lo = y + 6, y + ROW_H - 8
        if style == "group":
            o.append(f'<text x="12" y="{lo}" fill="{C_GROUP}" font-weight="bold" '
                     f'font-family="Segoe UI, Helvetica, Arial, sans-serif">{escape(label)}</text>')
            o.append(f'<line x1="12" y1="{lo + 5}" x2="{LABEL_W + WAVE_W}" y2="{lo + 5}" stroke="{C_GRID}"/>')
            continue
        o.append(f'<text x="18" y="{lo - 2}" fill="{C_TEXT}">{escape(label)}</text>')
        o.append(f'<line x1="{LABEL_W}" y1="{y + ROW_H - 1}" x2="{LABEL_W + WAVE_W}" y2="{y + ROW_H - 1}" '
                 f'stroke="#eaeef2" stroke-width="1"/>')
        w = waves[key]
        bit_index = row[3] if len(row) > 3 and style in ("bit", "clock") else None
        segs = segments(w, t0, t1, bit_index)
        color = C_CLK if style == "clock" else C_WAVE
        if style in ("bit", "clock"):
            pts = []
            for (ta, tb, v) in segs:
                xa, xb = xs(ta), xs(tb)
                if v in ("x", "z"):
                    o.append(f'<rect x="{xa:.1f}" y="{hi}" width="{xb - xa:.1f}" height="{lo - hi}" '
                             f'fill="{C_X}" fill-opacity="0.18" stroke="{C_X}" stroke-width="1"/>')
                    if xb - xa > 14:
                        o.append(f'<text x="{(xa + xb) / 2:.1f}" y="{lo - 5}" text-anchor="middle" '
                                 f'fill="{C_X}" font-size="10">X</text>')
                    if pts:
                        o.append(polyline(pts, color))
                        pts = []
                    continue
                yv = hi if v == "1" else lo
                if pts:
                    pts.append((xa, yv))
                pts += [(xa, yv), (xb, yv)]
            if pts:
                o.append(polyline(pts, color))
        else:
            enum = row[3] if len(row) > 3 else None
            for (ta, tb, v) in segs:
                xa, xb = xs(ta), xs(tb)
                bad = any(c in "xz" for c in v)
                d = min(3, (xb - xa) / 2)
                mid = (hi + lo) / 2
                shape = (f"{xa:.1f},{mid} {xa + d:.1f},{hi} {xb - d:.1f},{hi} {xb:.1f},{mid} "
                         f"{xb - d:.1f},{lo} {xa + d:.1f},{lo}")
                fill = C_X if bad else C_WAVE
                o.append(f'<polygon points="{shape}" fill="{fill}" fill-opacity="{0.18 if bad else 0.07}" '
                         f'stroke="{fill}" stroke-width="1"/>')
                txt = fmt_value(v, style, enum)
                if (xb - xa) > 7.2 * len(txt) + 6:
                    o.append(f'<text x="{(xa + xb) / 2:.1f}" y="{mid + 4}" text-anchor="middle" '
                             f'fill="{C_X if bad else C_TEXT}">{escape(txt)}</text>')

    # markers: vertical lines with a label at the top
    for (label, t) in markers:
        x = xs(t)
        o.append(f'<line x1="{x:.1f}" y1="{TOP - 10}" x2="{x:.1f}" y2="{ybot}" stroke="{C_MARK}" '
                 f'stroke-width="1.2" stroke-dasharray="4,3"/>')
        o.append(f'<text x="{x + 3:.1f}" y="{TOP - 12}" fill="{C_MARK}" font-size="11" '
                 f'font-family="Segoe UI, Helvetica, Arial, sans-serif">{escape(label)}</text>')

    # spans: a measured interval, drawn under the time axis
    for k, (label, ta, tb) in enumerate(spans):
        xa, xb = xs(ta), xs(tb)
        y = ybot + 28 + 12 * k
        o.append(f'<line x1="{xa:.1f}" y1="{y}" x2="{xb:.1f}" y2="{y}" stroke="{C_SPAN}" stroke-width="1.5" '
                 f'marker-start="url(#a)" marker-end="url(#a)"/>')
        fits_right = xb + 6 + 6.2 * len(label) < LABEL_W + WAVE_W + 18
        lx, anchor = (xb + 6, "start") if fits_right else (xa - 6, "end")
        o.append(f'<text x="{lx:.1f}" y="{y + 4}" text-anchor="{anchor}" fill="{C_SPAN}" font-size="11" '
                 f'font-family="Segoe UI, Helvetica, Arial, sans-serif">{escape(label)}</text>')
    o.insert(2, f'<defs><marker id="a" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="5" markerHeight="5" '
                f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{C_SPAN}"/></marker></defs>')
    o.append("</svg>")

    # grow the canvas if spans need the room
    svg = "\n".join(o)
    if spans:
        need = ybot + 28 + 12 * len(spans) + 10
        if need > height:
            svg = svg.replace(f'height="{height}"', f'height="{need}"', 2) \
                     .replace(f'viewBox="0 0 {width} {height}"', f'viewBox="0 0 {width} {need}"')
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)


def polyline(pts, color):
    p = " ".join(f"{x:.1f},{y}" for x, y in pts)
    return f'<polyline points="{p}" fill="none" stroke="{color}" stroke-width="1.4"/>'


def segments(w, t0, t1, bit=None):
    """[(start, end, value)] covering t0..t1, merged where the value repeats."""
    pick = (lambda v: v[-1 - bit] if bit is not None else v)
    out = []
    cur_t, cur_v = t0, pick(w.at(t0))
    for t, v in w.ch:
        if t <= t0:
            continue
        if t >= t1:
            break
        v = pick(v)
        if v != cur_v:
            out.append((cur_t, t, cur_v))
            cur_t, cur_v = t, v
    out.append((cur_t, t1, cur_v))
    return out


def nice_step(raw):
    mag = 10 ** (len(str(int(max(raw, 1)))) - 1)
    for m in (1, 2, 5, 10):
        if m * mag >= raw:
            return m * mag
    return 10 * mag


# ===========================================================================
# running the simulation
# ===========================================================================
def record(fig):
    sim_dir = os.path.join(ROOT, "sim_out", fig["test"])
    if not os.path.isdir(os.path.join(sim_dir, "xsim.dir")):
        sys.exit(f"no snapshot for {fig['test']}: run scripts/run_sim.ps1 {fig['test']} first")
    vcd = os.path.join(sim_dir, f"wave_{fig['name']}.vcd").replace("\\", "/")
    tcl = os.path.join(sim_dir, f"wave_{fig['name']}.tcl")
    paths = sorted({row[1] for row in fig["signals"] if row[2] != "group"} | set(fig.get("extra", [])))
    with open(tcl, "w") as f:
        f.write(f"open_vcd {{{vcd}}}\n")
        f.write("log_vcd [list " + " ".join("{%s}" % p for p in paths) + "]\n")
        f.write(f"run {fig.get('run', 'all')}\n")
        f.write("close_vcd\nquit\n")
    plus = " ".join(f'-testplusarg "{p}"' for p in fig.get("plus", []))
    # forward slashes: Tcl reads "\t" in a Windows path as a tab
    cmd = f'"{XSIM}" snap {plus} -onfinish stop -tclbatch "{tcl.replace(chr(92), "/")}"'
    subprocess.run(cmd, cwd=sim_dir, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(vcd):
        sys.exit(f"xsim did not write {vcd}; see {sim_dir}/xsim.log")
    raw = read_vcd(vcd)
    waves = {}
    for p in paths:
        key = p.strip("/").replace("/", ".")
        hits = [n for n in raw if n.endswith(key) or n.endswith(key.split(".")[-1]) and n.split(".")[-2:] == key.split(".")[-2:]]
        exact = [n for n in raw if n == key]
        name = (exact or hits or [None])[0]
        if name is None:
            sys.exit(f"{p} is not in the recording")
        waves[p] = Wave(name, raw[name])
    return waves


# ===========================================================================
# the figures
# ===========================================================================
PMU_STATES = {0: "RUN", 1: "DRAIN", 2: "ISOLATE", 3: "CLK_OFF", 4: "RESET", 5: "OFF",
              6: "PWR_UP", 7: "CLK_ON", 8: "RELEASE", 9: "UNISO"}
APB_STATES = {0: "IDLE", 1: "SETUP", 2: "ACCESS"}

F = "/tb_async_fifo"
M = "/tb_minisoc"
P = "/tb_power"
C = "/tb_cdc_prims"

FIGURES = [
    # -----------------------------------------------------------------
    dict(name="fifo_crossing", test="fifo_wfast", run="2us",
         title="Async FIFO: one word crossing from a 10 ns clock to a 27 ns clock",
         subtitle="From tb_async_fifo (latency phase). The write pointer crosses as Gray code; rempty falls "
                  "once it arrives. rdata is only meaningful while rempty is low.",
         signals=[
             ("write side", None, "group"),
             ("wclk",        F + "/wclk", "clock"),
             ("winc",        F + "/winc", "bit"),
             ("wdata",       F + "/wdata", "hex"),
             ("wgray",       F + "/dut/wgray", "hex"),
             ("read side", None, "group"),
             ("rclk",        F + "/rclk", "clock"),
             ("wgray_r (synchronized)", F + "/dut/wgray_r", "hex"),
             ("rempty",      F + "/rempty", "bit"),
             ("rinc",        F + "/rinc", "bit"),
             ("rdata",       F + "/rdata", "hex"),
         ],
         find=lambda w: dict(
             t_write=w[F + "/dut/wgray"].edges("change")[1],
             t_arrive=w[F + "/dut/wgray_r"].edges("change")[1],
             t_ready=w[F + "/rempty"].edges("fall")[1]),
         window=lambda e: (e["t_write"] - 30000, e["t_ready"] + 70000),
         markers=lambda e: [("pointer moves", e["t_write"]), ("synchronized", e["t_arrive"]),
                            ("not empty", e["t_ready"])],
         spans=lambda e: [(f"write to readable: {(e['t_ready'] - e['t_write']) / 1000:.1f} ns "
                           f"= {(e['t_ready'] - e['t_write']) / 27000:.1f} read clocks",
                           e["t_write"], e["t_ready"])]),

    # -----------------------------------------------------------------
    dict(name="fifo_full", test="fifo_wfast", run="all",
         title="Async FIFO: filling up",
         subtitle="From tb_async_fifo (fill phase): the writer runs flat out, the reader is slow. "
                  "wfull holds the writer off; nothing is lost.",
         signals=[
             ("wclk",   F + "/wclk", "clock"),
             ("winc",   F + "/winc", "bit"),
             ("wfull",  F + "/wfull", "bit"),
             ("wbin",   F + "/dut/wbin", "dec"),
             ("level (scoreboard)", F + "/level", "dec"),
             ("rclk",   F + "/rclk", "clock"),
             ("rinc",   F + "/rinc", "bit"),
             ("rbin",   F + "/dut/rbin", "dec"),
         ],
         extra=[F + "/rrate"],
         find=lambda w: dict(t_full=w[F + "/wfull"].edges(
             "rise", after=w[F + "/rrate"].edges("value", value=10)[0])[0]),
         window=lambda e: (e["t_full"] - 150000, e["t_full"] + 350000),
         markers=lambda e: [("FIFO full", e["t_full"])],
         spans=lambda e: []),

    # -----------------------------------------------------------------
    dict(name="bridge_access", test="chip_pslow",
         title="One store from the core to the UART, across the clock domains",
         subtitle="From tb_minisoc: a store to 0x1000_0008 (UART divisor). "
                  "Request FIFO -> APB SETUP/ACCESS -> response FIFO -> core.",
         signals=[
             ("core (clk_core, 10 ns)", None, "group"),
             ("clk_core",     M + "/clk_core", "clock"),
             ("dmem_valid",   M + "/dut/dmem_valid", "bit"),
             ("dmem_addr",    M + "/dut/dmem_addr", "hex"),
             ("req_push",     M + "/dut/u_bridge/req_push", "bit"),
             ("rsp_pop",      M + "/dut/u_bridge/rsp_pop", "bit"),
             ("dmem_ready",   M + "/dut/dmem_ready", "bit"),
             ("APB (clk_periph, 27 ns)", None, "group"),
             ("clk_periph",   M + "/clk_periph", "clock"),
             ("bridge state", M + "/dut/u_bridge/state", "enum", APB_STATES),
             ("psel",         M + "/dut/psel", "bit"),
             ("penable",      M + "/dut/penable", "bit"),
             ("paddr",        M + "/dut/paddr", "hex"),
             ("pwdata",       M + "/dut/pwdata", "hex"),
             ("pready",       M + "/dut/pready", "bit"),
         ],
         find=lambda w: dict(
             t_push=w[M + "/dut/u_bridge/req_push"].edges("rise")[0],
             t_psel=w[M + "/dut/psel"].edges("rise")[0],
             t_ready=w[M + "/dut/dmem_ready"].edges("rise",
                     after=w[M + "/dut/u_bridge/rsp_pop"].edges("rise")[0])[0]),
         window=lambda e: (e["t_push"] - 40000, e["t_ready"] + 40000),
         markers=lambda e: [("request pushed", e["t_push"]), ("APB starts", e["t_psel"]),
                            ("core released", e["t_ready"])],
         spans=lambda e: [(f"core waits {(e['t_ready'] - e['t_push']) / 10000:.0f} core cycles",
                           e["t_push"], e["t_ready"])]),

    # -----------------------------------------------------------------
    dict(name="apb_wait_states", test="chip_pslow",
         title="APB wait states: writing to a busy UART",
         subtitle="From tb_minisoc: the 2nd byte ('i') is written while the 1st is still shifting out, "
                  "so the UART holds PREADY low until it is free.",
         signals=[
             ("clk_periph", M + "/clk_periph", "clock"),
             ("psel",       M + "/dut/psel", "bit"),
             ("penable",    M + "/dut/penable", "bit"),
             ("pwdata",     M + "/dut/pwdata", "ascii"),
             ("pready",     M + "/dut/pready", "bit"),
             ("uart busy",  M + "/dut/u_uart/busy", "bit"),
             ("uart_tx",    M + "/dut/uart_tx", "bit"),
         ],
         find=lambda w: dict(
             t_stall=w[M + "/dut/pready"].edges("fall")[0],
             t_go=w[M + "/dut/pready"].edges("rise")[0]),
         window=lambda e: (e["t_stall"] - 200000, e["t_go"] + 300000),
         markers=lambda e: [("PREADY low: UART busy", e["t_stall"]), ("UART free", e["t_go"])],
         spans=lambda e: [(f"{(e['t_go'] - e['t_stall']) / 27000:.0f} wait states", e["t_stall"], e["t_go"])]),

    # -----------------------------------------------------------------
    dict(name="irq_crossing", test="chip_pslow",
         title="The timer interrupt crossing into the core's clock domain",
         subtitle="From tb_minisoc: irq is a level from a flop in clk_periph; "
                  "two flops in clk_core make it safe to use; the core then jumps to the handler at 0x100.",
         signals=[
             ("clk_periph",     M + "/clk_periph", "clock"),
             ("timer irq",      M + "/dut/irq_timer_periph", "bit"),
             ("clk_core",       M + "/clk_core", "clock"),
             ("sync stage 1",   M + "/dut/u_irq_sync/meta", "bit"),
             ("irq_timer_core", M + "/dut/irq_timer_core", "bit"),
             ("fetch address",  M + "/dut/imem_addr", "hex"),
         ],
         find=lambda w: dict(
             t_irq=w[M + "/dut/irq_timer_periph"].edges("rise")[0],
             t_core=w[M + "/dut/irq_timer_core"].edges("rise")[0],
             t_vec=w[M + "/dut/imem_addr"].edges("value", value=0x100)[0]),
         window=lambda e: (e["t_irq"] - 40000, e["t_vec"] + 60000),
         markers=lambda e: [("irq raised", e["t_irq"]), ("seen by core", e["t_core"]),
                            ("handler fetched", e["t_vec"])],
         spans=lambda e: [(f"synchronizer: {(e['t_core'] - e['t_irq']) / 1000:.0f} ns",
                           e["t_irq"], e["t_core"])]),

    # -----------------------------------------------------------------
    dict(name="power_down", test="power_pslow",
         title="Power-down sequence",
         subtitle="From tb_power: after software asks to sleep, one step per clock. "
                  "Isolation first, then clock, reset, and power.",
         signals=[
             ("clk_core (always on)", P + "/clk_core", "clock"),
             ("gclk_core (to core)",  P + "/dut/gclk_core", "clock"),
             ("PMU state",   P + "/dut/u_pmu/state", "enum", PMU_STATES),
             ("iso_en",      P + "/dut/pd_iso_en", "bit"),
             ("clk_en",      P + "/dut/pd_clk_en", "bit"),
             ("core reset_n", P + "/dut/pd_rst_n", "bit"),
             ("pwr_on",      P + "/dut/pd_pwr_on", "bit"),
             ("inside: imem_valid", P + "/dut/u_core_pd/out_domain", "bit", 102),
             ("outside: imem_valid", P + "/dut/imem_valid", "bit"),
         ],
         find=lambda w: dict(
             t_drain=w[P + "/dut/u_pmu/state"].edges("value", value=1)[0],
             t_off=w[P + "/dut/pd_pwr_on"].edges("fall")[0]),
         window=lambda e: (e["t_drain"] - 30000, e["t_off"] + 60000),
         markers=lambda e: [("sleep requested", e["t_drain"]), ("power off", e["t_off"])],
         spans=lambda e: []),

    # -----------------------------------------------------------------
    dict(name="power_up", test="power_pslow",
         title="Wake-up sequence",
         subtitle="From tb_power: the timer interrupt wakes the PMU. Power, wait for it to settle, "
                  "clock (still in reset), release reset, then remove isolation.",
         signals=[
             ("clk_core (always on)", P + "/clk_core", "clock"),
             ("gclk_core (to core)",  P + "/dut/gclk_core", "clock"),
             ("wake (timer irq)", P + "/dut/irq_timer_core", "bit"),
             ("PMU state",   P + "/dut/u_pmu/state", "enum", PMU_STATES),
             ("pwr_on",      P + "/dut/pd_pwr_on", "bit"),
             ("clk_en",      P + "/dut/pd_clk_en", "bit"),
             ("core reset_n", P + "/dut/pd_rst_n", "bit"),
             ("iso_en",      P + "/dut/pd_iso_en", "bit"),
             ("inside: imem_valid", P + "/dut/u_core_pd/out_domain", "bit", 102),
             ("outside: imem_valid", P + "/dut/imem_valid", "bit"),
             ("fetch address", P + "/dut/imem_addr", "hex"),
         ],
         find=lambda w: dict(
             t_wake=w[P + "/dut/irq_timer_core"].edges("rise")[0],
             t_on=w[P + "/dut/pd_pwr_on"].edges("rise")[0],
             t_run=w[P + "/dut/pd_iso_en"].edges("fall")[0]),
         window=lambda e: (e["t_wake"] - 30000, e["t_run"] + 80000),
         markers=lambda e: [("wake", e["t_wake"]), ("power on", e["t_on"]), ("running", e["t_run"])],
         spans=lambda e: [(f"wake-up takes {(e['t_run'] - e['t_wake']) / 10000:.0f} core cycles",
                           e["t_wake"], e["t_run"])]),

    # -----------------------------------------------------------------
    dict(name="metastability", test="cdc_prims_meta", run="all",
         title="Why multi-bit values cross as Gray code",
         subtitle="From tb_cdc_prims, metastability model on. A counter crosses twice. The binary copy jumps "
                  "back from 37 to 35: a mix of old and new bits. The Gray copy only ever moves forward.",
         signals=[
             ("source (10 ns)", None, "group"),
             ("sclk",        C + "/sclk", "clock"),
             ("counter",     C + "/cnt", "dec"),
             ("destination (27 ns)", None, "group"),
             ("dclk",        C + "/dclk", "clock"),
             ("binary copy", C + "/bin_d", "dec"),
             ("Gray copy (decoded)", C + "/gray_d", "gray"),
             ("bad binary values so far", C + "/bin_bad", "dec"),
         ],
         find=lambda w: dict(t_bad=w[C + "/bin_bad"].edges("change")[0]),
         window=lambda e: (e["t_bad"] - 160000, e["t_bad"] + 90000),
         markers=lambda e: [("binary copy jumps backwards", e["t_bad"] - 27000)],
         spans=lambda e: []),
]


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else ""
    os.makedirs(OUT, exist_ok=True)
    for fig in FIGURES:
        if want and want not in fig["name"]:
            continue
        waves = record(fig)
        ev = fig["find"](waves)
        t0, t1 = fig["window"](ev)
        path = os.path.join(OUT, fig["name"] + ".svg")
        draw(fig, waves, t0, t1, fig["markers"](ev), fig["spans"](ev), path)
        print(f"wrote docs/waves/{fig['name']}.svg  ({(t1 - t0) / 1000:.0f} ns window)")


if __name__ == "__main__":
    main()
