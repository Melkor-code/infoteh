"""Reference-inspired Geoscan Pioneer FPV. Python 3 + NumPy/Pillow/SciPy.
Metres, Y up, front -Z. All geometry is editable procedural source.
"""
from pathlib import Path
import math, json, struct, io
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.spatial import Delaunay

OUT=Path(__file__).resolve().parent
parts=[]
materials=[
 {'name':'White protective ducts','pbrMetallicRoughness':{'baseColorFactor':[.84,.87,.90,1],'metallicFactor':.04,'roughnessFactor':.34}},
 {'name':'Carbon fibre / black plastic','pbrMetallicRoughness':{'baseColorFactor':[.025,.030,.035,1],'metallicFactor':.15,'roughnessFactor':.4}},
 {'name':'Black propellers','pbrMetallicRoughness':{'baseColorFactor':[.028,.033,.037,1],'metallicFactor':.03,'roughnessFactor':.32},'doubleSided':True},
 {'name':'Brushed aluminium','pbrMetallicRoughness':{'baseColorFactor':[.39,.42,.44,1],'metallicFactor':.82,'roughnessFactor':.31}},
 {'name':'Camera glass','pbrMetallicRoughness':{'baseColorFactor':[.010,.020,.028,1],'metallicFactor':.5,'roughnessFactor':.10}},
 {'name':'Printed battery strap','pbrMetallicRoughness':{'baseColorTexture':{'index':0},'metallicFactor':0,'roughnessFactor':.84}},
 {'name':'Battery foil','pbrMetallicRoughness':{'baseColorFactor':[.66,.68,.70,1],'metallicFactor':.76,'roughnessFactor':.39}},
 {'name':'Red antenna and power leads','pbrMetallicRoughness':{'baseColorFactor':[.65,.035,.05,1],'metallicFactor':.03,'roughnessFactor':.36}},
 {'name':'Circuit board','pbrMetallicRoughness':{'baseColorFactor':[.065,.07,.063,1],'metallicFactor':.1,'roughnessFactor':.65}},
 {'name':'Connector ivory','pbrMetallicRoughness':{'baseColorFactor':[.79,.80,.77,1],'metallicFactor':0,'roughnessFactor':.53}},
 {'name':'Weave highlights','pbrMetallicRoughness':{'baseColorFactor':[.07,.078,.086,1],'metallicFactor':.15,'roughnessFactor':.5}},
]

def add(name,v,f,mat=1,parent=None,translation=None,uv=None,smooth=False):
 v=np.array(v,float);f=np.array(f,int)
 if not smooth:
  if uv is not None:uv=np.array(uv)[f].reshape(-1,2)
  v=v[f].reshape(-1,3);f=np.arange(len(v)).reshape(-1,3)
 n=np.zeros_like(v)
 for face in f:
  a,b,c=v[face];n[face]+=np.cross(b-a,c-a)
 n/=np.maximum(np.linalg.norm(n,axis=1)[:,None],1e-12)
 parts.append(dict(name=name,v=v,f=f,n=n,mat=mat,parent=parent,t=translation,uv=uv));return len(parts)-1

def prism(name,poly,y0,y1,mat=1,parent=None,translation=None):
 # CCW in XZ.
 if sum(poly[j][0]*poly[(j+1)%len(poly)][1]-poly[(j+1)%len(poly)][0]*poly[j][1] for j in range(len(poly)))<0:poly=list(reversed(poly))
 N=len(poly);v=[(x,y,z) for y in (y0,y1) for x,z in poly];f=[]
 for i in range(1,N-1):f.extend([(0,i,i+1),(N,N+i+1,N+i)])
 for i in range(N):j=(i+1)%N;f.extend([(i,N+i,N+j),(i,N+j,j)])
 return add(name,v,f,mat,parent,translation)

def rect(name,c,size,mat=1,parent=None):
 x,y,z=c;a,b,d=np.array(size)/2
 return prism(name,[(x-a,z-d),(x+a,z-d),(x+a,z+d),(x-a,z+d)],y-b,y+b,mat,parent)

