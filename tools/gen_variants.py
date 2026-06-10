#!/usr/bin/env python3
"""Render six case-colour variants and save a comparison grid (_variants_grid.png)."""
import os, math
from PIL import Image, ImageDraw, ImageFont
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)); PROJECT = os.path.dirname(HERE)
SS = 4

# ── fixed module colours (same for every variant) ────────────────────────────
WHITE=(231,236,241,255); BRIGHT=(232,236,240,255); GREY=(154,163,173,255); SIL=(197,202,208,255)
GREEN=(141,198,63,255); AMBER=(232,180,60,255); BLUE=(79,147,196,255); RED=(226,85,78,255)
DKHOLE=(20,24,30,255); SCREEN=(14,18,24,255); TOG=(16,20,26,255)
STEEL=(58,67,79,255); PANEL=(22,26,33,255)
MDARK=(42,49,59,255); MEDGE=(71,81,96,255)  # fixed darks for module internals

# ── helpers (mirror gen_case_icon.py) ────────────────────────────────────────
def P(x,y): return (x*SS,y*SS)
def W(w): return max(1,int(round(w*SS)))
def cap(d,p1,p2,w,fill):
    d.line([p1,p2],fill=fill,width=w); r=w/2
    for (x,y) in (p1,p2): d.ellipse([x-r,y-r,x+r,y+r],fill=fill)

class T:
    def __init__(s,k,dx,dy): s.k=k; s.dx=dx; s.dy=dy
    def x(s,v): return (s.k*v+s.dx)*SS
    def y(s,v): return (s.k*v+s.dy)*SS
    def w(s,v): return max(1,int(round(s.k*v*SS)))
    def r(s,v): return s.k*v*SS

def trr(d,t,x,y,w,h,rad,fill,outline=None,ow=0):
    d.rounded_rectangle([t.x(x),t.y(y),t.x(x+w),t.y(y+h)],radius=t.r(rad),fill=fill,outline=outline,width=t.w(ow) if ow else 0)
def tcap(d,t,x1,y1,x2,y2,w,fill): cap(d,(t.x(x1),t.y(y1)),(t.x(x2),t.y(y2)),t.w(w),fill)
def tcirc(d,t,cx,cy,r,fill): d.ellipse([t.x(cx)-t.r(r),t.y(cy)-t.r(r),t.x(cx)+t.r(r),t.y(cy)+t.r(r)],fill=fill)
def tarc(d,t,cx,cy,r,a0,a1,w,fill): d.arc([t.x(cx)-t.r(r),t.y(cy)-t.r(r),t.x(cx)+t.r(r),t.y(cy)+t.r(r)],a0,a1,fill=fill,width=t.w(w))
def thex(d,t,cx,cy,r,fill):
    pts=[(t.x(cx)+t.r(r)*math.cos(i*math.pi/3),t.y(cy)+t.r(r)*math.sin(i*math.pi/3)) for i in range(6)]; d.polygon(pts,fill=fill)

case_T = T(1.05,-6.35,-6.9)

def draw_modules(d,t,panel=PANEL):
    for px in (38,100,162): trr(d,t,px,68,54,140,7,panel)
    for px,c in ((44,GREEN),(106,AMBER),(168,BLUE)): trr(d,t,px,76,42,6,3,c)
    for ry in (105,125,145): tcap(d,t,46,ry,84,ry,5,WHITE)
    tcirc(d,t,72,105,5.5,GREEN); tcirc(d,t,52,125,5.5,WHITE); tcirc(d,t,76,145,5.5,WHITE)
    trr(d,t,45,166,14,28,3.5,TOG); trr(d,t,71,166,14,28,3.5,TOG)
    tcirc(d,t,52,172,3.2,GREY); tcirc(d,t,52,180,4.6,BRIGHT); tcirc(d,t,78,188,3.2,GREY); tcirc(d,t,78,180,4.6,BRIGHT)
    tarc(d,t,127,125,17,152,270,5,STEEL); tarc(d,t,127,125,17,270,355,5,AMBER); tarc(d,t,127,125,17,355,388,5,RED)
    tcap(d,t,127,125,138,116,3,WHITE); tcirc(d,t,127,125,4,WHITE)
    tcirc(d,t,114,160,7,SIL); tcap(d,t,114,160,110,155,2,MDARK); tcirc(d,t,140,160,7,SIL); tcap(d,t,140,160,144,155,2,MDARK)
    tcirc(d,t,120,186,3,AMBER); tcirc(d,t,134,186,3,SIL)
    trr(d,t,168,96,42,30,4,SCREEN)
    for (wx,wy) in [(172,116),(178,108),(184,116),(190,116),(196,100),(202,109),(207,116)]: tcirc(d,t,wx,wy,2.5,GREEN)
    tcap(d,t,181,131,181,165,3,STEEL); trr(d,t,175,137,12,11,2.5,GREEN); tcap(d,t,177,142.5,185,142.5,2,PANEL)
    tcap(d,t,201,131,201,165,3,STEEL); trr(d,t,195,151,12,11,2.5,MDARK,MEDGE,1); tcap(d,t,197,156.5,205,156.5,2,BRIGHT)
    for jx in (176,202): thex(d,t,jx,188,7,SIL); tcirc(d,t,jx,188,2.5,DKHOLE)

