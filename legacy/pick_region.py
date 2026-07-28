#!/usr/bin/env python3
"""
Drag a rectangle over the screen area you want to scope.
Prints an ffmpeg crop=W:H:X:Y string to stdout and copies it to the clipboard.

Usage: python3 pick_region.py [scale]
  scale defaults to 2 (Retina). Pass 1 for a non-Retina / external display.
"""
import sys
import subprocess
import tkinter as tk

SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 2

root = tk.Tk()
root.attributes("-fullscreen", True)
root.attributes("-alpha", 0.25)
root.attributes("-topmost", True)
root.configure(bg="grey")

canvas = tk.Canvas(root, cursor="cross", bg="grey", highlightthickness=0)
canvas.pack(fill="both", expand=True)

coords = {}
rect = None


def on_press(e):
    coords["x0"], coords["y0"] = e.x, e.y


def on_drag(e):
    global rect
    if rect:
        canvas.delete(rect)
    rect = canvas.create_rectangle(
        coords["x0"], coords["y0"], e.x, e.y, outline="red", width=2
    )


def on_release(e):
    coords["x1"], coords["y1"] = e.x, e.y
    root.quit()


def on_escape(_e):
    coords.clear()
    root.quit()


canvas.bind("<ButtonPress-1>", on_press)
canvas.bind("<B1-Motion>", on_drag)
canvas.bind("<ButtonRelease-1>", on_release)
root.bind("<Escape>", on_escape)

root.mainloop()
root.destroy()

if "x1" not in coords:
    sys.exit(1)  # user hit Escape, cancel silently

x0, y0, x1, y1 = coords["x0"], coords["y0"], coords["x1"], coords["y1"]
x, y = min(x0, x1), min(y0, y1)
w, h = abs(x1 - x0), abs(y1 - y0)

if w < 2 or h < 2:
    sys.exit(1)  # accidental click, no drag

crop = f"crop={int(w * SCALE)}:{int(h * SCALE)}:{int(x * SCALE)}:{int(y * SCALE)}"
print(crop)

try:
    subprocess.run(["pbcopy"], input=crop.encode())
except FileNotFoundError:
    pass  # pbcopy not available, printed value is still usable