def bevel_box(name,c,size,bevel,mat=1):
 # Clip the twelve edges and eight corners of a box.
 from scipy.spatial import ConvexHull
 half=np.array(size)/2;v=[]
 for sx in (-1,1):
  for sy in (-1,1):
   for sz in (-1,1):
    signs=np.array([sx,sy,sz]);corner=half*signs
    for axis in range(3):p=corner.copy();p[axis]-=signs[axis]*bevel;v.append(p+np.array(c))
 v=np.array(v);hull=ConvexHull(v);f=[]
 for face,equation in zip(hull.simplices,hull.equations):
  a,b,cc=v[face]
  if np.dot(np.cross(b-a,cc-a),equation[:3])<0:face=face[::-1]
  f.append(face)
 return add(name,v,f,mat)

def tube(name,points,radius,mat=1,closed=False,sides=10):
 pts=np.array(points,float);v=[];f=[]
 for i,p in enumerate(pts):
  t=pts[(i+1)%len(pts)]-pts[(i-1)%len(pts)] if closed else pts[min(i+1,len(pts)-1)]-pts[max(i-1,0)]
  t/=np.linalg.norm(t);ref=np.array([0.,1.,0.])
  if abs(t@ref)>.95:ref=np.array([1.,0.,0.])
  u=np.cross(t,ref);u/=np.linalg.norm(u);w=np.cross(t,u)
  for j in range(sides):a=j*2*math.pi/sides;v.append(p+radius*(math.cos(a)*u+math.sin(a)*w))
 for i in range(len(pts) if closed else len(pts)-1):
  ni=(i+1)%len(pts)
  for j in range(sides):a=i*sides+j;b=i*sides+(j+1)%sides;c=ni*sides+(j+1)%sides;d=ni*sides+j;f.extend([(a,b,c),(a,c,d)])
 if not closed:
  # End caps have their own hard normals.
  for end in (0,len(pts)-1):
   base=len(v);v.append(pts[end]);v.extend(v[end*sides:end*sides+sides])
   for j in range(sides):a=base+1+j;b=base+1+(j+1)%sides;f.append((base,b,a) if end==0 else (base,a,b))
 return add(name,v,f,mat,smooth=True)

def cylinder(name,c,r,h,mat=1,parent=None,N=32):
 x,y,z=c;v=[];f=[]
 for yy in (y-h/2,y+h/2):
  for i in range(N):a=2*math.pi*i/N;v.append((x+r*math.cos(a),yy,z+r*math.sin(a)))
 for i in range(N):j=(i+1)%N;f.extend([(i,N+i,N+j),(i,N+j,j)])
 for yy,up in ((y-h/2,False),(y+h/2,True)):
  base=len(v);v.append((x,yy,z))
  for i in range(N):a=2*math.pi*i/N;v.append((x+r*math.cos(a),yy,z+r*math.sin(a)))
  for i in range(N):a=base+1+i;b=base+1+(i+1)%N;f.append((base,b,a) if up else (base,a,b))
 return add(name,v,f,mat,parent,smooth=True)

def ring(name,c,r,width,height,mat=0,N=80):
 x,y,z=c;v=[];f=[]
 # bevel profile: ring is a broad, thin vertical protective band.
 profile=[(r-width+.0006,-height/2),(r-.0006,-height/2),(r,-height/2+.001),(r,height/2-.001),(r-.0006,height/2),(r-width+.0006,height/2),(r-width,height/2-.001),(r-width,-height/2+.001)]
 for rr,yy in profile:
  for j in range(N):a=2*math.pi*j/N;v.append((x+rr*math.cos(a),y+yy,z+rr*math.sin(a)))
 for k in range(8):
  nk=(k+1)%8
  for j in range(N):nj=(j+1)%N;a=k*N+j;b=k*N+nj;cc=nk*N+nj;d=nk*N+j;f.extend([(a,cc,b),(a,d,cc)])
 return add(name,v,f,mat,smooth=True)

def bolt(name,x,y,z,r=.0023):
 cylinder(name+'_washer',(x,y-.0004,z),r*1.45,.001,3,N=24)
 cylinder(name+'_head',(x,y+.0007,z),r,.002,3,N=6)
 cylinder(name+'_socket',(x,y+.00175,z),r*.48,.00015,1,N=6)

