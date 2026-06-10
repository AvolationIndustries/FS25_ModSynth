#!/usr/bin/env python3
"""
Render ModMixer's case art with Pillow (no SVG rasteriser; mirrors
art/icon_case_master.svg). Two outputs:
  * SHOP icon  (icon_ModMixer.dds) = the full rugged case, 512.
  * MENU glyph (gui/menuIcon.dds)  = JUST the three control modules, scaled to
    fill the icon (no case shell), so the colour reads on the dark side-menu button.
Uncompressed BGRA for LOCAL PREVIEW; the cert build re-encodes DXT1/DXT5.
"""
import os, struct, math
from PIL import Image, ImageDraw
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)); PROJECT = os.path.dirname(HERE)
SRC = os.path.join(PROJECT, "FS25_ModMixer"); GUI = os.path.join(SRC, "gui")
SS = 4

DARK=(48,72,104,255); EDGE=(86,124,160,255); RECESS=(32,52,78,255); PANEL=(12,32,58,255)
FOOT=(28,52,84,255); LATCH=(26,50,82,255); RIB=(30,54,86,255); BRACK=(26,50,82,255)
WHITE=(231,236,241,255); BRIGHT=(232,236,240,255); GREY=(154,163,173,255); SIL=(197,202,208,255)
GREEN=(141,198,63,255); AMBER=(232,180,60,255); BLUE=(79,147,196,255); RED=(226,85,78,255)
DKHOLE=(20,24,30,255); SCREEN=(14,18,24,255); TOG=(16,20,26,255); HANDLE=(48,72,104,255); CATCH=(72,105,140,255)
STEEL=(58,67,79,255)

def P(x,y): return (x*SS, y*SS)
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

def draw_modules(d,t,panel=PANEL):
    for px in (38,100,162): trr(d,t,px,68,54,140,7,panel)
    for px,c in ((44,GREEN),(106,AMBER),(168,BLUE)): trr(d,t,px,76,42,6,3,c)
    for ry in (105,125,145): tcap(d,t,46,ry,84,ry,5,WHITE)
    tcirc(d,t,72,105,5.5,GREEN); tcirc(d,t,52,125,5.5,WHITE); tcirc(d,t,76,145,5.5,WHITE)
    trr(d,t,45,166,14,28,3.5,TOG); trr(d,t,71,166,14,28,3.5,TOG)
    tcirc(d,t,52,172,3.2,GREY); tcirc(d,t,52,180,4.6,BRIGHT); tcirc(d,t,78,188,3.2,GREY); tcirc(d,t,78,180,4.6,BRIGHT)
    tarc(d,t,127,125,17,152,270,5,STEEL); tarc(d,t,127,125,17,270,355,5,AMBER); tarc(d,t,127,125,17,355,388,5,RED)
    tcap(d,t,127,125,138,116,3,WHITE); tcirc(d,t,127,125,4,WHITE)
    tcirc(d,t,114,160,7,SIL); tcap(d,t,114,160,110,155,2,DARK); tcirc(d,t,140,160,7,SIL); tcap(d,t,140,160,144,155,2,DARK)
    tcirc(d,t,120,186,3,AMBER); tcirc(d,t,134,186,3,SIL)
    trr(d,t,168,96,42,30,4,SCREEN)
    for (wx,wy) in [(172,116),(178,108),(184,116),(190,116),(196,100),(202,109),(207,116)]: tcirc(d,t,wx,wy,2.5,GREEN)
    tcap(d,t,181,131,181,165,3,STEEL); trr(d,t,175,137,12,11,2.5,GREEN); tcap(d,t,177,142.5,185,142.5,2,PANEL)
    tcap(d,t,201,131,201,165,3,STEEL); trr(d,t,195,151,12,11,2.5,DARK,EDGE,1); tcap(d,t,197,156.5,205,156.5,2,BRIGHT)
    for jx in (176,202): thex(d,t,jx,188,7,SIL); tcirc(d,t,jx,188,2.5,DKHOLE)

