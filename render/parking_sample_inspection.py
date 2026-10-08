#!/usr/bin/env python3
"""Overlay the published parking SVGs on one raster tile for visual QA."""
import argparse, json, math, os
from qgis.PyQt.QtCore import QRectF, QSize
from qgis.PyQt.QtGui import QImage, QPainter
from qgis.PyQt.QtSvg import QSvgRenderer
from qgis.core import QgsApplication

def main():
    p=argparse.ArgumentParser(); p.add_argument('--tile',required=True); p.add_argument('--points',required=True); p.add_argument('--output',required=True); p.add_argument('--z',type=int,required=True); p.add_argument('--x',type=int,required=True); p.add_argument('--y',type=int,required=True); p.add_argument('--assets',default='style/symbols/cars'); a=p.parse_args()
    q=QgsApplication([],False); q.initQgis(); image=QImage(a.tile); image.setDotsPerMeterX(3780); image.setDotsPerMeterY(3780); n=2**a.z; data=json.load(open(a.points,encoding='utf8')); painter=QPainter(image)
    for f in data['features']:
        lon,lat=f['geometry']['coordinates']; xf=(lon+180)/360*n; yf=(1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n; px=(xf-a.x)*256; py=(yf-a.y)*256
        if not (-20<px<276 and -20<py<276): continue
        pr=f['properties']; path=os.path.join(a.assets,pr['@modell']+'_'+pr['@colour']+'.svg'); renderer=QSvgRenderer(path); painter.save(); painter.translate(px,py); painter.rotate(-float(pr['angle'])); renderer.render(painter,QRectF(-8,-5,16,10)); painter.restore()
    painter.end(); image.save(a.output,'PNG'); q.exitQgis()
if __name__=='__main__': main()