def plate_with_holes(name,y,thickness,holes):
 # Triangulated carbon plate with circular through-holes.
 poly=[(-.037,-.046),(-.026,-.060),(.026,-.060),(.037,-.046),(.033,.052),(.023,.060),(-.023,.060),(-.033,.052)]
 loops=[poly]
 for x,z,r in holes:loops.append([(x+r*math.cos(j*2*math.pi/20),z+r*math.sin(j*2*math.pi/20)) for j in range(20)])
 points=np.array([p for loop in loops for p in loop]);tri=Delaunay(points).simplices;faces=[]
 def inside_poly(p):
  x,z=p;inside=False
  for i,(ax,az) in enumerate(poly):
   bx,bz=poly[(i+1)%len(poly)]
   if (az>z)!=(bz>z) and x<(bx-ax)*(z-az)/(bz-az)+ax:inside=not inside
  return inside
 v=[(x,yy,z) for yy in (y-thickness/2,y+thickness/2) for x,z in points];N=len(points)
 for face in tri:
  center=points[face].mean(axis=0)
  if not inside_poly(center) or any(np.linalg.norm(center-[x,z])<r*.97 for x,z,r in holes):continue
  a,b,c=face
  ab=points[b]-points[a];ac=points[c]-points[a]
  if ab[0]*ac[1]-ab[1]*ac[0]<0:b,c=c,b
  faces.extend([(a,b,c),(a+N,c+N,b+N)])
 off=0
 for li,loop in enumerate(loops):
  for i in range(len(loop)):
   a=off+i;b=off+(i+1)%len(loop)
   q=[(a,a+N,b+N),(a,b+N,b)]
   if li>0:q=[tuple(reversed(f)) for f in q]
   faces.extend(q)
  off+=len(loop)
 return add(name,v,faces,1)

# White connected four-loop lower guard; rotors run inside these ducts.
centers=[(-.048,-.048),(.048,-.048),(-.048,.048),(.048,.048)]
for i,(x,z) in enumerate(centers):
 ring('WhiteGuard_%d'%i,(x,-.020,z),.048,.0035,.011)
 ring('GuardTopLip_%d'%i,(x,-.014,z),.0487,.0022,.003)
 cylinder('WhiteMotorSeat_%d'%i,(x,-.022,z),.011,.006,0)
 for j in range(3):
  a=j*2*math.pi/3+.3;dx,dz=math.cos(a),math.sin(a);px,pz=-dz,dx
  poly=[(x+.009*dx-.002*px,z+.009*dz-.002*pz),(x+.045*dx-.003*px,z+.045*dz-.003*pz),(x+.045*dx+.003*px,z+.045*dz+.003*pz),(x+.009*dx+.002*px,z+.009*dz+.002*pz)]
  prism('GuardSpoke_%d_%d'%(i,j),poly,-.024,-.021,0)
for sx in (-1,1):rect('SideGuardBridge', (sx*.048,-.021,0),(.013,.007,.010),0)
for sz in (-1,1):rect('EndGuardBridge', (0,-.021,sz*.048),(.010,.007,.013),0)
rect('GuardCenterBridge',(0,-.022,0),(.028,.006,.028),0)

# Two carbon frame plates with standoffs and visible electronics.
holes=[(x,z,.0021) for x in (-.014,0,.014) for z in (-.045,-.034,-.023)]
holes += [(0,.039,.003),(-.022,.043,.002),(.022,.043,.002)]
plate_with_holes('UpperCarbonPlate',.026,.0025,holes)
plate_with_holes('LowerCarbonPlate',.006,.0025,[(0,.038,.006),(0,-.035,.008)])
for x,z in [(-.027,-.035),(.027,-.035),(-.026,.043),(.026,.043)]:
 cylinder('FrameStandoff',(x,.016,z),.0032,.019,1)
 bolt('FrameBolt',x,.028,z)