def draw_shell(d):
    cap(d,P(103,30),P(153,30),W(12),HANDLE); cap(d,P(103,30),P(103,52),W(12),HANDLE); cap(d,P(153,30),P(153,52),W(12),HANDLE)
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

def new(): img=Image.new("RGBA",(256*SS,256*SS),(0,0,0,0)); return img,ImageDraw.Draw(img)

GP=(40,46,56,255)  # lighter panel for the glyph so it lifts off the dark side-menu
def draw_glyph2(d):
    def gr(x,y,w,h,rad,fill,outline=None,ow=0): d.rounded_rectangle([x*SS,y*SS,(x+w)*SS,(y+h)*SS],radius=rad*SS,fill=fill,outline=outline,width=W(ow) if ow else 0)
    def gc(x1,y1,x2,y2,w,fill): cap(d,P(x1,y1),P(x2,y2),W(w),fill)
    def gci(cx,cy,r,fill): d.ellipse([(cx-r)*SS,(cy-r)*SS,(cx+r)*SS,(cy+r)*SS],fill=fill)
    def ga(cx,cy,r,a0,a1,w,fill): d.arc([(cx-r)*SS,(cy-r)*SS,(cx+r)*SS,(cy+r)*SS],a0,a1,fill=fill,width=W(w))
    # no panel backgrounds — controls sit on transparent so the sidebar shows through
    # left module: sliders + toggles
    for ry in (50,104,158): gc(16,ry,112,ry,11,WHITE)
    gci(96,50,13,GREEN); gci(46,104,13,WHITE); gci(102,158,13,WHITE)
    gr(30,193,32,55,7,None,WHITE,3); gr(74,193,32,55,7,None,WHITE,3)
    gci(46,207,7,GREY); gci(46,221,10,BRIGHT); gci(90,235,7,GREY); gci(90,221,10,BRIGHT)
    # right module: rpm gauge + dials. The gauge's "steel" sweep and the dial needle
    # lines were dark-on-dark (invisible idle, dots-only when selected) — WHITE now
    # so the full gauge ring + needles read in every state; amber/red tip unchanged.
    ga(191,84,52,152,270,9,WHITE); ga(191,84,52,270,355,9,AMBER); ga(191,84,52,355,388,9,RED)
    gc(191,84,225,58,6,WHITE); gci(191,84,7,WHITE)
    gci(164,192,19,SIL); gc(164,192,153,180,4,WHITE); gci(218,192,19,SIL); gc(218,192,229,180,4,WHITE)
    gci(180,234,6,AMBER); gci(206,234,6,SIL)

def draw_glyph_mono(d):
    # White line-art for the FS25 menu tab. The game tints ONE icon: white when
    # idle, dark when the tab is selected (green). So everything is pure white on
    # transparent; the engine handles the inverse-contrast state itself.
    WH=(255,255,255,255)
    def box(x,y,w,h,rad,sw): d.rounded_rectangle([x*SS,y*SS,(x+w)*SS,(y+h)*SS],radius=rad*SS,outline=WH,width=W(sw))
    def trk(x1,y1,x2,y2,w): cap(d,P(x1,y1),P(x2,y2),W(w),WH)
    def dot(cx,cy,r,col=WH): d.ellipse([(cx-r)*SS,(cy-r)*SS,(cx+r)*SS,(cy+r)*SS],fill=col)
    def ring(cx,cy,r,sw): d.ellipse([(cx-r)*SS,(cy-r)*SS,(cx+r)*SS,(cy+r)*SS],outline=WH,width=W(sw))
    def arc(cx,cy,r,a0,a1,w,col=WH): d.arc([(cx-r)*SS,(cy-r)*SS,(cx+r)*SS,(cy+r)*SS],a0,a1,fill=col,width=W(w))
    # left: sliders + toggles
    box(8,8,114,240,16,4)
    for ry in (54,104,154): trk(24,ry,104,ry,7)
    dot(88,54,11,GREEN); dot(42,104,11); dot(96,154,11)   # winner knob = green accent
    box(32,190,26,52,7,3); box(74,190,26,52,7,3)
    dot(45,203,6); dot(87,229,6)
    # right: rpm gauge + dials
    box(134,8,114,240,16,4)
    arc(191,88,48,152,345,7); arc(191,88,48,345,368,7,AMBER); arc(191,88,48,368,388,7,RED)
    trk(191,88,223,64,5); dot(191,88,7)
    ring(164,196,17,4); trk(164,196,154,185,4); ring(218,196,17,4); trk(218,196,228,185,4)

