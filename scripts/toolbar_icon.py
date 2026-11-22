#!/usr/bin/env python3
import math, re, sys
from shapely.geometry import Polygon, LineString, Point, MultiPolygon
from shapely.ops import unary_union
from shapely import affinity
# Кнопка PangoZip в панели инструментов Finder: глиф-силуэт по логотипу (Pangolin.png).
# Тёмный клубок из чешуи-черепицы, светлая морда внутри круга, тёмная полость с лапками.
# Геометрия считается булевыми операциями shapely и выводится одним контуром без масок:
# PDF с масками NSImage рисует пустым. Запуск:
#   uv run --with shapely python scripts/toolbar_icon.py Resources/Icons/ToolbarIcon.svg
#   rsvg-convert -f pdf --dpi-x 72 --dpi-y 72 -w 18 -h 18 Resources/Icons/ToolbarIcon.svg \
#     -o Resources/Icons/ToolbarIcon.pdf
args = dict(a.split("=") for a in sys.argv[2:])
g = lambda k, d: float(args.get(k, d))
K = g("k", 0.9); C0 = 12.3; R = g("R", 11.0); RIM = g("rim", 1.1); GW = g("gw", 0.5)
def tx(x, y): return 12 + (x - C0) * K, 12 + (y - C0) * K
def bez(p0, p1, p2, p3, n=24):
    return [tuple((1-t)**3*a + 3*(1-t)**2*t*b + 3*(1-t)*t**2*c + t**3*d for a, b, c, d in zip(p0, p1, p2, p3))
            for t in (i / n for i in range(1, n + 1))]
def path_pts(d, transform=True):
    # Поддерживаются только M и C — этого хватает для контуров ниже. Координаты — сетка логотипа.
    toks = re.findall(r"[MC]|-?\d+\.?\d*", d); pts = []; i = 0; cur = None; subs = []
    while i < len(toks):
        if toks[i] == "M":
            if pts: subs.append(pts)
            cur = (float(toks[i+1]), float(toks[i+2])); pts = [cur]; i += 3
        elif toks[i] == "C":
            i += 1
            while i < len(toks) and toks[i] not in "MC":
                c = [(float(toks[i+2*j]), float(toks[i+2*j+1])) for j in range(3)]
                pts += bez(cur, *c); cur = c[2]; i += 6
    subs.append(pts)
    if transform: subs = [[tx(*p) for p in s] for s in subs]
    return subs
head_d = ("M10.0,7.9 C9.7,7.3 9.4,6.6 8.6,6.6 C8.0,6.6 7.6,7.0 7.5,7.4 "
          "C5.6,7.9 3.6,9.4 2.6,11.2 C2.0,12.3 1.5,13.2 1.4,13.9 "
          "C1.3,14.6 2.1,15.0 2.8,14.8 C4.6,14.2 6.6,13.0 8.0,12.2 C8.8,11.7 9.6,11.2 10.1,10.5 "
          "C10.6,9.6 10.5,8.6 10.0,7.9")
cav_d = ("M2.6,15.5 C4.4,17.2 7.8,17.6 10.2,16.4 C12.2,15.4 12.9,13.1 11.9,11.5 C11.3,10.6 10.7,10.3 10.2,10.4 "
         "C9.6,11.4 8.4,12.4 6.0,13.8 C4.6,14.6 3.6,15.0 2.6,15.5")
paw_d = "M9.0,12.2 C8.5,12.8 8.4,13.6 8.8,14.3 M10.2,12.1 C9.8,12.8 9.8,13.6 10.2,14.3"
ear_d = "M8.9,7.6 C8.9,7.2 9.2,7.0 9.5,7.2"
L = g("L", 4.8); W = g("W", 3.6); tilt = g("tilt", 22)
def leaf(r, a):
    t = math.radians(a)
    bx, by = 12 + r*math.cos(t), 12 + r*math.sin(t)
    ux, uy = -math.sin(t), math.cos(t); vx, vy = math.cos(t), math.sin(t)
    c, s = math.cos(math.radians(tilt)), math.sin(math.radians(tilt))
    ux, uy, vx, vy = ux*c + vx*s, uy*c + vy*s, -ux*s + vx*c, -uy*s + vy*c
    P = lambda u, v: (bx + u*ux + v*vx, by + u*uy + v*vy)
    w = W / 2
    p = [P(0, -w), P(-0.45*L, -w), P(-0.45*L, w), P(0, w), P(0.45*L, w), P(0.8*L, 0.25*w), P(0.75*L, 0),
         P(0.8*L, -0.25*w), P(0.45*L, -w), P(0, -w)]
    pts = [p[0]] + bez(p[0], p[1], p[2], p[3]) + bez(p[3], p[4], p[5], p[6]) + bez(p[6], p[7], p[8], p[9])
    return Polygon(pts).buffer(0)
rows = [(8.8, 0.0), (6.0, 0.5), (3.3, 0.0), (0.8, 0.5)]
items = []
for r, off in rows:
    step = math.degrees(g("gap", 3.0) / max(r, 1.5))
    a = 180 + off * step
    while a < 520: items.append((a, r)); a += step
# Хвост рисуется первым: чешуйки ближе к голове ложатся сверху, как черепица.
items.sort(key=lambda x: -x[0])
disc = Point(12, 12).buffer(R, 256)
region = disc
for a, r in items:
    lf = leaf(r, a)
    region = region.difference(lf.buffer(GW / 2, join_style=1)).union(lf.buffer(-GW / 2, join_style=1))
cav = Polygon(path_pts(cav_d)[0]).buffer(0)
s = GW * 1.3
region = region.difference(cav.buffer(s / 2, join_style=1)).union(cav.buffer(-s / 2, join_style=1))
for sub in path_pts(paw_d):
    region = region.difference(LineString(sub).buffer(0.4, cap_style=1))
region = region.difference(Point(12, 12).buffer(R - RIM, 256).exterior.buffer(GW / 2))
head = Polygon(path_pts(head_d)[0]).buffer(0)
region = region.union(head.buffer(g("ho", 1.7) / 2, join_style=1)).difference(head)
region = region.intersection(disc)
rim = disc.difference(Point(12, 12).buffer(R - RIM, 256))
ex, ey = tx(5.8, 10.0)
eye = affinity.rotate(affinity.scale(Point(ex, ey).buffer(1, 64), 0.55, 0.68), -30, origin=(ex, ey))
nose = Point(*tx(1.75, 14.15)).buffer(0.5, 64)
ear = LineString(path_pts(ear_d)[0]).buffer(0.3, cap_style=1)
final = unary_union([region, rim, eye, nose, ear]).simplify(0.01)
def ring(c): return "M" + " L".join(f"{x:.3f},{y:.3f}" for x, y in list(c.coords)[:-1]) + " Z"
polys = final.geoms if isinstance(final, MultiPolygon) else [final]
d = " ".join(ring(p.exterior) + " " + " ".join(ring(i) for i in p.interiors) for p in polys)
open(sys.argv[1], "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="black" fill-rule="evenodd" d="{d}"/></svg>\n')