for i,(x,z) in enumerate(centers):
 sx=1 if x>0 else -1;sz=1 if z>0 else -1
 poly=[(sx*.023,sz*.028),(x-.009,z-.008),(x+.009,z+.008),(sx*.027,sz*.044)]
 # use a simple tapered strip along the arm to ensure no self-intersections.
 a=np.array([sx*.024,sz*.032]);b=np.array([x,z]);vec=b-a;side=np.array([-vec[1],vec[0]]);side/=np.linalg.norm(side)
 poly=[tuple(a-side*.008),tuple(b-side*.010),tuple(b+side*.010),tuple(a+side*.008)]
 prism('CarbonMotorArm_%d'%i,poly,.006,.010,1)
 cylinder('MotorBody_%d'%i,(x,-.003,z),.010,.019,3)
 cylinder('MotorBlackBase_%d'%i,(x,-.016,z),.008,.008,1)
 cylinder('MotorTop_%d'%i,(x,.011,z),.009,.007,1)
 cylinder('MotorRotorBell_%d'%i,(x,.016,z),.0078,.004,3)
 for j in range(4):
  a=j*math.pi/2;xx=x+.0056*math.cos(a);zz=z+.0056*math.sin(a);bolt('MotorScrew_%d_%d'%(i,j),xx,.019,zz,.00125)
 # Slots in each exposed motor bell.
 for j in range(10):
  a=j*2*math.pi/10;xx=x+.0095*math.cos(a);zz=z+.0095*math.sin(a)
  rect('MotorCoolingSlot',(xx,-.003,zz),(.001,.006,.001),1)
 # Three gently swept and pitched blades: entire rotor has a local shaft origin.
 rv=[];rf=[]
 outline=[(.005,-.002),(.014,-.004),(.028,-.008),(.038,-.010),(.041,-.008),(.042,-.005),(.040,-.002),(.030,.001),(.016,.002),(.006,.002)]
 for j in range(3):
  angle=j*2*math.pi/3+i*.40;co=math.cos(angle);si=math.sin(angle)
  vv=[];ff=[];N=len(outline)
  for sign in (-1,1):
   for xx,zz in outline:vv.append((xx*co-zz*si,zz*.23+sign*.00055,xx*si+zz*co))
  for k in range(1,N-1):ff.extend([(0,k,k+1),(N,N+k+1,N+k)])
  for k in range(N):n=(k+1)%N;ff.extend([(k,k+N,n+N),(k,n+N,n)])
  offset=len(rv);rv.extend(vv);rf.extend(np.array(ff)+offset)
 rotor=add('Propeller_%d'%i,rv,rf,2,translation=[x,-.014,z])
 cylinder('PropHub_%d'%i,(0,0,0),.005,.004,2,parent=rotor)

bevel_box('FlightController',(0,.013,0),(.035,.003,.044),.001,8)
for x,z in [(-.010,-.007),(.009,.004),(0,.014)]:bevel_box('ElectronicChip',(x,.016,z),(.008,.002,.008),.0005,1)
for x in (-.015,.015):
 for z in (-.015,-.009,-.003,.003,.009,.015):rect('BoardSolderPad',(x,.015,z),(.002,.0005,.002),3)
bevel_box('USBPort',(.033,.012,.020),(.009,.005,.008),.0005,3)
rect('USBOpening',(.0377,.012,.020),(.0004,.003,.005),1)

# Camera between vertical side brackets at the front, facing -Z.
bevel_box('FPVCameraBody',(0,.008,-.050),(.028,.025,.021),.002,1)
for x in (-.018,.018):
 prism('CameraSideBracket',[(x-.002,-.067),(x+.002,-.067),(x+.002,-.039),(x-.002,-.039)],-.014,.019,1)
 # Round pivot pin along X.
 pin=cylinder('CameraTiltPivot',(0,0,0),.0025,.003,3)
 p=parts[pin];p['v']=p['v'][:,[1,0,2]]+np.array([x,.007,-.049]);p['n']=p['n'][:,[1,0,2]];p['f']=p['f'][:,::-1]
def camera_cylinder(name,z,r,h,mat):
 i=cylinder(name,(0,0,0),r,h,mat,N=48);p=parts[i]
 p['v']=p['v'][:,[0,2,1]]+np.array([0,.009,z]);p['n']=p['n'][:,[0,2,1]];p['f']=p['f'][:,::-1]