def draw_shell(d,c):
    H=c['HANDLE']; FOOT=c['FOOT']; LATCH=c['LATCH']; EDGE=c['EDGE']
    DARK=c['DARK']; RIB=c['RIB']; RECESS=c['RECESS']; BRACK=c['BRACK']; CATCH=c['CATCH']
    cap(d,P(103,30),P(153,30),W(12),H); cap(d,P(103,30),P(103,52),W(12),H); cap(d,P(153,30),P(153,52),W(12),H)
    cap(d,P(112,28),P(144,28),W(3),(61,70,84,255))
    for (x,y,w,h) in [(34,226,28,13),(92,228,24,11),(140,228,24,11),(194,226,28,13)]:
        d.rounded_rectangle([x*SS,y*SS,(x+w)*SS,(y+h)*SS],radius=4*SS,fill=FOOT)
    for lx in (8,232):
        d.rounded_rectangle([lx*SS,125*SS,(lx+16)*SS,157*SS],radius=4*SS,fill=LATCH,outline=EDGE,width=W(1.5))
    d.rounded_rectangle([11*SS,137*SS,21*SS,144*SS],radius=2*SS,fill=CATCH); d.rounded_rectangle([235*SS,137*SS,245*SS,144*SS],radius=2*SS,fill=CATCH)
    d.rounded_rectangle([16*SS,46*SS,240*SS,230*SS],radius=18*SS,fill=DARK,outline=EDGE,width=W(2))
    for x in (22,27,229,234): cap(d,P(x,92),P(x,184),W(2.5),RIB)
    d.rounded_rectangle([30*SS,60*SS,226*SS,216*SS],radius=12*SS,fill=RECESS)
    for (vx,vy1,vy2,hx1,hx2,hy) in [(26,72,57,30,42,56),(230,72,57,226,214,56),(26,204,219,30,42,220),(230,204,219,226,214,220)]:
        cap(d,P(vx,vy1),P(vx,vy2),W(5),BRACK); cap(d,P(hx1,hy),P(hx2,hy),W(5),BRACK)

# ── palette helper: auto-derive feet/latches/ribs/panels from base colours ────
def pal(dark,edge,recess):
    def dk(col,amt): return tuple(max(5,v-amt) for v in col[:3])+(255,)
    def bl(a,b,t): return tuple(int(a[i]*t+b[i]*(1-t)) for i in range(3))+(255,)
    return dict(DARK=dark,EDGE=edge,RECESS=recess,
                FOOT=dk(dark,20),LATCH=dk(dark,22),RIB=dk(dark,18),BRACK=dk(dark,22),
                HANDLE=dark,CATCH=bl(edge,dark,0.65),
                PANEL=dk(recess,20))

# ── the six variants ──────────────────────────────────────────────────────────
VARIANTS = [
    ("navy",     pal((20,32,62,255),   (40,65,118,255),  (12,22,46,255))),
    ("midnight", pal((28,42,88,255),   (55,82,152,255),  (18,28,64,255))),
    ("ocean",    pal((22,66,110,255),  (45,114,170,255), (14,46,80,255))),
    ("steel",    pal((48,72,104,255),  (86,124,160,255), (32,52,78,255))),
    ("cobalt",   pal((30,62,155,255),  (58,108,210,255), (18,42,118,255))),
    ("slate",    pal((56,76,100,255),  (92,120,150,255), (38,56,76,255))),
]

# ── render ────────────────────────────────────────────────────────────────────
tmpl_path = os.path.join(PROJECT,"art","giants_template.png")
tmpl_base = Image.open(tmpl_path).convert("RGBA").resize((512,512),Image.LANCZOS) if os.path.exists(tmpl_path) else Image.new("RGBA",(512,512),(30,32,34,255))

previews = []
for name,c in VARIANTS:
    img = Image.new("RGBA",(256*SS,256*SS),(0,0,0,0)); d = ImageDraw.Draw(img)
    draw_shell(d,c); draw_modules(d,case_T,panel=c['PANEL'])
    case = img.resize((512,512),Image.LANCZOS)
    tmpl = tmpl_base.copy(); tmpl.alpha_composite(case)
    result = tmpl.convert("RGB")
    fname = "_variant_"+name.replace(" ","_")+".png"
    result.save(os.path.join(PROJECT,fname))
    previews.append((name,result))
    print(f"  {name}")

# ── 2×3 comparison grid ───────────────────────────────────────────────────────
cols,rows,sz,pad,lh = 3,2,256,14,22
gw = cols*sz+(cols+1)*pad; gh = rows*(sz+lh)+(rows+1)*pad
grid = Image.new("RGB",(gw,gh),(18,20,22))
gd = ImageDraw.Draw(grid)
try: font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf",13)
except: font = ImageFont.load_default()
for i,(name,img) in enumerate(previews):
    col=i%cols; row=i//cols
    x=pad+col*(sz+pad); y=pad+row*(sz+lh+pad)
    grid.paste(img.resize((sz,sz),Image.LANCZOS),(x,y))
    gd.text((x+sz//2,y+sz+4),name,fill=(175,180,188),font=font,anchor="mt")
grid.save(os.path.join(PROJECT,"_variants_grid.png"))
print("grid -> _variants_grid.png")
