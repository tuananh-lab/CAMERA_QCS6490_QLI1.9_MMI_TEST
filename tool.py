#!/usr/bin/env python3
# =============================================================================
#  HSP-117 MMI TOOL  -  Camera Bullet QCS6490 (QLI 1.9)
#  Click a button -> a terminal opens -> enter the device IP there -> the test runs.
#  No connection logic here: everything is handled by mmi/run_mmi.sh.
# =============================================================================
import os
import re
import shlex
import shutil
import subprocess
import queue
import threading
import time
import tkinter as tk
from tkinter import messagebox, ttk

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_SH = os.path.join(TOOL_DIR, "config.sh")
RUN_MMI = os.path.join(TOOL_DIR, "mmi", "run_mmi.sh")
REPORT_DIR = os.path.join(TOOL_DIR, "reports")
LOG_DIR = os.path.join(REPORT_DIR, "log")        # log thông tin thiết bị (trùng LOG_DIR trong config.sh)


def read_config(*keys):
    if not os.path.isfile(CONFIG_SH):
        return {}
    printer = "; ".join('printf "%%s\\n" "${%s}"' % k for k in keys)
    try:
        out = subprocess.check_output(
            ["bash", "-c", ". '%s' >/dev/null 2>&1; %s" % (CONFIG_SH, printer)],
            text=True, timeout=10, stderr=subprocess.DEVNULL)
    except Exception:
        return {}
    values = out.splitlines()
    return {k: (values[i].strip() if i < len(values) else "") for i, k in enumerate(keys)}


CFG = read_config("PRODUCT_NAME", "PRODUCT_CODE", "TRANSPORT", "CLUSTERS", "DEVICE_IP", "REBOOT_WAIT")
PRODUCT_NAME = CFG.get("PRODUCT_NAME") or "Camera"
PRODUCT_CODE = CFG.get("PRODUCT_CODE") or "HSP-117"
DEVICE_IP = (CFG.get("DEVICE_IP") or "").strip()      # static IP: ONE line in config.sh (DEVICE_IP)
REBOOT_WAIT = int(CFG.get("REBOOT_WAIT") or 180)
# Test clusters come from config.sh (CLUSTERS / CLUSTER_<NAME>)
CLUSTERS = (CFG.get("CLUSTERS") or "CARRIER-KIMQ IMAGE-SENSOR LED").split()
CLUSTER_INFO = {                      # short hint shown next to each cluster name
    "CARRIER-KIMQ": "carrier + KIMQ board",
    "IMAGE-SENSOR": "image sensor board",
    "LED": "LED driver + IR/Laser",
}

FONT = "DejaVu Sans"
FONT_MONO = "DejaVu Sans Mono"

TERMINALS = [
    ("gnome-terminal", lambda c: ["gnome-terminal", "--maximize", "--", "bash", "-c", c]),
    ("konsole", lambda c: ["konsole", "-e", "bash", "-c", c]),
    ("xfce4-terminal", lambda c: ["xfce4-terminal", "-x", "bash", "-c", c]),
    ("mate-terminal", lambda c: ["mate-terminal", "--", "bash", "-c", c]),
    ("tilix", lambda c: ["tilix", "-e", "bash", "-c", c]),
    ("x-terminal-emulator", lambda c: ["x-terminal-emulator", "-e", "bash", "-c", c]),
    ("xterm", lambda c: ["xterm", "-fa", "Monospace", "-fs", "11", "-e", "bash", "-c", c]),
]


def open_in_terminal(command):
    for name, builder in TERMINALS:
        if shutil.which(name):
            try:
                subprocess.Popen(builder(command))
            except Exception as exc:
                messagebox.showerror("Cannot open terminal", str(exc))
            return
    messagebox.showerror("No terminal found",
                         "Please install one of: gnome-terminal, konsole, xfce4-terminal, xterm.")


def run_mmi(args):
    cmd = "cd %s; TRANSPORT=%s MMI_PAUSE_END=1 bash %s %s" % (
        shlex.quote(TOOL_DIR), shlex.quote(transport_var.get()), shlex.quote(RUN_MMI), args)
    open_in_terminal(cmd)


def setup_pc():
    cmd = "cd %s; TRANSPORT=%s MMI_PAUSE_END=1 bash %s" % (
        shlex.quote(TOOL_DIR), shlex.quote(transport_var.get()), shlex.quote(os.path.join(TOOL_DIR, "setup_pc.sh")))
    open_in_terminal(cmd)


MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}([:-]?[0-9A-Fa-f]{2}){5}$")


def write_mac():
    """Write MAC button: check the format, ask for confirmation, then open a terminal that runs
    mmi/run_mmi.sh --write-mac <MAC> (build bin file -> push -> ethtool -E -> verify -> reboot -> verify)."""
    mac = mac_var.get().strip()
    if not MAC_RE.match(mac):
        messagebox.showerror("Invalid MAC address",
                             "Please enter 12 hex digits, for example 74:25:84:C0:0F:08")
        return
    mac_hex = re.sub(r"[:-]", "", mac).upper()
    mac_show = ":".join(mac_hex[i:i + 2] for i in range(0, 12, 2))
    if not messagebox.askyesno("Write MAC",
                               "Write MAC address %s to the device?\n\n"
                               "This overwrites the Ethernet EEPROM and the device will reboot." % mac_show):
        return
    mac_var.set(mac_show)
    run_mmi("--write-mac %s" % shlex.quote(mac_hex))


SERIAL_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def norm_mac(text):
    return re.sub(r"[^0-9A-Fa-f]", "", text or "").upper()


# ---- Device Info panel: Read / Reboot run WITHOUT a terminal, the result is shown in the window ----
busy = {"on": False, "t0": 0.0, "what": ""}
results = queue.Queue()          # worker thread -> UI thread (the worker never touches Tk)


def set_status(text, color="gray"):
    status_var.set(text)
    status_lbl.configure(foreground=color)


def set_check(label, text, color):
    label.configure(text=text, foreground=color)


def show_info(info):
    """Fill the three rows, and compare Serial / MAC with what is typed in the Write boxes."""
    chip_ro.set(info.get("CHIPID") or "(not set)")
    ser_ro.set(info.get("SERIAL") or "(not set)")
    mac_ro.set(info.get("MAC") or "-")
    set_check(chip_chk, "", "gray")
    exp = serial_var.get().strip()
    if not exp:
        set_check(ser_chk, "", "gray")
    elif exp == info.get("SERIAL", ""):
        set_check(ser_chk, "OK - matches", "#1a7f37")
    else:
        set_check(ser_chk, "DIFFERENT from input", "#cf222e")
    exp = norm_mac(mac_var.get())
    if not exp:
        set_check(mac_chk, "", "gray")
    elif exp == norm_mac(info.get("MAC", "")):
        set_check(mac_chk, "OK - matches", "#1a7f37")
    else:
        set_check(mac_chk, "DIFFERENT from input", "#cf222e")


def clear_info():
    for var in (chip_ro, ser_ro, mac_ro):
        var.set("-")
    for lbl in (chip_chk, ser_chk, mac_chk):
        set_check(lbl, "", "gray")


def tick():
    if busy["on"]:
        set_status("%s ... %ds" % (busy["what"], time.time() - busy["t0"]), "#9a6700")
        root.after(1000, tick)


FAIL_HINTS = [      # (text in run_mmi.sh output, short English explanation shown in the window)
    ("Không kết nối được", "cannot connect to %s - check power, network cable, static IP, adbd/sshd" % DEVICE_IP),
    ("KHÔNG KẾT NỐI LẠI", "device did not come back after reboot - check power and static IP"),
    ("LỆNH REBOOT KHÔNG", "the reboot command had no effect (device still running)"),
    ("KHÔNG ĐỌC ĐƯỢC CHIP ID", "Chip ID is empty (getprop ro.chipid returned nothing)"),
    ("KHÔNG CÓ LỆNH getprop", "getprop not found on the device"),
    ("KHÔNG phản hồi", "no response in time"),
    ("TRANSPORT không hợp lệ", "invalid connection type"),
]


def explain_failure(out):
    lines = [l.strip() for l in out.splitlines() if l.strip() and not l.startswith("@@")]
    last = (lines[-1] if lines else "no output")[:110]
    for key, text in FAIL_HINTS:
        if key in out:
            return "%s  [%s]" % (text, last) if last not in text else text
    return last


def save_gui_log(action, out, rc):
    """Keep the raw output of the last Read / Reboot so a failure can be inspected: reports/log/gui_last_run.log"""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, "gui_last_run.log"), "w", encoding="utf-8") as fh:
            fh.write("%s  %s --ip %s  rc=%s  transport=%s\n\n%s\n" % (
                time.strftime("%F %T"), action, DEVICE_IP, rc, transport_var.get(), out))
    except OSError:
        pass