camera_cylinder('LensBarrel',-.064,.010,.010,1)
camera_cylinder('LensMetalRim',-.0698,.009,.0015,3)
camera_cylinder('LensGlass',-.0707,.0077,.0004,4)
camera_cylinder('LensInnerElement',-.071,.0035,.0003,4)

# Shrink-wrapped silver battery with subtle uneven foil bands and black strap.
bevel_box('LiPoBattery',(0,.053,.013),(.053,.048,.103),.004,6)
for side in (-1,1):
 for j in range(9):
  y=.035+j*.0047
  tube('BatteryFoilFold',[(side*.0266,y,-.032),(side*.027,y+.0007,-.01),(side*.0268,y-.0003,.023),(side*.0265,y+.0006,.059)],.0004,3,sides=6)
for z in (-.037,.063):
 tube('BatteryFoldEdge',[(-.022,.033,z),(-.026,.037,z),(-.026,.072,z),(-.020,.077,z),(.021,.077,z),(.026,.071,z),(.026,.036,z),(.021,.031,z)],.0007,6,sides=8)
for x in (-.028,.028):bevel_box('BatteryStrapSide',(x,.053,.009),(.003,.047,.014),.001,1)
bevel_box('BatteryStrapTop',(0,.0785,.009),(.059,.003,.014),.001,1)
bevel_box('StrapBuckle',(-.029,.071,.009),(.005,.008,.019),.001,1)

fontpath='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
im=Image.new('RGB',(768,192),(9,12,15));draw=ImageDraw.Draw(im)
draw.text((384,94),'ГЕОСКАН',font=ImageFont.truetype(fontpath,95),fill=(221,227,234),anchor='mm')
bio=io.BytesIO();im.save(bio,format='PNG');texture=bio.getvalue()
add('StrapBrand',[(-.025,.08005,.003),(.025,.08005,.003),(.025,.08005,.015),(-.025,.08005,.015)],[(0,2,1),(0,3,2)],5,uv=[(1,1),(0,1),(0,0),(1,0)],smooth=True)

# Battery cable loops, balance lead, white plug and elevated red antenna.
for k,(mat,offset) in enumerate([(7,0),(1,.004)]):
 tube('BatteryPowerCable',[(.018,.060+offset,.063),(.028,.063+offset,.070),(.030,.055+offset,.079),(.020,.041+offset,.082),(.004,.038+offset,.078),(-.006,.039+offset,.067)],.0018,mat,sides=10)
for k in range(4):
 tube('BalanceLead_%d'%k,[(.023,.048-k*.002,.061),(.033,.038-k*.001,.075),(.041,.031-k*.001,.079),(.045,.030-k*.001,.076)],.00065,7 if k<3 else 1,sides=8)
bevel_box('BalanceConnector',(.047,.030,.076),(.008,.012,.005),.0008,9)
for k in range(4):rect('ConnectorPin',(.044+k*.0017,.025,.0786),(.0007,.0015,.0004),3)
antenna_path=[(.018,.026,.043),(.020,.039,.056),(.023,.069,.080),(.025,.100,.095)]
tube('AntennaStem',antenna_path,.002,1,sides=12)
tube('RedAntennaCap',[(.025,.100,.095),(.029,.116,.103)],.0064,7,sides=12)
tube('AntennaNeck',[(.024,.096,.093),(.026,.101,.096)],.0035,7,sides=12)

# Route the exposed leads along the side visible in the reference photograph.
for p in parts:
 if p['name'].startswith(('BatteryPowerCable','BalanceLead','BalanceConnector','ConnectorPin')):
  p['v'][:,0]*=-1;p['n'][:,0]*=-1;p['f']=p['f'][:,::-1]

# Small diagonal weave highlights on the exposed front of the carbon top plate.
for row in range(5):
 for col in range(12):
  x=-.029+col*.005;z=-.053+row*.006
  if any((x-hx)**2+(z-hz)**2<(r+.0015)**2 for hx,hz,r in holes):continue
  prism('CarbonWeave',[(x-.0009,z-.001),(x+.0002,z-.0018),(x+.0017,z+.0009),(x+.0006,z+.0017)],.02730,.02735,10)

