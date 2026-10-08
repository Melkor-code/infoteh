"""Reference-inspired DJI Phantom. Python 3 + NumPy/Pillow/SciPy.
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
 {'name':'Phantom glossy white','pbrMetallicRoughness':{'baseColorFactor':[.91,.93,.95,1],'metallicFactor':.03,'roughnessFactor':.25}},
 {'name':'Dark detail','pbrMetallicRoughness':{'baseColorFactor':[.035,.042,.048,1],'metallicFactor':.08,'roughnessFactor':.38}},
 {'name':'White propellers','pbrMetallicRoughness':{'baseColorFactor':[.86,.89,.92,1],'metallicFactor':.02,'roughnessFactor':.3},'doubleSided':True},
 {'name':'Motor aluminium','pbrMetallicRoughness':{'baseColorFactor':[.48,.51,.54,1],'metallicFactor':.8,'roughnessFactor':.27}},
 {'name':'Camera glass','pbrMetallicRoughness':{'baseColorFactor':[.012,.032,.044,1],'metallicFactor':.55,'roughnessFactor':.1}},
 {'name':'DJI marking','pbrMetallicRoughness':{'baseColorTexture':{'index':0},'metallicFactor':0,'roughnessFactor':.38}},
 {'name':'Light grey joints','pbrMetallicRoughness':{'baseColorFactor':[.64,.68,.72,1],'metallicFactor':.06,'roughnessFactor':.4}},
 {'name':'Red navigation LEDs','pbrMetallicRoughness':{'baseColorFactor':[.65,.025,.02,1],'roughnessFactor':.3},'emissiveFactor':[.6,.01,.005]},
 {'name':'Green navigation LEDs','pbrMetallicRoughness':{'baseColorFactor':[.03,.45,.08,1],'roughnessFactor':.3},'emissiveFactor':[.01,.45,.02]},
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
 pts=np.array(points,float);v=[];f=[];previous_u=None
 for i,p in enumerate(pts):
  t=pts[(i+1)%len(pts)]-pts[(i-1)%len(pts)] if closed else pts[min(i+1,len(pts)-1)]-pts[max(i-1,0)]
  t/=np.linalg.norm(t);ref=np.array([0.,1.,0.])
  if abs(t@ref)>.95:ref=np.array([1.,0.,0.])
  u=np.cross(t,ref) if previous_u is None else previous_u-t*np.dot(previous_u,t)
  if np.linalg.norm(u)<1e-8:u=np.cross(t,ref)
  u/=np.linalg.norm(u);previous_u=u;w=np.cross(t,u)
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

# Smooth shell and arms are closed mesh lofts, not intersecting cubes.
def pillow(name,center,size,mat=0,rings=24,sides=64):
 c=np.array(center);rx,ry,rz=np.array(size)/2;v=[c+[0,-ry,0]];f=[]
 for j in range(1,rings):
  latitude=-math.pi/2+j*math.pi/rings
  for k in range(sides):
   a=2*math.pi*k/sides;co,si=math.cos(a),math.sin(a)
   x=rx*math.copysign(abs(co)**.72,co)*math.cos(latitude)
   z=rz*math.copysign(abs(si)**.72,si)*math.cos(latitude)
   v.append(c+[x,ry*math.sin(latitude),z])
 v.append(c+[0,ry,0]);top=len(v)-1
 for k in range(sides):n=(k+1)%sides;f.append((0,1+k,1+n))
 for j in range(rings-2):
  for k in range(sides):n=(k+1)%sides;a=1+j*sides+k;b=1+j*sides+n;cc=1+(j+1)*sides+n;d=1+(j+1)*sides+k;f.extend([(a,cc,b),(a,d,cc)])
 for k in range(sides):n=(k+1)%sides;f.append((top,1+(rings-2)*sides+n,1+(rings-2)*sides+k))
 return add(name,v,f,mat,smooth=True)

def arm(name,sx,sz):
 N=24;R=28;v=[];f=[];side=np.array([-sz,0,sx],float)/math.sqrt(2)
 for j in range(R):
  t=j/(R-1);p=np.array([sx*(.042+.093*t),.012+.014*t,sz*(.042+.093*t)])
  width=.027-.010*t+.004*t*t;h=.015-.006*t
  for k in range(N):a=2*math.pi*k/N;v.append(p+side*(width*math.cos(a))+[0,h*math.sin(a),0])
 for j in range(R-1):
  for k in range(N):n=(k+1)%N;a=j*N+k;b=j*N+n;cc=(j+1)*N+n;d=(j+1)*N+k;f.extend([(a,b,cc),(a,cc,d)])
 for end in (0,R-1):
  base=len(v);v.append(np.mean(v[end*N:(end+1)*N],axis=0))
  for k in range(N):n=(k+1)%N;f.append((base,end*N+n,end*N+k) if end==0 else (base,end*N+k,end*N+n))
 # Orient faces outward using the centerline of each vertex ring.
 arr=np.array(v)
 for idx,face in enumerate(f):
  aa,bb,cc=arr[list(face)];mid=(aa+bb+cc)/3;t=np.clip((abs(mid[0])-.042)/.093,0,1)
  center=np.array([sx*(.042+.093*t),.012+.014*t,sz*(.042+.093*t)])
  if np.dot(np.cross(bb-aa,cc-aa),mid-center)<0:f[idx]=tuple(reversed(face))
 return add(name,v,f,0,smooth=True)

pillow('MainShell',(0,.016,0),(.174,.060,.180),0)
pillow('LowerElectronicsHousing',(0,-.003,.008),(.129,.052,.135),0)
# Fine grey shell seam encircles the central fuselage.
seam=[]
for j in range(96):
 a=j*2*math.pi/96;co,si=math.cos(a),math.sin(a)
 seam.append((.087*math.copysign(abs(co)**.72,co),.013,.09*math.copysign(abs(si)**.72,si)))
tube('ShellSeam',seam,.00065,6,True,sides=6)

for i,(sx,sz) in enumerate([(-1,-1),(1,-1),(-1,1),(1,1)]):
 x=sx*.135;z=sz*.135
 arm('SmoothArm_%d'%i,sx,sz)
 cylinder('MotorWhiteMount_%d'%i,(x,.027,z),.019,.011,0)
 cylinder('MotorLowerRing_%d'%i,(x,.036,z),.0158,.005,3)
 cylinder('MotorBell_%d'%i,(x,.049,z),.0145,.023,3)
 cylinder('MotorTopLip_%d'%i,(x,.061,z),.0135,.003,6)
 for j in range(3):ring('MotorGroove_%d_%d'%(i,j),(x,.036+j*.0015,z),.016,.0008,.0022,6,N=48)
 cylinder('PropShaft_%d'%i,(x,.065,z),.004,.009,3)
 # Thin pitched, swept two-blade propeller. White domed fastener is a child.
 outline=[(.007,-.004),(.019,-.006),(.055,-.006),(.083,-.002),(.101,.002),(.107,.005),(.104,.007),(.095,.008),(.060,.006),(.025,.005),(.008,.004)]
 rv=[];rf=[];angle=(.30 if i%2 else -.12)
 for sign in (-1,1):
  N=len(outline);vv=[];ff=[]
  for layer in (-1,1):
   for xx,zz in outline:
    xx*=sign;zz*=sign;co,si=math.cos(angle),math.sin(angle);vv.append((xx*co-zz*si,zz*.20+layer*.0007,xx*si+zz*co))
  for k in range(1,N-1):ff.extend([(0,k,k+1),(N,N+k+1,N+k)])
  for k in range(N):n=(k+1)%N;ff.extend([(k,k+N,n+N),(k,n+N,n)])
  offset=len(rv);rv.extend(vv);rf.extend(np.array(ff)+offset)
 rotor=add('Propeller_%d'%i,rv,rf,2,translation=[x,.069,z])
 hub=pillow('PropHub_%d'%i,(0,.003,0),(.019,.010,.019),2,rings=12,sides=24);parts[hub]['parent']=rotor
 cylinder('PropHubMark_%d'%i,(0,.0083,0),.005,.0008,1 if i in (0,3) else 6,parent=rotor)
 pillow('ArmLED_%d'%i,(sx*.108,.005,sz*.108),(.029,.004,.017),7 if sz<0 else 8,rings=8,sides=24)

# Two tall, rounded U-shaped landing rails along the length of the fuselage.
for sx in (-1,1):
 pts=[(sx*.053,-.006,-.057),(sx*.062,-.043,-.070),(sx*.073,-.092,-.089),(sx*.077,-.132,-.102),(sx*.077,-.149,-.097),(sx*.077,-.155,-.083),(sx*.077,-.155,.087),(sx*.077,-.151,.105),(sx*.076,-.135,.109),(sx*.069,-.086,.092),(sx*.058,-.034,.070),(sx*.052,-.006,.059)]
 # Interpolate curve to remove sharp corners from the supports and skid ends.
 from scipy.interpolate import CubicSpline
 pts=np.array(pts);d=np.r_[0,np.cumsum(np.linalg.norm(np.diff(pts,axis=0),axis=1))]
 curve=CubicSpline(d,pts,axis=0)(np.linspace(0,d[-1],120))
 tube('LandingRail',curve,.0052,0,sides=12)
 for z in (-.070,.077):bevel_box('SkidGrip',(sx*.077,-.159,z),(.010,.005,.017),.0015,6)
 for z in (-.058,.059):pillow('LandingLegAttachment',(sx*.052,-.013,z),(.018,.026,.023),0,rings=12,sides=24)
 # Small antenna panels and black screws on the legs.
 for z in (-.071,.071):
  cylinder('LegScrew',(sx*.062,-.043,z),.0017,.0015,1,N=16)

# Stabilized camera and gimbal assembly hanging below the body.
pillow('GimbalMount',(0,-.038,-.008),(.042,.015,.041),6,rings=12,sides=32)
cylinder('GimbalYawMotor',(0,-.052,-.008),.013,.019,3)
bevel_box('GimbalUpperBracket',(0,-.067,-.008),(.030,.013,.014),.003,0)
tube('GimbalSideArm',[(.019,-.063,-.008),(.024,-.079,-.009),(.024,-.105,-.026),(.019,-.116,-.031)],.0045,0,sides=12)
bevel_box('CameraBody',(0,-.113,-.031),(.047,.036,.041),.006,0)
# Gimbal pitch motor on the camera side (axis X).
pitch=cylinder('GimbalPitchMotor',(0,0,0),.010,.009,6,N=40)
p=parts[pitch];p['v']=p['v'][:,[1,0,2]]+np.array([.026,-.109,-.030]);p['n']=p['n'][:,[1,0,2]];p['f']=p['f'][:,::-1]
def front_cylinder(name,z,r,h,mat):
 idx=cylinder(name,(0,0,0),r,h,mat,N=48);p=parts[idx]
 p['v']=p['v'][:,[0,2,1]]+np.array([0,-.113,z]);p['n']=p['n'][:,[0,2,1]];p['f']=p['f'][:,::-1]
front_cylinder('CameraLensBarrel',-.054,.012,.008,6)
front_cylinder('CameraLensBlackRim',-.0587,.0108,.002,1)
front_cylinder('CameraLensGlass',-.060,.0086,.0006,4)
front_cylinder('CameraLensInnerRing',-.0604,.0054,.0003,1)
front_cylinder('CameraLensInnerGlass',-.0606,.0047,.0002,4)

# Vision sensors, shell vents, status button and rear battery detail.
for x in (-.019,.019):
 idx=cylinder('ForwardVisionSensor',(0,0,0),.005,.002,1,N=32);p=parts[idx]
 p['v']=p['v'][:,[0,2,1]]+np.array([x,-.002,-.085]);p['n']=p['n'][:,[0,2,1]];p['f']=p['f'][:,::-1]
for side in (-1,1):
 for j in range(6):
  z=-.020+j*.006;tube('SideCoolingVent',[(side*.078,.000,z),(side*.078,.003,z+.002)],.001,6,sides=6)
bevel_box('RearBatteryPanel',(0,.015,.086),(.059,.027,.004),.002,0)
bevel_box('BatteryPowerButton',(0,.018,.089),(.011,.010,.002),.001,6)
for j in range(4):rect('BatteryChargeIndicator',(-.015+j*.010,.007,.089),(.005,.0015,.001),8)

# A small DJI word mark is embedded, so the GLB has no external dependencies.
fontpath='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
im=Image.new('RGB',(768,192),(232,237,242));draw=ImageDraw.Draw(im)
draw.text((384,95),'dji',font=ImageFont.truetype(fontpath,170),fill=(95,104,113),anchor='mm')
bio=io.BytesIO();im.save(bio,format='PNG');texture=bio.getvalue()
add('DJITopMark',[(-.019,.04603,-.005),(.019,.04603,-.005),(.019,.04603,.005),(-.019,.04603,.005)],[(0,2,1),(0,3,2)],5,uv=[(1,1),(0,1),(0,0),(1,0)],smooth=True)

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
 nodes.append({'name':'DJIPhantom','children':roots,'extras':{'reference':'image.png','approximate_dimensions':True,'forward':'-Z','units':'metres'}})
 imageview=blob(texture)
 doc={'asset':{'version':'2.0','generator':'Procedural reference-inspired DJI Phantom'},'scene':0,'scenes':[{'nodes':[len(nodes)-1]}],'nodes':nodes,'meshes':meshes,'materials':materials,'accessors':access,'bufferViews':views,'buffers':[{'byteLength':len(binary)}],'images':[{'bufferView':imageview,'mimeType':'image/png'}],'textures':[{'source':0}]}
 js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*((-len(js))%4);binary+=b'\0'*((-len(binary))%4)
 data=struct.pack('<4sII',b'glTF',2,12+8+len(js)+8+len(binary))+struct.pack('<I4s',len(js),b'JSON')+js+struct.pack('<I4s',len(binary),b'BIN\0')+binary
 (OUT/'dji_phantom.glb').write_bytes(data);return doc

def render():
 W,H=1400,1050;img=np.zeros((H,W,3),dtype=np.uint8);img[:]=[231,235,240];depth=np.full((H,W),-np.inf)
 eye=np.array([-.8,.65,-1.1]);eye/=np.linalg.norm(eye);right=np.cross([0,1,0],eye);right/=np.linalg.norm(right);up=np.cross(eye,right)
 scale=1900;light=np.array([-.5,1,-.7]);light/=np.linalg.norm(light)
 def world(i):
  p=parts[i];t=np.array(p['t'] if p['t'] is not None else [0,0,0],float);j=p['parent']
  while j is not None:
   t+=np.array(parts[j]['t'] if parts[j]['t'] is not None else [0,0,0]);j=parts[j]['parent']
  return p['v']+t
 for i,p in enumerate(parts):
  v=world(i);screen=np.stack([v@right*scale+W/2,-v@up*scale+H/2+25,v@eye],axis=1)
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
 d.text((45,35),'DJI PHANTOM',font=ImageFont.truetype(fontpath,35),fill=(45,55,65))
 d.text((45,83),'Reference-inspired 3D asset / Godot 4',font=ImageFont.truetype(fontpath,23),fill=(85,95,105))
 d.text((45,H-52),'Embedded materials  ·  independent rotors  ·  metres / Y up',font=ImageFont.truetype(fontpath,22),fill=(75,85,95));output.save(OUT/'preview.png')

if __name__=='__main__':
 merge_static_geometry();export_glb();render()
 print(json.dumps({'meshes':len(parts),'triangles':sum(len(p['f']) for p in parts),'vertices':sum(len(p['v']) for p in parts),'glb_bytes':(OUT/'dji_phantom.glb').stat().st_size}))