def poll_result():
    try:
        out, rc, action = results.get_nowait()
    except queue.Empty:
        if busy["on"]:
            root.after(200, poll_result)
        return
    finish_info(out, rc, action)


def finish_info(out, rc, action):
    busy["on"] = False
    for b in info_buttons:
        b.configure(state="normal")
    out = ANSI_RE.sub("", out or "")
    save_gui_log(action, out, rc)
    info = {}
    for line in out.splitlines():
        if line.startswith("@@") and "=" in line:
            key, val = line[2:].split("=", 1)
            info[key] = val.strip()
    if rc == 0 and "CHIPID" in info:      # Chip ID / Serial trống vẫn là đọc thành công (chưa ghi)
        show_info(info)
        done = "Rebooted, device is back" if action == "--reboot" else "Read OK"
        set_status("%s  (%s, %s)" % (done, DEVICE_IP, time.strftime("%H:%M:%S")), "#1a7f37")
        return
    clear_info()
    set_status("FAILED: " + explain_failure(out) + "  (log: reports/log/gui_last_run.log)", "#cf222e")


def run_info(action, what, timeout):
    if busy["on"]:
        return
    if not DEVICE_IP:
        set_status("DEVICE_IP is empty - set it in config.sh (one line)", "#cf222e")
        return
    busy.update(on=True, t0=time.time(), what=what)
    for b in info_buttons:
        b.configure(state="disabled")
    clear_info()
    tick()
    poll_result()
    env = dict(os.environ, MMI_MACHINE="1", MMI_NONINTERACTIVE="1", TRANSPORT=transport_var.get())

    def work():
        try:
            p = subprocess.run(["bash", RUN_MMI, action, "--ip", DEVICE_IP, "--skip-setup"], cwd=TOOL_DIR, env=env,
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
            out, rc = p.stdout + p.stderr, p.returncode
        except subprocess.TimeoutExpired:
            out, rc = "KHÔNG phản hồi trong %ds" % timeout, 124
        except Exception as exc:
            out, rc = "LỖI: %s" % exc, 1
        results.put((out, rc, action))

    threading.Thread(target=work, daemon=True).start()


def read_ids():
    """Read Chip ID button: getprop ro.chipid / ro.serialno + MAC, shown in the window (no terminal)."""
    run_info("--read-id", "Connecting and reading", 60)


def reboot_device():
    """Reboot button: reboot, wait until the device is back, then show Chip ID / Serial / MAC again."""
    if messagebox.askyesno("Reboot Device",
                           "Reboot %s now?\n\nWait until the window shows the device is back (about 1-2 minutes)." % DEVICE_IP):
        run_info("--reboot", "Rebooting", REBOOT_WAIT + 90)


def write_serial():
    """Write Serial button: check the format, ask for confirmation, then run --write-serial <SERIAL> in a terminal
    (echo SERIAL=<SERIAL> > devinfo partition, then read it back). The new serial shows after a reboot."""
    serial = serial_var.get().strip()
    if not SERIAL_RE.match(serial):
        messagebox.showerror("Invalid serial",
                             "Use only letters, digits, '_' or '-' (max 32 characters), for example ABC12345")
        return
    if not messagebox.askyesno("Write Serial",
                               "Write serial %s to the device?\n\n"
                               "This overwrites the devinfo partition. "
                               "Press Reboot Device afterwards to apply it." % serial):
        return
    run_mmi("--write-serial %s" % shlex.quote(serial))


selected_cluster = {"name": None}


def pick_cluster(name):
    """Called when a cluster is chosen in the dropdown: the button now shows the cluster name."""
    selected_cluster["name"] = name
    cluster_text.set(name)
    cluster_btn.focus_set()          # so that Enter works right away


def show_cluster_menu(_event=None):
    """Dropdown list right under the Test Cluster box (no extra window)."""
    menu = tk.Menu(root, tearoff=0, font=(FONT, 11))
    for name in CLUSTERS:
        info = CLUSTER_INFO.get(name)
        menu.add_command(label="%s  -  %s" % (name, info) if info else name,
                         command=lambda n=name: pick_cluster(n))
    try:
        menu.tk_popup(cluster_box.winfo_rootx(), cluster_box.winfo_rooty() + cluster_box.winfo_height())
    finally:
        menu.grab_release()


def run_selected_cluster(_event=None):
    """Double-click or Enter on the cluster box runs the chosen cluster."""
    name = selected_cluster["name"]
    if not name:
        messagebox.showinfo("Test Cluster", "Please choose a cluster first.\nClick the arrow next to the box.")
    else:
        run_mmi("--cluster %s" % shlex.quote(name))
    return "break"


def open_reports():
    os.makedirs(REPORT_DIR, exist_ok=True)
    for opener in ("xdg-open", "nautilus", "thunar", "dolphin"):
        if shutil.which(opener):
            subprocess.Popen([opener, REPORT_DIR])
            return
    messagebox.showinfo("Reports folder", REPORT_DIR)


# ------------------------------ UI ------------------------------
# Layout (2 columns, height follows the content so it fits small screens):
#   Device Info | Write
#   Run Test    | Tools
root = tk.Tk()
root.title("%s Tool - %s" % (PRODUCT_CODE, PRODUCT_NAME))
root.resizable(False, False)

style = ttk.Style()
style.configure("TButton", padding=7, font=(FONT, 11, "bold"))
style.configure("TLabel", font=(FONT, 11))
style.configure("TRadiobutton", font=(FONT, 11))
style.configure("TLabelframe.Label", font=(FONT, 10, "bold"))

PAD_L, PAD_R = (22, 8), (8, 22)          # outer padding of the left / right column
BOX_PAD = (18, 8, 18, 12)                # inner padding of every box
root.columnconfigure(0, weight=1, uniform="col")
root.columnconfigure(1, weight=1, uniform="col")

# ---- header ----
ttk.Label(root, text="%s MMI TOOL" % PRODUCT_CODE, font=("Arial", 20, "bold")).grid(
    row=0, column=0, columnspan=2, pady=(14, 0))
ttk.Label(root, text=PRODUCT_NAME, font=(FONT, 10), foreground="gray").grid(row=1, column=0, columnspan=2)
ttk.Separator(root, orient="horizontal").grid(row=2, column=0, columnspan=2, sticky="ew", padx=22, pady=(8, 8))

# Connection: transport + static IP (the IP comes from ONE line in config.sh: DEVICE_IP)
transport_var = tk.StringVar(value=CFG.get("TRANSPORT") or "adb")
conn_row = ttk.Frame(root)
conn_row.grid(row=3, column=0, columnspan=2, pady=(0, 6))
ttk.Label(conn_row, text="Connection:").pack(side="left", padx=4)
ttk.Radiobutton(conn_row, text="adb", value="adb", variable=transport_var).pack(side="left", padx=4)
ttk.Radiobutton(conn_row, text="ssh", value="ssh", variable=transport_var).pack(side="left", padx=4)
ttk.Label(conn_row, text="      Device IP:").pack(side="left", padx=4)
ttk.Label(conn_row, text=DEVICE_IP or "not set (config.sh)", font=(FONT_MONO, 11, "bold"),
          foreground="black" if DEVICE_IP else "#cf222e").pack(side="left")

# ---- Device Info (left, top): Read / Reboot, result shown here (no terminal) ----
info_box = ttk.LabelFrame(root, text=" Device Info ", padding=BOX_PAD)
info_box.grid(row=4, column=0, sticky="nsew", padx=PAD_L, pady=(0, 16))
info_box.columnconfigure(0, weight=1, uniform="ibtn")
info_box.columnconfigure(1, weight=1, uniform="ibtn")
read_btn = ttk.Button(info_box, text="Read Chip ID / Serial", command=read_ids)
read_btn.grid(row=0, column=0, sticky="ew", padx=(0, 4), pady=(0, 8))
reboot_btn = ttk.Button(info_box, text="Reboot Device", command=reboot_device)
reboot_btn.grid(row=0, column=1, sticky="ew", padx=(4, 0), pady=(0, 8))
info_buttons = [read_btn, reboot_btn]

chip_ro, ser_ro, mac_ro = tk.StringVar(value="-"), tk.StringVar(value="-"), tk.StringVar(value="-")
rows = ttk.Frame(info_box)
rows.grid(row=1, column=0, columnspan=2, sticky="ew")
rows.columnconfigure(1, weight=1)
chk_labels = []
for r, (name, var) in enumerate((("Chip ID", chip_ro), ("Serial", ser_ro), ("MAC", mac_ro))):
    ttk.Label(rows, text=name, width=7).grid(row=r, column=0, sticky="w", pady=2)
    ttk.Entry(rows, textvariable=var, state="readonly", font=(FONT_MONO, 11)).grid(
        row=r, column=1, sticky="ew", pady=2, ipady=3)
    lbl = ttk.Label(rows, text="", font=(FONT, 9, "bold"), width=19)
    lbl.grid(row=r, column=2, sticky="w", padx=(6, 0))
    chk_labels.append(lbl)
chip_chk, ser_chk, mac_chk = chk_labels
status_var = tk.StringVar(value="Press Read to get the device info")
status_lbl = ttk.Label(info_box, textvariable=status_var, font=(FONT, 9), foreground="gray", wraplength=400)
status_lbl.grid(row=2, column=0, columnspan=2, sticky="w", pady=(8, 0))

# ---- Write (right, top): MAC and Serial, each with its own button (the result opens in a terminal) ----
mac_box = ttk.LabelFrame(root, text=" Write ", padding=BOX_PAD)
mac_box.grid(row=4, column=1, sticky="nsew", padx=PAD_R, pady=(0, 16))
mac_box.columnconfigure(0, weight=1)
mac_var = tk.StringVar()
serial_var = tk.StringVar()
ttk.Label(mac_box, text="MAC, e.g. 74:25:84:C0:0F:08", foreground="gray", font=(FONT, 9)).grid(row=0, column=0, sticky="w")
ttk.Entry(mac_box, textvariable=mac_var, font=(FONT_MONO, 11)).grid(row=1, column=0, sticky="ew", pady=(2, 6), ipady=3)
ttk.Button(mac_box, text="Write MAC", command=write_mac).grid(row=2, column=0, sticky="ew", pady=(0, 10))
ttk.Label(mac_box, text="Serial, e.g. ABC12345", foreground="gray", font=(FONT, 9)).grid(row=3, column=0, sticky="w")
ttk.Entry(mac_box, textvariable=serial_var, font=(FONT_MONO, 11)).grid(row=4, column=0, sticky="ew", pady=(2, 6), ipady=3)
ttk.Button(mac_box, text="Write Serial", command=write_serial).grid(row=5, column=0, sticky="ew")
ttk.Label(mac_box, text="After writing, press Reboot Device and check Device Info.", font=(FONT, 9),
          foreground="gray", wraplength=400).grid(row=6, column=0, sticky="w", pady=(8, 0))
mac_box.rowconfigure(6, weight=1)

# ---- Run Test (left, bottom) ----
run_box = ttk.LabelFrame(root, text=" Run Test ", padding=BOX_PAD)
run_box.grid(row=5, column=0, sticky="nsew", padx=PAD_L, pady=(0, 8))
run_box.columnconfigure(0, weight=1, uniform="run")
run_box.columnconfigure(1, weight=1, uniform="run")
ttk.Button(run_box, text="MMI Test 117", command=lambda: run_mmi("--all")).grid(
    row=0, column=0, sticky="ew", padx=(0, 4))
cluster_box = ttk.Frame(run_box)                 # [ cluster name ][ v ]
cluster_box.grid(row=0, column=1, sticky="ew", padx=(4, 0))
cluster_box.columnconfigure(0, weight=1)
cluster_text = tk.StringVar(value="Test Cluster")
cluster_btn = ttk.Button(cluster_box, textvariable=cluster_text)
cluster_btn.grid(row=0, column=0, sticky="ew")
for seq in ("<Double-Button-1>", "<Return>", "<KP_Enter>"):
    cluster_btn.bind(seq, run_selected_cluster)
ttk.Button(cluster_box, text="\u25BC", width=3, command=show_cluster_menu).grid(row=0, column=1, padx=(2, 0))
ttk.Label(run_box, text="Cluster: click the arrow to choose, then double-click it (or press Enter) to run.",
          font=(FONT, 9), foreground="gray", wraplength=400).grid(row=1, column=0, columnspan=2, sticky="w", pady=(8, 0))

# ---- Tools (right, bottom) ----
tools_box = ttk.LabelFrame(root, text=" Tools ", padding=BOX_PAD)
tools_box.grid(row=5, column=1, sticky="nsew", padx=PAD_R, pady=(0, 8))
tools_box.columnconfigure(0, weight=1)
ttk.Button(tools_box, text="Check / Install PC Tools", command=setup_pc).grid(row=0, column=0, sticky="ew", pady=(0, 8))
ttk.Button(tools_box, text="Open Reports Folder", command=open_reports).grid(row=1, column=0, sticky="ew")

# Fixed width, height = what the content needs (never cut off, also on small screens)
root.update_idletasks()
root.geometry("%dx%d" % (940, int(root.winfo_reqheight())))

root.mainloop()