def merge_static_geometry():
 # Keep rotors independent and reduce static surface count for game rendering.
 global parts
 old=parts;result=[];mapping={}
 independent={i for i,p in enumerate(old) if p['t'] is not None or p['parent'] is not None}
 for i,p in enumerate(old):
  if i in independent:mapping[i]=len(result);result.append(p)
 for p in result:
  if p['parent'] is not None:p['parent']=mapping[p['parent']]
 for mat in range(len(materials)):
  group=[p for i,p in enumerate(old) if i not in independent and p['mat']==mat]
  if not group:continue
  vv=[];nn=[];ff=[];uv=[];offset=0
  for p in group:
   vv.extend(p['v']);nn.extend(p['n']);ff.extend(p['f']+offset);offset+=len(p['v'])
   if p['uv'] is not None:uv.extend(p['uv'])
  result.append(dict(name='Body_'+materials[mat]['name'].replace(' / ','_').replace(' ','_'),v=np.array(vv),n=np.array(nn),f=np.array(ff),mat=mat,parent=None,t=None,uv=np.array(uv) if uv else None))
 parts=result

def export_glb():
 binary=bytearray();views=[];access=[];meshes=[];nodes=[]
 def blob(data,target=None):
  while len(binary)%4:binary.append(0)
  off=len(binary);binary.extend(data);view={'buffer':0,'byteOffset':off,'byteLength':len(data)}
  if target:view['target']=target
  views.append(view);return len(views)-1
 def acc(a,typ,ctype,target):
  o={'bufferView':blob(a.tobytes(),target),'componentType':ctype,'count':len(a),'type':typ}
  if typ=='VEC3':o.update(min=a.min(axis=0).tolist(),max=a.max(axis=0).tolist())
  access.append(o);return len(access)-1
 for p in parts:
  attrs={'POSITION':acc(p['v'].astype('<f4'),'VEC3',5126,34962),'NORMAL':acc(p['n'].astype('<f4'),'VEC3',5126,34962)}
  if p['uv'] is not None:attrs['TEXCOORD_0']=acc(np.array(p['uv'],dtype='<f4'),'VEC2',5126,34962)
  indices=acc(p['f'].ravel().astype('<u4'),'SCALAR',5125,34963)
  meshes.append({'name':p['name'],'primitives':[{'attributes':attrs,'indices':indices,'material':p['mat']}]})
  node={'name':p['name'],'mesh':len(meshes)-1}
  if p['t'] is not None:node['translation']=p['t']
  nodes.append(node)
 for i,p in enumerate(parts):
  if p['parent'] is not None:nodes[p['parent']].setdefault('children',[]).append(i)
 roots=[i for i,p in enumerate(parts) if p['parent'] is None]
 nodes.append({'name':'GeoscanPioneerFPV','children':roots,'extras':{'reference':'01-image.png','approximate_dimensions':True,'forward':'-Z','units':'metres'}})
 imageview=blob(texture)
 doc={'asset':{'version':'2.0','generator':'Procedural reference-inspired Geoscan Pioneer FPV'},'scene':0,'scenes':[{'nodes':[len(nodes)-1]}],'nodes':nodes,'meshes':meshes,'materials':materials,'accessors':access,'bufferViews':views,'buffers':[{'byteLength':len(binary)}],'images':[{'bufferView':imageview,'mimeType':'image/png'}],'textures':[{'source':0}]}
 js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*((-len(js))%4);binary+=b'\0'*((-len(binary))%4)
 data=struct.pack('<4sII',b'glTF',2,12+8+len(js)+8+len(binary))+struct.pack('<I4s',len(js),b'JSON')+js+struct.pack('<I4s',len(binary),b'BIN\0')+binary
 (OUT/'geoscan_pioneer_fpv.glb').write_bytes(data);return doc

