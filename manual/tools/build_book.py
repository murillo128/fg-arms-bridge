#!/usr/bin/env python3
"""Build the illustrated A4 campaign manual from the verified JSON data.

Artwork is never rewritten. Whole source PNGs are embedded and displayed through
PDF clipping paths; pixel inspection only measures the ink inside each region.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import io
import json
import math
import re
import subprocess
import unicodedata
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image
from pypdf import PdfReader, PdfWriter, PageObject, Transformation
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import A2, A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph


ROOT = Path(__file__).resolve().parents[1]
PAGE_W, PAGE_H = A4
MARGIN = 42.0
TEXT_W = PAGE_W - 2 * MARGIN
PAPER = colors.HexColor("#FAF7ED")
INK = colors.HexColor("#201D18")
FAINT = colors.HexColor("#E9E2D2")
RULE = colors.HexColor("#A79B86")
RED = colors.HexColor("#772B25")
CREAM = colors.HexColor("#F5E7C4")

GROUPS = {
    "blunted": "Contundentes", "bladed": "Hojas", "axes": "Hachas",
    "polearms": "Armas de asta", "bows": "Arcos", "crossbows": "Ballestas",
    "exotic": "Exóticas", "firearms": "Armas de fuego",
}
ARMOR_LABELS = ["Sin arm.", "Cuero", "Malla", "Placas", "Piel", "Escamas", "Caparazón"]
ARMOR_SHORT = ["SA", "CU", "MA", "PL", "PI", "ES", "CA"]
HANDS = {"1h": "Una mano", "2h": "Dos manos", "versatile": "Versátil · 1H / 2H",
         "mounted": "1H montado / 2H", "conditional": "Uso condicionado"}

# Source-pixel regions may override a nominal grid cell when an illustration
# crosses its invisible grid line. Bounds are measured, never raster edits.
REGION_OVERRIDES: dict[str, tuple[int, int, int, int]] = {
    "flail": (381, 565, 694, 963), "morningstar": (784, 502, 985, 994),
    "warhammer": (68, 1015, 322, 1513), "maul": (755, 996, 1001, 1529),
    "halberd": (115, 500, 277, 1024), "lance": (478, 502, 551, 1020),
    "pike": (824, 504, 856, 1021), "whip": (326, 821, 710, 1432),
    "blowgun": (49, 782, 238, 1479), "pistol": (57, 91, 517, 935),
    "blunderbuss": (529, 20, 1041, 1003), "musket": (1052, 10, 1508, 1013),
    "shortbow": (224, 248, 538, 1205), "longbow": (747, 14, 1095, 1239),
    "hand_crossbow": (6, 280, 526, 760),
    "light_crossbow": (498, 110, 1055, 878),
    "heavy_crossbow": (1008, 106, 1534, 922),
    "spear": (173, 10, 228, 496), "quarterstaff": (488, 9, 537, 497),
    "glaive": (815, 2, 889, 499),
    "club": (78, 20, 314, 484), "greatclub": (424, 5, 595, 514),
    "light_hammer": (781, 110, 981, 460), "mace": (85, 508, 282, 977),
    "war_pick": (391, 1024, 620, 1508),
    "dagger": (121, 79, 252, 456), "sickle": (418, 89, 678, 464),
    "greatsword": (782, 1, 941, 520), "longsword": (106, 516, 267, 1015),
    "shortsword": (461, 601, 590, 994), "scimitar": (788, 551, 921, 1028),
    "rapier": (115, 1030, 251, 1531),
    "handaxe": (166, 248, 440, 830), "battleaxe": (635, 57, 936, 938),
    "greataxe": (1065, 7, 1515, 995), "trident": (152, 1029, 252, 1528),
    "javelin": (147, 31, 213, 747), "sling": (390, 55, 677, 721),
    "dart": (784, 136, 909, 682), "shuriken": (712, 936, 1016, 1258),
}
REGION_POLYGONS = {
    "light_crossbow": [(498,110),(1000,110),(1000,300),(1055,340),(1055,878),(535,878),(535,470),(498,440)],
    "heavy_crossbow": [(1008,106),(1534,106),(1534,922),(1055,922),(1055,315),(1008,290)],
}


def load_json(name):
    return json.loads((ROOT / "data" / name).read_text(encoding="utf-8"))


def esc(text):
    return html.escape(str(text), quote=False)


def num(value):
    return f"{value:g}".replace(".", ",")


def register_fonts():
    font_root = ROOT / "fonts"
    manifest = json.loads((font_root / "manifest.json").read_text(encoding="utf-8"))
    hashes = {}
    for entry in manifest["fonts"]:
        path = font_root / entry["file"]
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != entry["sha256"]:
            raise ValueError("Bundled font hash mismatch: " + entry["file"])
        if not (font_root / entry["notice"]).is_file():
            raise ValueError("Missing font license: " + entry["notice"])
        hashes[entry["file"]] = digest
    for name, suffix in [("Body", "Regular"), ("Body-Bold", "Bold"), ("Body-Italic", "Italic"), ("Body-BoldItalic", "BoldItalic")]:
        pdfmetrics.registerFont(TTFont(name, str(font_root / f"LiberationSerif-{suffix}.ttf")))
    pdfmetrics.registerFontFamily("Body", normal="Body", bold="Body-Bold", italic="Body-Italic", boldItalic="Body-BoldItalic")
    face = pdfmetrics.EmbeddedType1Face(str(font_root / "URWBookman-Demi.afm"), str(font_root / "URWBookman-Demi.pfb"))
    pdfmetrics.registerTypeFace(face)
    pdfmetrics.registerFont(pdfmetrics.Font("Display", face.name, "WinAnsiEncoding"))
    return hashes


class Book:
    def __init__(self, output: Path, audit_path: Path):
        font_hashes = register_fonts()
        self.output = output
        self.audit_path = audit_path
        self.manual = load_json("manual_text.json")
        self.tables = load_json("tables.json")
        self.data = load_json("weapons.json")
        self.manifest = load_json("image_manifest.json")
        self.weapons = self.data["weapons"]
        self.sections = {s["id"]: s for s in self.manual["sections"]}
        self.examples = {e["id"]: e for e in self.manual["examples"]}
        self.version = self.tables["engine_version"]
        assert self.manual["version"] == self.version + " alpha", "Manual and engine versions differ"
        assert self.data["document_version"] == self.version, "Weapon and engine versions differ"
        assert len(self.weapons) == 40
        self.group_order = self.tables["family_order"]
        self.groups = defaultdict(list)
        for weapon in self.weapons:
            weapon = dict(weapon)
            weapon["ordinal"] = len(self.groups[weapon["group"]])
            self.groups[weapon["group"]].append(weapon)
        self.weapons = [w for group in self.group_order for w in self.groups[group]]
        assert [w["id"] for w in self.weapons] == [w["id"] for w in self.data["weapons"]]
        front = ["cover", "contents", "attack", "protection", "open_rolls", "damage_types", "scope", "armory"]
        back = ["fantasy_grounds", "index", "sources", "quick_reference"]
        self.page_ids = front + ["weapon_" + w["id"] for w in self.weapons] + back
        self.page_for = {pid: i + 1 for i, pid in enumerate(self.page_ids)}
        self.group_pages = {g: [self.page_for["weapon_" + self.groups[g][0]["id"]],
                                self.page_for["weapon_" + self.groups[g][-1]["id"]]] for g in self.group_order}
        self.audit = {"schema_version": 1, "version": self.version, "page_size": [PAGE_W, PAGE_H],
                      "coordinate_system": "PDF points, bottom-left origin", "minimum_table_font": 9.5,
                      "source_hashes": {}, "font_hashes": font_hashes,
                      "page_map": self.page_for, "pages": [], "errors": []}
        for filename in ["weapons.json", "manual_text.json", "tables.json", "image_manifest.json"]:
            self.audit["source_hashes"][filename] = hashlib.sha256((ROOT / "data" / filename).read_bytes()).hexdigest()
        self._image_cache = {}
        self._image_readers = {}
        self._page = None
        output.parent.mkdir(parents=True, exist_ok=True)
        audit_path.parent.mkdir(parents=True, exist_ok=True)
        self.temp = output.with_name(output.stem + ".building.pdf")
        self.c = canvas.Canvas(str(self.temp), pagesize=A4, pageCompression=1, invariant=1)
        self.c.setTitle("El nuevo Arms Law — Armas & armaduras para D&D 2024")
        self.c.setAuthor("O.R.T.I.C.E. · Arms Bridge · Cuaderno de campaña")
        self.c.setSubject("Tablas experimentales originales; edición " + self.version + " alpha")

    def record(self, role, box, **extra):
        x, y, w, h = [round(float(v), 3) for v in box]
        if x < -0.1 or y < -0.1 or x + w > PAGE_W + .1 or y + h > PAGE_H + .1:
            raise ValueError(f"Outside page {self._page['id']}: {role}, {(x,y,w,h)}")
        entry = {"role": role, "bounds": [x, y, w, h], **extra}
        self._page["boxes"].append(entry)
        return entry

    def start(self, pid, running_title, *, cover=False):
        expected = self.page_for[pid]
        assert self.c.getPageNumber() == expected, (pid, self.c.getPageNumber(), expected)
        self._page = {"id": pid, "page": expected, "title": running_title, "boxes": [], "tables": [], "images": []}
        self.audit["pages"].append(self._page)
        self.c.bookmarkPage(pid)
        self.c.addOutlineEntry(running_title, pid, level=0, closed=False)
        self.c.setFillColor(PAPER)
        self.c.rect(0, 0, PAGE_W, PAGE_H, stroke=0, fill=1)
        if not cover:
            self.line(MARGIN, PAGE_H - 34, PAGE_W - MARGIN, PAGE_H - 34, width=.45)
            self.text("EL NUEVO ARMS LAW", MARGIN, PAGE_H - 27, font="Body-Bold", size=9)
            self.text(running_title.upper(), PAGE_W-MARGIN, PAGE_H-27, font="Body", size=9, align="right")
            self.line(MARGIN, 41, PAGE_W-MARGIN, 41, width=.45)
            self.text("Tablas originales de campaña · " + self.version + " alpha", MARGIN, 27, size=9)
            self.text(str(expected), PAGE_W-MARGIN, 27, font="Body-Bold", size=10, align="right")

    def end(self):
        self.c.showPage()

    def line(self, x1, y1, x2, y2, *, width=.5, color=INK):
        self.c.setStrokeColor(color)
        self.c.setLineWidth(width)
        self.c.line(x1, y1, x2, y2)

    def text(self, text, x, baseline, *, font="Body", size=11, color=INK, align="left", role="text", max_width=None):
        text = str(text)
        width = pdfmetrics.stringWidth(text, font, size)
        if max_width is not None and width > max_width + .05:
            raise ValueError(f"Text too wide on {self._page['id']}: {text!r}, {width:.1f}>{max_width:.1f}")
        left = x - width if align == "right" else x-width/2 if align == "center" else x
        self.c.setFont(font, size)
        self.c.setFillColor(color)
        self.c.drawString(left, baseline, text)
        self.record(role, [left, baseline-size*.23, width, size*1.15], text=text, font=font, size=size)
        return width

    def para(self, text, x, top, width, *, size=11.3, leading=14.5, font="Body", align=TA_LEFT, max_height=None, markup=False, color=INK, role="paragraph"):
        style = ParagraphStyle("p", fontName=font, fontSize=size, leading=leading, alignment=align,
                               textColor=color, allowWidows=0, allowOrphans=0, splitLongWords=1)
        p = Paragraph(text if markup else esc(text), style)
        actual_w, height = p.wrap(width, PAGE_H)
        if max_height is not None and height > max_height + .1:
            raise ValueError(f"Paragraph overflows {self._page['id']}: {height:.1f}>{max_height:.1f}: {text[:80]}")
        p.drawOn(self.c, x, top-height)
        self.record(role, [x, top-height, width, height], text=re.sub("<[^>]+>", "", text), font=font, size=size)
        return top-height

    def paras(self, paragraphs, x, top, width, *, gap=9, bottom=58, **kw):
        y = top
        for paragraph in paragraphs:
            y = self.para(paragraph, x, y, width, max_height=y-bottom, **kw)-gap
        return y

    def heading(self, title, *, subtitle=None, top=None, size=25):
        top = PAGE_H - 66 if top is None else top
        self.text(title, MARGIN, top, font="Display", size=size, max_width=TEXT_W)
        y = top-20
        if subtitle:
            y = self.para(subtitle, MARGIN, y, TEXT_W, size=10.3, leading=13)-9
        self.line(MARGIN, y-1, PAGE_W-MARGIN, y-1, width=1.1)
        return y-20

    def subheading(self, title, x, top, width=TEXT_W):
        self.text(title, x, top-12, font="Display", size=13, max_width=width)
        return top-23

    def panel(self, title, paragraphs, x, top, width, *, size=11.1, leading=14, padding=12, fill=FAINT):
        wrapped = []
        total = 26 + 2*padding
        for p in paragraphs:
            style=ParagraphStyle("measure",fontName="Body",fontSize=size,leading=leading)
            item=Paragraph(esc(p),style)
            h=item.wrap(width-2*padding,PAGE_H)[1]
            total += h+7
            wrapped.append((p,h))
        total -= 7
        self.c.setFillColor(fill)
        self.c.setStrokeColor(RULE)
        self.c.setLineWidth(.5)
        self.c.rect(x,top-total,width,total,fill=1,stroke=1)
        self.record("panel",[x,top-total,width,total],title=title)
        self.text(title,x+padding,top-padding-12,font="Display",size=12.5,max_width=width-2*padding)
        y=top-padding-29
        for p,h in wrapped:
            y=self.para(p,x+padding,y,width-2*padding,size=size,leading=leading)-7
        return top-total

    def simple_table(self, headers, rows, x, top, widths, *, font_size=10.5, leading=13, min_height=29, table_id="reference"):
        total_w=sum(widths)
        y=top
        heights=[]
        for row in [headers]+rows:
            hs=[]
            for value,w in zip(row,widths):
                st=ParagraphStyle("measure",fontName="Body",fontSize=font_size,leading=leading)
                hs.append(Paragraph(esc(str(value)),st).wrap(w-12,PAGE_H)[1]+12)
            heights.append(max(min_height,max(hs)))
        table_audit={"id":table_id,"bounds":[x,top-sum(heights),total_w,sum(heights)],"rows":[]}
        self._page["tables"].append(table_audit)
        for ri,(row,h) in enumerate(zip([headers]+rows,heights)):
            self.c.setFillColor(INK if ri==0 else (FAINT if ri%2 else PAPER))
            self.c.rect(x,y-h,total_w,h,fill=1,stroke=0)
            xx=x
            for value,w in zip(row,widths):
                self.para(str(value),xx+6,y-6,w-12,size=font_size,leading=leading,
                          font="Body-Bold" if ri==0 else "Body",color=PAPER if ri==0 else INK,max_height=h-9)
                xx+=w
            table_audit["rows"].append({"cells":[str(v) for v in row],"bounds":[x,y-h,total_w,h]})
            self.line(x,y-h,x+total_w,y-h,width=.25,color=RULE)
            y-=h
        self.record("table",table_audit["bounds"],id=table_id)
        return y

    def image_reader(self, path):
        # ImageReader makes PDF XObject names depend on image content, not the
        # checkout's absolute filename. The original PNG and clips stay intact.
        if path not in self._image_readers:
            self._image_readers[path] = ImageReader(str(path))
        return self._image_readers[path]

    def image_info(self, group):
        if group not in self._image_cache:
            path=ROOT/self.manifest["plates"][group]["file"]
            with Image.open(path) as im:
                rgba=np.asarray(im.convert("RGBA"))
            # Analysis only: locate visible dark ink; never create a raster crop.
            mask=(rgba[:,:,3]>18)&(np.max(rgba[:,:,:3],axis=2)<225)
            self._image_cache[group]=(path,rgba.shape[1],rgba.shape[0],mask)
        return self._image_cache[group]

    def weapon_image(self, weapon, box):
        x,y,w,h=box
        group=weapon["group"]
        path,iw,ih,mask=self.image_info(group)
        plate=self.manifest["plates"][group]
        col=weapon["ordinal"]%plate["columns"]
        row=weapon["ordinal"]//plate["columns"]
        cell=(round(col*iw/plate["columns"]),round(row*ih/plate["rows"]),
              round((col+1)*iw/plate["columns"]),round((row+1)*ih/plate["rows"]))
        region=REGION_OVERRIDES.get(weapon["id"],cell)
        x0,y0,x1,y1=region
        local_mask=mask[y0:y1,x0:x1]
        polygon=REGION_POLYGONS.get(weapon["id"])
        if polygon:
            yy,xx=np.mgrid[y0:y1,x0:x1]
            xx=xx+.5;yy=yy+.5
            inside=np.zeros(local_mask.shape,dtype=bool)
            previous=polygon[-1]
            for point in polygon:
                ax,ay=previous;bx,by=point
                if by!=ay:
                    inside^=((ay>yy)!=(by>yy))&(xx<(bx-ax)*(yy-ay)/(by-ay)+ax)
                previous=point
            local_mask=local_mask&inside
        coords=np.argwhere(local_mask)
        if not len(coords):
            raise ValueError("Empty artwork region: "+weapon["id"])
        miny,minx=coords.min(axis=0)
        maxy,maxx=coords.max(axis=0)
        bounds=(int(x0+minx),int(y0+miny),int(x0+maxx+1),int(y0+maxy+1))
        bx0,by0,bx1,by1=bounds
        scale=min(w/(bx1-bx0),h/(by1-by0))*.965
        ink_w=(bx1-bx0)*scale
        ink_h=(by1-by0)*scale
        ink_x=x+(w-ink_w)/2
        ink_y=y+(h-ink_h)/2
        draw_x=ink_x-bx0*scale
        draw_y=ink_y-(ih-by1)*scale
        self.c.saveState()
        target=self.c.beginPath();target.rect(x,y,w,h)
        self.c.clipPath(target,stroke=0,fill=0)
        source=self.c.beginPath()
        if polygon:
            for i,(px,py) in enumerate(polygon):
                operation=source.moveTo if i==0 else source.lineTo
                operation(draw_x+px*scale,draw_y+(ih-py)*scale)
            source.close()
        else:
            source.rect(draw_x+x0*scale,draw_y+(ih-y1)*scale,(x1-x0)*scale,(y1-y0)*scale)
        self.c.clipPath(source,stroke=0,fill=0)
        self.c.drawImage(self.image_reader(path),draw_x,draw_y,width=iw*scale,height=ih*scale,mask="auto")
        self.c.restoreState()
        image_audit={"weapon":weapon["id"],"group":group,"source":str(path.relative_to(ROOT)),
                     "nominal_cell":list(cell),"source_region":list(region),"ink_bounds":list(bounds),
                     "source_polygon":polygon,"bounds":list(box),"ink_pdf_bounds":[ink_x,ink_y,ink_w,ink_h],"method":"whole PNG plus PDF clips"}
        self._page["images"].append(image_audit)
        self.record("illustration",box,weapon=weapon["id"])

    def cover(self):
        self.start("cover","Portada",cover=True)
        path=ROOT/self.manifest["cover"]["file"]
        with Image.open(path) as im:
            iw,ih=im.size
        scale=max(PAGE_W/iw,PAGE_H/ih)
        self.c.drawImage(self.image_reader(path),(PAGE_W-iw*scale)/2,(PAGE_H-ih*scale)/2,iw*scale,ih*scale)
        # The illustration already contains its red stripe. An opaque overlay
        # here would cut the axe blade where it crosses into that stripe.
        logo=ROOT/self.manifest.get("logo",{}).get("file","assets/logo.png")
        if logo.exists():
            with Image.open(logo) as im:
                logo_w,logo_h=im.size
            scale_logo=min(72/logo_w,94/logo_h)
            dw,dh=logo_w*scale_logo,logo_h*scale_logo
            self.c.setFillColor(colors.white)
            self.c.rect(3,69,76,dh+8,fill=1,stroke=0)
            self.c.drawImage(self.image_reader(logo),5+(72-dw)/2,73,dw,dh,mask="auto")
            self._page["images"].append({"source":str(logo.relative_to(ROOT)),"bounds":[3,69,76,dh+8],"role":"publisher_logo","sha256":hashlib.sha256(logo.read_bytes()).hexdigest()})
        else:
            for letter,baseline in [("A",PAGE_H-55),("B",PAGE_H-85)]:
                self.text(letter,24.5,baseline,font="Display",size=28,color=CREAM,align="center")
        self.c.saveState();self.c.translate(29,200 if logo.exists() else 116);self.c.rotate(90)
        self.c.setFillColor(CREAM);self.c.setFont("Body-Bold",11)
        self.c.drawString(0,0,"TABLAS DE CAMPAÑA")
        self.c.restoreState()
        def shadow(text,baseline,size):
            # Keep all lettering to the right of the archer's bow. The shorter
            # subtitle also ends before the golem's tall crest.
            left=221
            self.text(text,left+2.1,baseline-2.8,font="Display",size=size,color=colors.black)
            self.text(text,left,baseline,font="Display",size=size,color=CREAM)
        shadow("EL NUEVO",PAGE_H-29,17)
        shadow("Arms Law",PAGE_H-85,65)
        shadow("Armas & armaduras",PAGE_H-112,20)
        shadow("Para D&D 2024",PAGE_H-135,15)
        self.c.setFillColor(INK);self.c.rect(49,0,PAGE_W-49,42,fill=1,stroke=0)
        self.text("TABLAS EXPERIMENTALES ORIGINALES",(PAGE_W+49)/2,24,font="Body-Bold",size=10,color=CREAM,align="center")
        self.text("Arms Bridge · "+self.version+" alpha",(PAGE_W+49)/2,10,size=9,color=CREAM,align="center")
        self._page["images"].append({"source":str(path.relative_to(ROOT)),"bounds":[0,0,PAGE_W,PAGE_H],"sha256":hashlib.sha256(path.read_bytes()).hexdigest()})
        self.end()

    def contents(self):
        self.start("contents","Sumario")
        y=self.heading("Sumario",subtitle="Armas & armaduras para D&D 2024 · Edición experimental "+self.version+" alpha")
        y=self.paras(["Un cuaderno de campaña inspirado en la relación entre ataque, daño y protección de Arms Law de Rolemaster Classic. Las matrices y fórmulas aquí impresas son originales. Este manual acompaña a Arms Bridge y puede consultarse también en mesa."],MARGIN,y,TEXT_W,size=12,leading=15.7)
        left=MARGIN;right=PAGE_W/2+12;col_w=(TEXT_W-24)/2
        y-=14
        yl=self.subheading("Las reglas",left,y,col_w)
        entries=[("Tirada y consulta","attack"),("Protección y defensa adicional","protection"),("Veintes abiertos y prolongación","open_rolls"),("Componentes y resistencias","damage_types"),("Alcance y casos de campaña","scope"),("La armería","armory")]
        for title,pid in entries:
            self.para(title,left,yl,col_w-27,size=11.5,leading=14)
            self.text(self.page_for[pid],left+col_w,yl-11,font="Body-Bold",size=11.5,align="right")
            self.c.linkRect("",pid,(left,yl-19,left+col_w,yl+2),relative=0,thickness=0)
            self.line(left,yl-22,left+col_w,yl-22,width=.25,color=RULE)
            yl-=34
        yr=self.subheading("Las ocho familias",right,y,col_w)
        for group in self.group_order:
            first,last=self.group_pages[group]
            self.text(GROUPS[group],right,yr-11,size=11.5)
            self.text(f"{first}–{last}",right+col_w,yr-11,font="Body-Bold",size=11.5,align="right")
            self.c.linkRect("","weapon_"+self.groups[group][0]["id"],(right,yr-19,right+col_w,yr+2),relative=0,thickness=0)
            self.line(right,yr-22,right+col_w,yr-22,width=.25,color=RULE)
            yr-=34
        y=min(yl,yr)-18
        y=self.subheading("Apéndices",MARGIN,y)
        rows=[["Uso en Fantasy Grounds",self.page_for["fantasy_grounds"]],["Índice alfabético de armas",self.page_for["index"]],["Procedencia y fuentes",self.page_for["sources"]],["Guía de consulta rápida",self.page_for["quick_reference"]]]
        y=self.simple_table(["Referencia","Página"],rows,MARGIN,y,[TEXT_W-70,70],font_size=11,min_height=27)
        self.panel("Antes de la primera partida",["Las reglas conservan el crítico nativo de D&D. Las tablas no añaden heridas ni críticos de Rolemaster. Las curvas necesitan calibración y la aplicación dentro de Fantasy Grounds sigue pendiente de prueba real."],MARGIN,y-24,TEXT_W,size=11,leading=14)
        self.end()

    def attack_page(self):
        self.start("attack","Tirada y consulta")
        y=self.heading("El ataque y la calidad del golpe",subtitle="I. Objeto de estas tablas · Procedimiento de consulta")
        y=self.paras(self.sections["objeto"]["paragraphs"],MARGIN,y,TEXT_W,size=11.7,leading=15,gap=8)
        self.c.setFillColor(FAINT);self.c.rect(MARGIN,y-57,TEXT_W,55,fill=1,stroke=0)
        self.text("R = T + B − E",PAGE_W/2,y-29,font="Body-Bold",size=23,align="center")
        self.text("Índice interno: I = 5R",PAGE_W/2,y-46,font="Body",size=11,align="center")
        y-=75
        y=self.paras(self.sections["ataque"]["paragraphs"],MARGIN,y,TEXT_W,size=11.5,leading=14.8,gap=9)
        self.panel(self.examples["impacto_normal"]["title"],self.examples["impacto_normal"]["paragraphs"],MARGIN,y-7,TEXT_W,size=11.5,leading=14.8)
        self.end()

    def protection_page(self):
        self.start("protection","Protección y defensa")
        y=self.heading("La armadura y la defensa",subtitle="II. Siete perfiles de protección · La CA material se separa de las demás defensas")
        y=self.paras(self.sections["proteccion"]["paragraphs"],MARGIN,y,TEXT_W,size=12,leading=15.5,gap=10)
        y-=10
        rows=[
            ["SA","Sin armadura","Sin protección material especial."],
            ["CU","Cuero","Acolchada, cuero, cuero tachonado y pieles."],
            ["MA","Malla","Camisa y cota de malla, anillas y escamas."],
            ["PL","Placas","Coraza, semiplacas, laminada y placas completas."],
            ["PI","Piel gruesa","Protección natural; parte de la curva de cuero."],
            ["ES","Escamas naturales","Protección natural; parte de la curva de malla."],
            ["CA","Caparazón","Protección natural; parte de la curva de placas."],
        ]
        y=self.simple_table(["Clave","Perfil","Criterio de campaña"],rows,MARGIN,y,[42,132,TEXT_W-174],font_size=11,leading=14,min_height=33,table_id="armor_profiles")
        self.panel("Una asignación expresa",["La protección natural no se deduce de la CA ni concede resistencias. El director elige material y base de CA. Una laminada de CA 17 y unas placas de CA 18 todavía comparten columna; consulta las limitaciones de la página "+str(self.page_for["scope"])+"."],MARGIN,y-22,TEXT_W,size=11.2,leading=14.5)
        self.end()

    def open_page(self):
        self.start("open_rolls","Veintes abiertos")
        y=self.heading("Veintes abiertos",subtitle="III. Un resultado excepcional puede superar el daño habitual del arma")
        y=self.paras(self.sections["abiertas"]["paragraphs"][:2],MARGIN,y,TEXT_W,size=12,leading=15.5,gap=11)
        y-=7
        self.c.setFillColor(FAINT);self.c.rect(MARGIN,y-47,TEXT_W,46,fill=1,stroke=0)
        self.text("Δ = suelo[μ × máximo(0, R − R₀) / 10]",PAGE_W/2,y-27,font="Body-Bold",size=17,align="center")
        y-=63
        y=self.paras(self.sections["abiertas"]["paragraphs"][2:],MARGIN,y,TEXT_W,size=11.6,leading=15,gap=10)
        y=self.panel(self.examples["impacto_abierto"]["title"],self.examples["impacto_abierto"]["paragraphs"],MARGIN,y-4,TEXT_W,size=11.2,leading=14.4)-18
        rows=[["20 + 1","26","0","2d8 + 3"],["20 + 10","35","4","2d8 + 7"],["20 + 20 + 10","55","13","2d8 + 16"]]
        y=self.simple_table(["Cadena","R","Δ físico","Crítico nativo + M + Δ"],rows,MARGIN,y,[143,45,73,TEXT_W-261],font_size=10.6,min_height=27,table_id="open_examples")
        self.para("Mismo ejemplo: hojas, placas, ataque +5, defensa adicional 0, base 1d8 + 3. Cada continuación de 20 suma; no crea un segundo crítico.",MARGIN,y-12,TEXT_W,size=10.3,leading=13,max_height=y-65)
        self.end()

    def types_page(self):
        self.start("damage_types","Componentes y resistencias")
        y=self.heading("Cada tipo conserva su daño",subtitle="IV. La tabla transforma la base física; los componentes adicionales conservan su tirada")
        y=self.paras(self.sections["componentes"]["paragraphs"],MARGIN,y,TEXT_W,size=12,leading=15.5,gap=12)
        y-=12
        rows=[["Daño ordinario","Celda de 1d8 + 3","1d4 nativo"],["Crítico D&D","2d8 + 3 + Δ","2d4 nativos"],["Resistencia al ácido","Se conserva","Mitad, hacia abajo"],["Inmunidad física pertinente","Se anula si corresponde","Se conserva"]]
        y=self.simple_table(["Resolución","Componente cortante","Componente ácido"],rows,MARGIN,y,[158,185,TEXT_W-343],font_size=11,leading=14,min_height=42,table_id="component_rules")
        y=self.panel(self.examples["resistencia"]["title"],self.examples["resistencia"]["paragraphs"],MARGIN,y-25,TEXT_W,size=12,leading=15.5)-24
        self.para("El pico de guerra está en contundentes y la daga en hojas, pero ambos conservan el tipo perforante de su propia ficha. Del mismo modo, escamas naturales o caparazón no conceden inmunidades. En Fantasy Grounds, sus gestores nativos aplican cada defensa por tipo una sola vez.",MARGIN,y,TEXT_W,size=11.6,leading=15,max_height=y-58)
        self.end()

    def scope_page(self):
        self.start("scope","Alcance de la edición")
        y=self.heading("Alcance y casos de campaña",subtitle="V. Tablas originales de prueba · Un punto de partida que todavía necesita calibración")
        y=self.paras(self.sections["estado"]["paragraphs"],MARGIN,y,TEXT_W,size=12,leading=15.5,gap=12)
        y-=10
        rows=[["Shuriken","1d4 perforante · simple · una mano","Propuesta de campaña. Sin maestría ni alcance inventados."],["Trabuco / Blunderbuss","2d6 perforante · marcial · dos manos","Propuesta de campaña. Configura su ficha antes de usarlo."],["Cerbatana","1 perforante fijo","Daño nativo: sin conversión por calidad ni crecimiento de apertura."]]
        y=self.simple_table(["Caso","Perfil en este cuaderno","Alcance de la propuesta"],rows,MARGIN,y,[110,172,TEXT_W-282],font_size=10.8,leading=13.7,min_height=52,table_id="campaign_cases")
        self.panel("Qué conviene observar en mesa",["Compara daño por intento, incluidos fallos y críticos, con distintas bonificaciones, armaduras y situaciones de ventaja. Registra cuándo una protección pierde su diferencia material o una cola abierta domina el daño. Los modificadores, componentes adicionales y maestrías de D&D siguen sus propias reglas."],MARGIN,y-24,TEXT_W,size=11.5,leading=14.8)
        self.end()

    def armory_page(self):
        self.start("armory","La armería")
        y=self.heading("La armería",subtitle="Cuarenta armas · Ocho familias · Una escala de daño propia para cada bolsa de dados",size=33)
        self.para("Cada página reúne el perfil del arma, su ilustración y las siete columnas de protección. Las cifras de las celdas son daño físico ordinario, con el suplemento ya incluido y sin el modificador M. Las maestrías se conservan como referencia de la ficha.",MARGIN,y,TEXT_W,size=12,leading=15.5)
        top=661
        cell_w=TEXT_W/4
        for index,group in enumerate(self.group_order):
            col=index%4;row=index//4
            x=MARGIN+col*cell_w
            yy=top-row*260
            chosen=self.groups[group][0]
            self.weapon_image(chosen,[x+19,yy-190,cell_w-38,171])
            self.text(GROUPS[group],x+cell_w/2,yy-213,font="Display",size=10.4,align="center",max_width=cell_w-6)
            first,last=self.group_pages[group]
            self.text(f"Páginas {first}–{last}",x+cell_w/2,yy-232,size=10.5,align="center")
            self.c.linkRect("","weapon_"+chosen["id"],(x,yy-243,x+cell_w,yy),relative=0,thickness=0)
        self.line(MARGIN,388,PAGE_W-MARGIN,388,width=.45,color=RULE)
        self.para("Lectura de valores dobles: 1H / 2H. Un 1 natural inicial siempre falla; un 20 inicial abre y usa el crítico nativo, aunque la tabla muestre otra cifra ordinaria.",MARGIN,95,TEXT_W,size=10.7,leading=13.5,max_height=37)
        self.end()

    def pool_ids(self,weapon):
        if weapon.get("fixed_damage") is not None:
            return ["fixed1"]
        values=[]
        for key in ["dice_1h","dice_2h"]:
            value=weapon.get(key)
            if value:
                value=value[1:] if value.startswith("1d") else value
                if value not in values: values.append(value)
        assert values and all(p in self.tables["pools"] for p in values),(weapon["id"],values)
        return values

    def weapon_rows(self,weapon):
        pools=self.pool_ids(weapon)
        family=self.tables["families"][weapon["group"]]
        if len(pools)==2:
            return family["versatile"]["_".join(pools)]["grouped_rows"],pools
        return family["grids"][pools[0]]["grouped_rows"],pools

    def damage_label(self,weapon):
        if weapon.get("fixed_damage") is not None: return "1 fijo"
        one,two=weapon.get("dice_1h"),weapon.get("dice_2h")
        if one and two and one!=two: return one+" / "+two
        return one or two

    def hands_label(self,weapon):
        if weapon["id"]=="lance": return "1H montado / 2H"
        if weapon.get("dice_1h") and weapon.get("dice_2h") and weapon["dice_1h"]!=weapon["dice_2h"]: return "Versátil · 1H / 2H"
        return HANDS.get(weapon["hands"],weapon["hands"])

    def attack_table(self,weapon,top=526):
        rows,pools=self.weapon_rows(weapon)
        assert len(rows)<=28,(weapon["id"],len(rows))
        assert rows[-1]["r_max"]==35
        x=MARGIN;w=TEXT_W;first_w=49;cell_w=(w-first_w)/7
        header_h=26;row_h=12;tail_h=17
        total_h=header_h+len(rows)*row_h+tail_h
        bottom=top-total_h
        self.c.setFillColor(INK);self.c.rect(x,top-header_h,w,header_h,fill=1,stroke=0)
        self.text("R",x+first_w/2,top-18,font="Body-Bold",size=10,color=PAPER,align="center")
        for i,(short,label) in enumerate(zip(ARMOR_SHORT,ARMOR_LABELS)):
            cx=x+first_w+cell_w*(i+.5)
            self.text(short,cx,top-10,font="Body-Bold",size=9.5,color=PAPER,align="center",max_width=cell_w-5)
            self.text(label,cx,top-21,size=9.5,color=PAPER,align="center",max_width=cell_w-5)
        table_audit={"id":"damage_"+weapon["id"],"family":weapon["group"],"pools":pools,
                     "bounds":[x,bottom,w,total_h],"headers":["R"]+ARMOR_SHORT,"font_size":10,
                     "row_height":row_h,"ordinary_only":True,"modifier_excluded":True,"rows":[]}
        self._page["tables"].append(table_audit)
        y=top-header_h
        for ri,row in enumerate(rows):
            fill=FAINT if ri%2==0 else PAPER
            self.c.setFillColor(fill);self.c.rect(x,y-row_h,w,row_h,fill=1,stroke=0)
            self.c.setFillColor(colors.HexColor("#E4DCCB"));self.c.rect(x,y-row_h,first_w,row_h,fill=1,stroke=0)
            values=[]
            for value in row["totals"]:
                if value is None: values.append("—")
                elif isinstance(value,list): values.append(" / ".join(str(n) for n in value))
                else: values.append(str(value))
            all_cells=[row["label"]]+values
            bounds=[]
            for ci,value in enumerate(all_cells):
                cw=first_w if ci==0 else cell_w
                xx=x if ci==0 else x+first_w+(ci-1)*cell_w
                self.text(value,xx+cw/2,y-9,font="Body-Bold" if ci==0 else "Body",size=10,align="center",max_width=cw-7,role="table_cell")
                bounds.append([xx,y-row_h,cw,row_h])
            self.line(x,y-row_h,x+w,y-row_h,width=.18,color=RULE)
            table_audit["rows"].append({"label":row["label"],"r_min":row["r_min"],"r_max":row["r_max"],"cells":values,"cell_bounds":bounds})
            y-=row_h
        self.c.setFillColor(colors.HexColor("#D8CEBB"));self.c.rect(x,y-tail_h,w,tail_h,fill=1,stroke=0)
        self.text("R₀",x+first_w/2,y-11.5,font="Body-Bold",size=10,align="center")
        r0s=[]
        for i,armor in enumerate(self.tables["armor_order"]):
            r0=self.tables["families"][weapon["group"]]["columns"][armor]["tail_start_r"]
            r0s.append(r0)
            self.text(str(r0),x+first_w+cell_w*(i+.5),y-11.5,font="Body-Bold",size=10,align="center")
        table_audit["r0"]=r0s
        for i in range(8):
            xx=x if i==0 else x+first_w+(i-1)*cell_w
            self.line(xx,top-header_h,xx,bottom,width=.18,color=RULE)
        self.line(x+w,top-header_h,x+w,bottom,width=.18,color=RULE)
        self.record("damage_table",[x,bottom,w,total_h],weapon=weapon["id"])
        return bottom,pools

    def weapon_page(self,weapon):
        pid="weapon_"+weapon["id"]
        self.start(pid,GROUPS[weapon["group"]])
        title_size=min(25,25*TEXT_W/max(TEXT_W,pdfmetrics.stringWidth(weapon["name_es"],"Display",25)))
        self.text(weapon["name_es"],MARGIN,784,font="Display",size=title_size,max_width=TEXT_W)
        self.text(weapon["name_en"],MARGIN,765,font="Body-Italic",size=12.5)
        category="Simple" if weapon["category"]=="simple" else "Marcial" if weapon["category"]=="martial" else "De campaña"
        meta=GROUPS[weapon["group"]]+"  ·  "+category+"  ·  "+self.hands_label(weapon)
        self.text(meta,MARGIN,747,font="Body-Bold",size=10.5,max_width=TEXT_W)
        self.line(MARGIN,737,PAGE_W-MARGIN,737,width=1)
        self.weapon_image(weapon,[MARGIN+8,559,130,171])
        rx=MARGIN+158;rw=TEXT_W-158;y=729
        self.text(self.damage_label(weapon),rx,y-22,font="Display",size=24,max_width=rw)
        y-=36
        suffix=" · sin modificador de característica salvo regla específica" if weapon.get("fixed_damage") else " · añade M una vez"
        y=self.para(weapon["damage_type_es"].capitalize()+suffix,rx,y,rw,size=10.1,leading=12,max_height=y-543)-4
        props=" · ".join(weapon["properties_es"]) or "Sin propiedades adicionales"
        reach=weapon.get("range_ft")
        if reach:
            if isinstance(reach,dict):
                values=list(reach.values());range_text=" / ".join(str(v) for v in values if v is not None)
            elif isinstance(reach,list): range_text=" / ".join(map(str,reach))
            else: range_text=str(reach)
            props+=" · Distancia "+range_text+" pies"
        y=self.para("Propiedades: "+props,rx,y,rw,size=9.8,leading=11.7,max_height=y-543)-4
        mastery="Maestría: "+weapon["mastery"]+" · uso nativo de D&D" if weapon.get("mastery") else "Propuesta de campaña · sin maestría asignada"
        y=self.para(mastery,rx,y,rw,font="Body-Bold",size=9.8,leading=11.7,max_height=y-543)-6
        y=self.para(weapon["note_es"],rx,y,rw,size=10.3,leading=12.1,max_height=y-543)-4
        if weapon.get("usage_condition_es"):
            y=self.para(weapon["usage_condition_es"],rx,y,rw,size=9.5,leading=10.9,font="Body-Italic",max_height=y-543)
        if weapon.get("origin")!="dnd2024":
            self.text("PERFIL PROPUESTO · NO OFICIAL",rx,y-10,font="Body-Bold",size=9.5,color=RED,max_width=rw)
            y-=14
        if y<539:
            raise ValueError("Weapon header collides with table: "+weapon["id"])
        self.text("DAÑO ORDINARIO · R = T + B − E · M FUERA DE LA CELDA",MARGIN,536,font="Body-Bold",size=9.6,max_width=TEXT_W)
        bottom,pools=self.attack_table(weapon)
        legend="SA sin armadura · CU cuero · MA malla · PL placas · PI piel gruesa · ES escamas naturales · CA caparazón."
        yy=self.para(legend,MARGIN,bottom-8,TEXT_W,size=9.5,leading=11.1)-4
        fixed=weapon.get("fixed_damage") is not None
        if fixed:
            self.panel("DAÑO NATIVO · SIN CRECIMIENTO",[
                "La cifra 1 indica el daño fijo de un impacto de tabla. La cerbatana no tiene dados base que convertir: Arms Bridge conserva el daño nativo y no añade suplemento por apertura.",
                "No añadas automáticamente el modificador de característica a este daño fijo. Un 20 inicial conserva su impacto y crítico nativos; esta página no crea dados críticos ni crecimiento adicional."
            ],MARGIN,yy-20,TEXT_W,size=11.5,leading=15)
        else:
            mus=" / ".join(num(self.tables["pools"][p]["mu"]) for p in pools)
            maxs=" / ".join(str(self.tables["pools"][p]["maximum_base"]) for p in pools)
            uses=" (1H / 2H)" if len(pools)==2 else ""
            yy=self.para("Media μ = "+mus+uses+". Máximo base = "+maxs+". R₀ indica el comienzo de la prolongación en cada columna.",MARGIN,yy,TEXT_W,size=9.7,leading=11.7)-4
            yy=self.para("R > 35: daño = máximo base + M + suelo[μ × máximo(0, R − R₀) / 10].",MARGIN,yy,TEXT_W,size=10.1,leading=12,font="Body-Bold")-4
            yy=self.para("Crítico: dados nativos + M + Δ. El suplemento Δ se añade una vez; no se maximiza la base.",MARGIN,yy,TEXT_W,size=9.7,leading=11.7)-4
            self.para("— fallo. Un 1 natural inicial falla; un 20 inicial abre y usa el crítico nativo, no esta celda ordinaria.",MARGIN,yy,TEXT_W,size=9.5,leading=11.1,max_height=yy-49)
        self.end()

    def fg_page(self):
        self.start("fantasy_grounds","Uso en Fantasy Grounds")
        y=self.heading("Uso en Fantasy Grounds",subtitle="Apéndice A · Comandos de Arms Bridge "+self.version+" alpha")
        y=self.paras(self.manual["fg"]["paragraphs"],MARGIN,y,TEXT_W,size=11.8,leading=15.2,gap=12)-12
        rows=[[c["command"],c["description"]] for c in self.manual["fg"]["commands"]]
        y=self.simple_table(["Comando","Función"],rows,MARGIN,y,[293,TEXT_W-293],font_size=10.1,leading=12.8,min_height=33,table_id="fg_commands")
        self.panel("Prueba antes de usarlo en campaña",["Utiliza una copia de prueba, un único objetivo y la misma ficha y cliente para ataque y daño. Espera a que cierre la cadena abierta. La presencia de callbacks no certifica la aplicación final por tipos; consulta SMOKE_TEST.md en el paquete de fuentes."],MARGIN,y-23,TEXT_W,size=11.2,leading=14.3)
        self.end()

    def index_page(self):
        self.start("index","Índice de armas")
        y=self.heading("Índice alfabético de armas",subtitle="Apéndice B · Nombre español, referencia inglesa y página")
        def key(w):
            return unicodedata.normalize("NFD",w["name_es"]).encode("ascii","ignore").decode().lower()
        ordered=sorted(self.weapons,key=key)
        cw=(TEXT_W-24)/2
        for i,w in enumerate(ordered):
            col=i//20;row=i%20
            x=MARGIN+col*(cw+24);top=y-row*29
            self.text(w["name_es"],x,top-11,font="Body-Bold",size=11.2,max_width=cw-27)
            self.text(w["name_en"],x,top-23,font="Body-Italic",size=9.7,max_width=cw-27)
            self.text(self.page_for["weapon_"+w["id"]],x+cw,top-13,font="Body-Bold",size=11,align="right")
            self.line(x,top-28,x+cw,top-28,width=.22,color=RULE)
            self.c.linkRect("","weapon_"+w["id"],(x,top-27,x+cw,top+1),relative=0,thickness=0)
        self.para("El grupo selecciona la tabla. Categoría, manos, propiedades, tipo de daño y maestría se leen en la página del arma. Shuriken y Trabuco son propuestas de campaña.",MARGIN,118,TEXT_W,size=11,leading=14,max_height=60)
        self.end()

    def sources_page(self):
        self.start("sources","Procedencia y fuentes")
        y=self.heading("Procedencia y fuentes",subtitle="Apéndice C · Referencias conceptuales, reglas de D&D y documentación técnica")
        y=self.paras(self.manual["colophon"]["paragraphs"],MARGIN,y,TEXT_W,size=11.6,leading=15,gap=10)
        y=self.paras(["Los nombres españoles, notas de uso y tablas son redacción original de campaña. Las estadísticas oficiales de las 38 armas de D&D se contrastaron con sus fichas; Shuriken y Blunderbuss se distinguen como propuestas. La bibliografía ampliada y las direcciones individuales están en data/weapons-sources.json.",
                      "Las ilustraciones son originales generadas para este cuaderno a partir de las referencias de campaña. El diseño evoca los manuales clásicos. O.R.T.I.C.E. identifica esta edición de campaña; la obra no es una edición de Iron Crown Enterprises ni un producto oficial de D&D."],MARGIN,y,TEXT_W,size=10.8,leading=13.8,gap=10)
        y-=8
        sources=self.manual["colophon"]["sources"]+self.manifest.get("art_references",[])
        for i,source in enumerate(sources,1):
            y=self.para(str(i)+". "+source["title"],MARGIN,y,TEXT_W,font="Body-Bold",size=10.7,leading=13.5)-4
            url=source.get("url")
            if url:
                markup='<link href="'+html.escape(url,quote=True)+'" color="#772B25">'+esc(url)+'</link>'
                y=self.para(markup,MARGIN+12,y,TEXT_W-12,size=9.5,leading=11.7,markup=True)-5
            if source.get("note"):
                y=self.para(source["note"],MARGIN+12,y,TEXT_W-12,size=9.7,leading=12.1,font="Body-Italic")-4
            y-=4
        y=self.panel("Colofón",["O.R.T.I.C.E. · Edición de campaña "+self.version+" alpha · Octubre de 2026. Cuarenta armas y siete perfiles por familia. Tablas comprobadas contra distribuciones exactas. Tipografía Bookman y Liberation Serif; composición en A4. El suplemento abierto no tiene techo de reglas."],MARGIN,y-5,TEXT_W,size=10.5,leading=13.4,padding=10)
        if y<52: raise ValueError("Source page overflow")
        self.end()

    def quick_page(self):
        self.start("quick_reference","Guía de consulta rápida",cover=True)
        self.c.setFillColor(RED);self.c.rect(0,0,35,PAGE_H,fill=1,stroke=0)
        self.line(36,0,36,PAGE_H,width=1,color=INK)
        x=63;width=PAGE_W-x-36
        self.text("Guía de consulta rápida",x,774,font="Display",size=25,max_width=width)
        self.text("EL NUEVO ARMS LAW",x,749,font="Body-Bold",size=11)
        self.line(x,734,PAGE_W-36,734,width=1.2)
        y=711
        steps=[
            ("1. Protección y defensa","Elige la columna material. E = CA efectiva − CA material. El grupo del arma selecciona la tabla; su tipo de daño sigue en la ficha."),
            ("2. Tirada de ataque","Resuelve ventaja o desventaja. T es el d20 elegido y todas sus continuaciones. Calcula R = T + B − E; aplica las bonificaciones una sola vez."),
            ("3. Lectura de la celda","Cruza R con la protección. — significa fallo. La cifra incluye el suplemento físico ordinario: añade M una vez. Si hay dos cifras, lee 1H / 2H."),
            ("4. Naturales y apertura","El 1 natural inicial falla. El 20 inicial impacta, es crítico y abre. Cada 20 de continuación suma y vuelve a tirar. De 1 a 19, suma y termina."),
            ("5. Crítico y tipos adicionales","Usa los dados críticos nativos + M + Δ, sin maximizar. Conserva aparte ácido, fuego, necrótico y los demás componentes. Aplica después sus defensas por tipo."),
        ]
        for title,body in steps:
            y=self.subheading(title,x,y,width)
            y=self.para(body,x,y,width,size=12,leading=15.8)-20
        self.c.setFillColor(FAINT);self.c.rect(x,y-74,width,74,fill=1,stroke=0)
        self.text("Por encima de R = 35",x+width/2,y-20,font="Display",size=15,align="center")
        self.text("D = máximo base + M + Δ",x+width/2,y-42,font="Body-Bold",size=17,align="center")
        self.text("Δ = suelo[μ × máximo(0, R − R₀) / 10]",x+width/2,y-62,size=12.8,align="center",max_width=width-12)
        self.para("μ y R₀ figuran al pie de cada arma. Cerbatana: daño fijo nativo, sin crecimiento. Las reglas de estas tablas son experimentales y originales.",x,y-94,width,size=10.6,leading=13.5,max_height=y-136)
        self.line(x,66,PAGE_W-36,66,width=.7)
        self.text("Arms Bridge · "+self.version+" alpha",x,47,font="Body-Bold",size=10.5)
        self.text(self.page_for["quick_reference"],PAGE_W-36,47,font="Body-Bold",size=10.5,align="right")
        self.end()

    def build(self):
        self.cover();self.contents();self.attack_page();self.protection_page()
        self.open_page();self.types_page();self.scope_page();self.armory_page()
        for weapon in self.weapons: self.weapon_page(weapon)
        self.fg_page();self.index_page();self.sources_page();self.quick_page()
        assert len(self.audit["pages"])==52
        self.c.save()
        reader=PdfReader(str(self.temp))
        assert len(reader.pages)==52
        for i,page in enumerate(reader.pages):
            text=page.extract_text() or ""
            assert len(text.strip())>30,("Empty page",i+1)
            if "\ufffd" in text or "\u25a0" in text:
                raise ValueError("Replacement glyph on page "+str(i+1))
            self.audit["pages"][i]["extracted_characters"]=len(text)
            if self.audit["pages"][i]["id"].startswith("weapon_"):
                weapon=self.weapons[i-8]
                assert weapon["name_es"] in text,("Missing weapon title",weapon["id"])
                assert "R₀" in text,("Missing continuation row",weapon["id"])
        self.audit["validation"]={"page_count":52,"weapon_pages":40,"all_titles_extracted":True,
                                   "table_cells_fit":True,"paragraphs_fit":True,"errors":0,
                                   "live_fantasy_grounds_test":"pending"}
        self.temp.replace(self.output)
        self.audit["pdf_sha256"]=hashlib.sha256(self.output.read_bytes()).hexdigest()
        self.audit_path.write_text(json.dumps(self.audit,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        print(f"PDF: {self.output} ({self.output.stat().st_size:,} bytes)")
        print(f"Pages: {len(reader.pages)}; weapon pages: 40; table font: 9.5–10 pt; layout errors: 0")
        print(f"Audit: {self.audit_path}")


def render_review(pdf_path: Path, audit_path: Path):
    """Render the requested cover, sources and single-sheet overview from one PDF."""
    out=audit_path.parent
    reader=PdfReader(pdf_path)
    audit=json.loads(audit_path.read_text(encoding="utf-8"))
    for name,pageno in [("final-cover",1),("final-sources",audit["page_map"]["sources"])]:
        subprocess.run(["pdftoppm","-f",str(pageno),"-l",str(pageno),"-scale-to","1800",
                        "-png","-singlefile",str(pdf_path),str(out/name)],check=True)
    width,height=A2
    sheet=PageObject.create_blank_page(width=width,height=height)
    margin=25;gap=10;cols=7;rows=math.ceil(len(reader.pages)/cols)
    cw=(width-2*margin-(cols-1)*gap)/cols
    ch=(height-2*margin-24-(rows-1)*gap)/rows
    buffer=io.BytesIO()
    overlay=canvas.Canvas(buffer,pagesize=A2,invariant=1)
    overlay.setFont("Body-Bold",12)
    overlay.drawString(margin,height-19,"El nuevo Arms Law · "+audit["version"]+" alpha · "+str(len(reader.pages))+" páginas")
    for i,page in enumerate(reader.pages):
        col=i%cols;row=i//cols
        pw=float(page.mediabox.width);ph=float(page.mediabox.height)
        scale=min(cw/pw,(ch-13)/ph)
        x=margin+col*(cw+gap)+(cw-pw*scale)/2
        y=height-margin-24-row*(ch+gap)-ph*scale
        sheet.merge_transformed_page(page,Transformation().scale(scale).translate(x,y),over=True)
        overlay.setStrokeColorRGB(.65,.65,.65);overlay.setLineWidth(.25)
        overlay.rect(x,y,pw*scale,ph*scale,fill=0,stroke=1)
        overlay.setFont("Body",8);overlay.drawCentredString(x+pw*scale/2,y-10,str(i+1))
    overlay.save();buffer.seek(0)
    sheet.merge_page(PdfReader(buffer).pages[0])
    writer=PdfWriter();writer.add_page(sheet)
    contact_pdf=out/"contact-sheet.pdf"
    with contact_pdf.open("wb") as handle: writer.write(handle)
    subprocess.run(["pdftoppm","-f","1","-l","1","-scale-to","3400","-png","-singlefile",
                    str(contact_pdf),str(out/"contact-sheet")],check=True)
    audit["review_artifacts"]={"source_pdf_sha256":audit["pdf_sha256"],"contact_pages":len(reader.pages),
                               "files":{name:hashlib.sha256((out/name).read_bytes()).hexdigest()
                                        for name in ["final-cover.png","final-sources.png","contact-sheet.png"]}}
    audit_path.write_text(json.dumps(audit,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print("Review renders: "+str(out/"final-cover.png")+", "+str(out/"final-sources.png")+", "+str(out/"contact-sheet.png"))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",type=Path,default=ROOT/"output/pdf/El-nuevo-Arms-Law.pdf")
    parser.add_argument("--audit",type=Path,default=ROOT/"tmp/pdfs/layout-audit.json")
    parser.add_argument("--render-qa",action="store_true",help="Render cover, sources and a single-sheet overview with Poppler")
    args=parser.parse_args()
    Book(args.output.resolve(),args.audit.resolve()).build()
    if args.render_qa: render_review(args.output.resolve(),args.audit.resolve())


if __name__=="__main__":
    main()