def draw_header(d):
    # Header-badge glyph: four mixing FADERS (the verticals cropped from the menu
    # glyph). White on transparent → shows white on the green header badge.
    WH=(255,255,255,255)
    for x in (52,104,156,208): cap(d,P(x,38),P(x,218),W(6),WH)
    for (cx,cy) in [(52,82),(104,152),(156,104),(208,174)]:
        d.rounded_rectangle([(cx-15)*SS,(cy-9)*SS,(cx+15)*SS,(cy+9)*SS],radius=4*SS,fill=WH)
        cap(d,P(cx-9,cy),P(cx+9,cy),W(3),DARK)

case_T = T(1.05, -6.35, -6.9)

img,d=new(); draw_shell(d); draw_modules(d,case_T); case=img.resize((512,512),Image.LANCZOS)
img,d=new(); draw_glyph2(d); glyph=img.resize((256,256),Image.LANCZOS)

def write_dds(path,im):
    # Cert-allowed compressed DDS (DXT5 / BC3): smooth alpha, ~4:1 smaller than raw.
    im.save(path, pixel_format="DXT5")

write_dds(os.path.join(SRC,"icon_ModMixer.dds"),case)
write_dds(os.path.join(GUI,"menuIcon.dds"),glyph)
imgh,dh=new(); draw_header(dh); header=imgh.resize((256,256),Image.LANCZOS)
write_dds(os.path.join(GUI,"headerIcon.dds"),header)
bh=Image.new("RGBA",(256,256),(141,198,63,255)); bh.alpha_composite(header); bh.convert("RGB").resize((200,200)).save(os.path.join(PROJECT,"_header_preview.png"))
# previews: UNSELECTED (white glyph on dark menu) + SELECTED (engine tints it dark on FS green)
def show(sel,size):
    a=np.array(glyph.resize((size,size),Image.LANCZOS))
    if sel: a[:,:,:3]=(a[:,:,:3].astype(float)*0.16).astype("uint8"); bgc=(141,198,63,255)
    else: bgc=(26,28,33,255)
    b=Image.new("RGBA",(size,size),bgc); b.alpha_composite(Image.fromarray(a,"RGBA")); return b.convert("RGB")
show(False,256).resize((280,280)).save(os.path.join(PROJECT,"_glyph_unselected.png"))
show(True,256).resize((280,280)).save(os.path.join(PROJECT,"_glyph_selected.png"))
show(False,52).resize((176,176),Image.NEAREST).save(os.path.join(PROJECT,"_glyph_u56.png"))
show(True,52).resize((176,176),Image.NEAREST).save(os.path.join(PROJECT,"_glyph_s56.png"))
tmpl_path=os.path.join(PROJECT,"art","giants_template.png")
if os.path.exists(tmpl_path):
    tmpl=Image.open(tmpl_path).convert("RGBA").resize((512,512),Image.LANCZOS)
else:
    tmpl=Image.new("RGBA",(512,512),(30,32,34,255))
tmpl.alpha_composite(case)
tmpl.convert("RGB").resize((512,512)).save(os.path.join(PROJECT,"_case_preview.png"))
print("wrote case 512 + glyph 256 (modules-only) + previews")