def render():
 W,H=1400,1050;img=np.zeros((H,W,3),dtype=np.uint8);img[:]=[231,235,240];depth=np.full((H,W),-np.inf)
 eye=np.array([-.8,.65,-1.1]);eye/=np.linalg.norm(eye);right=np.cross([0,1,0],eye);right/=np.linalg.norm(right);up=np.cross(eye,right)
 scale=3800;light=np.array([-.5,1,-.7]);light/=np.linalg.norm(light)
 def world(i):
  p=parts[i];t=np.array(p['t'] if p['t'] is not None else [0,0,0],float);j=p['parent']
  while j is not None:
   t+=np.array(parts[j]['t'] if parts[j]['t'] is not None else [0,0,0]);j=parts[j]['parent']
  return p['v']+t
 for i,p in enumerate(parts):
  v=world(i);screen=np.stack([v@right*scale+W/2,-v@up*scale+H/2+110,v@eye],axis=1)
  base=np.array(materials[p['mat']]['pbrMetallicRoughness'].get('baseColorFactor',[.91,.93,.94,1])[:3])*255
  for face in p['f']:
   a,b,c=screen[face];xmin=max(0,int(min(a[0],b[0],c[0])));xmax=min(W-1,int(max(a[0],b[0],c[0]))+1);ymin=max(0,int(min(a[1],b[1],c[1])));ymax=min(H-1,int(max(a[1],b[1],c[1]))+1)
   if xmin>=xmax or ymin>=ymax:continue
   den=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
   if abs(den)<1e-8:continue
   xx,yy=np.meshgrid(np.arange(xmin,xmax+1)+.5,np.arange(ymin,ymax+1)+.5)
   u=((b[1]-c[1])*(xx-c[0])+(c[0]-b[0])*(yy-c[1]))/den;w=((c[1]-a[1])*(xx-c[0])+(a[0]-c[0])*(yy-c[1]))/den;t=1-u-w
   zz=u*a[2]+w*b[2]+t*c[2];region=depth[ymin:ymax+1,xmin:xmax+1];mask=(u>=0)&(w>=0)&(t>=0)&(zz>region)
   if not mask.any():continue
   norm=u[...,None]*p['n'][face[0]]+w[...,None]*p['n'][face[1]]+t[...,None]*p['n'][face[2]];norm/=np.maximum(np.linalg.norm(norm,axis=2)[...,None],1e-9)
   shade=.55+.45*np.maximum(0,norm@light)
   color=np.broadcast_to(base,(*u.shape,3)).copy()
   if p['uv'] is not None:
    uv=u[...,None]*p['uv'][face[0]]+w[...,None]*p['uv'][face[1]]+t[...,None]*p['uv'][face[2]]
    tx=np.clip((uv[:,:,0]*767).astype(int),0,767);ty=np.clip((uv[:,:,1]*191).astype(int),0,191);color=np.array(im)[ty,tx].astype(float)
   # Small highlights make the glass and metal legible in this software preview.
   if p['mat'] in (3,4,6):
    half=eye+light;half/=np.linalg.norm(half);spec=np.maximum(0,norm@half)**(60 if p['mat']==4 else 24);color+=spec[...,None]*(100 if p['mat']==4 else 60)
   color=np.clip(color*shade[...,None],0,255).astype(np.uint8);img[ymin:ymax+1,xmin:xmax+1][mask]=color[mask];region[mask]=zz[mask]
 output=Image.fromarray(img);d=ImageDraw.Draw(output)
 d.text((45,35),'GEOSCAN PIONEER FPV',font=ImageFont.truetype(fontpath,35),fill=(45,55,65))
 d.text((45,83),'Reference-inspired 3D asset / Godot 4',font=ImageFont.truetype(fontpath,23),fill=(85,95,105))
 d.text((45,H-52),'Embedded materials  ·  independent rotors  ·  metres / Y up',font=ImageFont.truetype(fontpath,22),fill=(75,85,95));output.save(OUT/'preview.png')

if __name__=='__main__':
 merge_static_geometry();export_glb();render()
 print(json.dumps({'meshes':len(parts),'triangles':sum(len(p['f']) for p in parts),'vertices':sum(len(p['v']) for p in parts),'glb_bytes':(OUT/'geoscan_pioneer_fpv.glb').stat().st_size}))
