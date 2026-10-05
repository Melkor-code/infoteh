"""Rebuild the reference-inspired drone with Python, NumPy and Pillow.
Units: metres; Y up; forward: -Z. Writes a self-contained glTF 2.0 GLB.
"""
from pathlib import Path
import json, struct, math, io
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
parts=[]
materials=[
 {'name':'White shell','pbrMetallicRoughness':{'baseColorFactor':[.91,.93,.94,1],'metallicFactor':.05,'roughnessFactor':.36}},
 {'name':'Graphite plastic','pbrMetallicRoughness':{'baseColorFactor':[.035,.043,.049,1],'metallicFactor':.05,'roughnessFactor':.48}},
 {'name':'Red propellers','pbrMetallicRoughness':{'baseColorFactor':[.84,.075,.055,1],'metallicFactor':.02,'roughnessFactor':.35},'doubleSided':True},
 {'name':'Motor aluminium','pbrMetallicRoughness':{'baseColorFactor':[.32,.35,.37,1],'metallicFactor':.8,'roughnessFactor':.29}},
 {'name':'Lens','pbrMetallicRoughness':{'baseColorFactor':[.012,.025,.04,1],'metallicFactor':.35,'roughnessFactor':.12}},
 {'name':'Shell graphics','pbrMetallicRoughness':{'baseColorTexture':{'index':0},'metallicFactor':.02,'roughnessFactor':.42}},
]
def add(name,v,f,mat=1,parent=None,translation=None,uv=None,smooth=False):
 v=np.asarray(v,float); f=np.asarray(f,int)
 if not smooth:
  v=v[f].reshape(-1,3); f=np.arange(len(v)).reshape(-1,3)
 n=np.zeros_like(v)
 for face in f:
  a,b,c=v[face]; normal=np.cross(b-a,c-a); n[face]+=normal
 n/=np.maximum(np.linalg.norm(n,axis=1)[:,None],1e-12)
 parts.append(dict(name=name,v=v,f=f,n=n,mat=mat,parent=parent,t=translation,uv=uv))
 return len(parts)-1
def prism(name,poly,y0,y1,mat=1,parent=None,translation=None):
 # poly must be counterclockwise in XZ; top faces point toward +Y
 N=len(poly); v=[(x,y,z) for y in (y0,y1) for x,z in poly]; f=[]
 for i in range(1,N-1): f.extend([(0,i,i+1),(N,N+i+1,N+i)])
 for i in range(N): j=(i+1)%N; f.extend([(i,N+i,N+j),(i,N+j,j)])
 return add(name,v,f,mat,parent,translation)
def rect(name,c,size,mat=1,parent=None):
 x,y,z=c; a,b,d=np.array(size)/2
 return prism(name,[(x-a,z-d),(x+a,z-d),(x+a,z+d),(x-a,z+d)],y-b,y+b,mat,parent)
def tube(name,points,radius,mat=1,closed=False,sides=8):
 pts=np.array(points); v=[]; f=[]
 for i,p in enumerate(pts):
  tang=pts[(i+1)%len(pts)]-pts[(i-1)%len(pts)] if closed else pts[min(i+1,len(pts)-1)]-pts[max(i-1,0)]
  tang/=np.linalg.norm(tang); ref=np.array([0.,1.,0.])
  if abs(np.dot(tang,ref))>.95: ref=np.array([1.,0.,0.])
  u=np.cross(tang,ref); u/=np.linalg.norm(u); w=np.cross(tang,u)
  for j in range(sides): v.append(p+radius*(math.cos(j*2*math.pi/sides)*u+math.sin(j*2*math.pi/sides)*w))
 for i in range(len(pts) if closed else len(pts)-1):
  ni=(i+1)%len(pts)
  for j in range(sides): a=i*sides+j;b=i*sides+(j+1)%sides;c=ni*sides+(j+1)%sides;d=ni*sides+j;f.extend([(a,b,c),(a,c,d)])
 return add(name,v,f,mat,smooth=True)
def cylinder(name,c,r,h,mat=1,parent=None):
 x,y,z=c; N=32; v=[];f=[]
 for yy in (y-h/2,y+h/2):
  for i in range(N): a=2*math.pi*i/N;v.append((x+r*math.cos(a),yy,z+r*math.sin(a)))
 for i in range(N): j=(i+1)%N;f.extend([(i,N+i,N+j),(i,N+j,j)])
 # separate vertices for hard caps
 for yy,up in ((y-h/2,False),(y+h/2,True)):
  base=len(v);v.append((x,yy,z))
  for i in range(N):a=2*math.pi*i/N;v.append((x+r*math.cos(a),yy,z+r*math.sin(a)))
  for i in range(N):a=base+1+i;b=base+1+(i+1)%N;f.append((base,b,a) if up else (base,a,b))
 return add(name,v,f,mat,parent,smooth=True)
def chamfer(w,d,k):return [(-w/2+k,-d/2),(w/2-k,-d/2),(w/2,-d/2+k),(w/2,d/2-k),(w/2-k,d/2),(-w/2+k,d/2),(-w/2,d/2-k),(-w/2,-d/2+k)]

# Angular, lightly domed upper shell, stepped black lower housing.
prism('LowerHousing',chamfer(.094,.150,.018),-.020,.000,1)
poly0=chamfer(.108,.170,.023);poly1=chamfer(.093,.149,.024)
v=[(x,y,z) for poly,y in ((poly0,-.002),(poly0,.010),(poly1,.026)) for x,z in poly];f=[]
for ring in range(2):
 for i in range(8):j=(i+1)%8;a=ring*8+i;b=ring*8+j;c=(ring+1)*8+j;d=(ring+1)*8+i;f.extend([(a,c,b),(a,d,c)])
for i in range(1,7): f.append((16,16+i+1,16+i))
add('UpperShell',v,f,0)

# Embedded top label texture, only on a planar panel.
im=Image.new('RGB',(512,768),(232,237,240));draw=ImageDraw.Draw(im)
fontpath='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
font=ImageFont.truetype(fontpath,45);small=ImageFont.truetype(fontpath,27)
draw.text((256,350),'POWER',font=font,fill=(32,35,38),anchor='mm')
draw.text((256,395),'PIONEER',font=small,fill=(40,43,45),anchor='mm')
draw.line([(204,250),(296,290),(272,250),(240,300)],fill=(229,105,34),width=13)
draw.rounded_rectangle((223,112,289,156),radius=20,fill=(15,20,24))
draw.line([(236,137),(269,131)],fill=(45,53,58),width=3)
bio=io.BytesIO();im.save(bio,format='PNG');texture=bio.getvalue()
v=[(-.030,.02615,-.061),(.030,.02615,-.061),(.030,.02615,.061),(-.030,.02615,.061)]
add('TopGraphics',v,[(0,2,1),(0,3,2)],5,uv=[(0,0),(1,0),(1,1),(0,1)],smooth=True)
for side in (-1,1):
 for z in (-.050,.044):rect('ShellLatch', (side*.047,.016,z),(.007,.006,.012),1)
 for z in (-.029,-.021,-.013):rect('SideVent',(side*.0542,.004,z),(.0015,.006,.0045),1)
rect('FrontCameraHousing',(0,-.005,-.076),(.031,.023,.009),1)
# lens lies on front face; small dark round cylinder rotated from Y to Z
idx=cylinder('FrontLens',(0,0,0),.006,.002,4)
p=parts[idx];p['v']=p['v'][:,[0,2,1]];p['v']+=np.array([0,-.004,-.0815]);p['n']=p['n'][:,[0,2,1]];p['f']=p['f'][:,::-1]

for i,(sx,sz) in enumerate([(-1,-1),(1,-1),(-1,1),(1,1)]):
 x=sx*.096;z=sz*.095
 # tapered load-bearing arm with upper ridge
 start=np.array([sx*.035,-.008,sz*.048]);end=np.array([x,-.008,z]);d=end-start;per=np.array([-d[2],0,d[0]]);per/=np.linalg.norm(per)
 poly=[(start[0]-per[0]*.010,start[2]-per[2]*.010),(end[0]-per[0]*.008,end[2]-per[2]*.008),(end[0]+per[0]*.008,end[2]+per[2]*.008),(start[0]+per[0]*.010,start[2]+per[2]*.010)]
 # enforce CCW
 if sum(poly[j][0]*poly[(j+1)%4][1]-poly[(j+1)%4][0]*poly[j][1] for j in range(4))<0:poly.reverse()
 prism('Arm_%d'%i,poly,-.015,-.001)
 tube('ArmRidge_%d'%i,[start+[0,.010,0],end+[0,.010,0]],.0025)
 cylinder('MotorMount_%d'%i,(x,-.011,z),.012,.032,1)
 cylinder('MotorCan_%d'%i,(x,.009,z),.009,.022,3)
 cylinder('MotorCollar_%d'%i,(x,.001,z),.0105,.007,1)
 cylinder('Shaft_%d'%i,(x,.024,z),.0025,.010,3)
 # Photo shows each loop raised along the outer edge. Rounded outward D shape.
 outward=np.array([sx,0,sz],float);outward/=np.linalg.norm(outward);side=np.array([-outward[2],0,outward[0]])
 pts=[]
 for j in range(64):
  a=2*math.pi*j/64;r=.048;along=r*math.cos(a)+.010
  pt=np.array([x,.002,z])+outward*along+side*(r*.88*math.sin(a));pt[1]+=.012*(math.cos(a)+1)/2;pts.append(pt)
 tube('PropGuard_%d'%i,pts,.003,1,True,8)
 for angle in (-.95,.95):
  target=np.array([x,.002,z])+outward*(.010+.048*math.cos(angle))+side*(.048*.88*math.sin(angle))
  tube('GuardBrace_%d'%i,[(x,-.023,z),(x,-.011,z),target],.0024)
 # Rotor is one mesh, centered at its shaft for animation.
 blade=[(.003,-.003),(.012,-.005),(.041,-.007),(.048,-.002),(.046,.003),(.018,.005),(.006,.004)]
 angle=(.20 if i%2 else -.30);co=math.cos(angle);si=math.sin(angle)
 rotor_v=[];rotor_f=[]
 for sign in (1,-1):
  poly=[(sign*(xx*co-zz*si),sign*(xx*si+zz*co)) for xx,zz in blade]
  temp=len(parts);prism('_blade',poly,-.001,.0012,2);p=parts.pop();offset=len(rotor_v);rotor_v.extend(p['v']);rotor_f.extend(p['f']+offset)
 rotor=add('Propeller_%d'%i,rotor_v,rotor_f,2,translation=[x,.028,z])
 cylinder('PropHub_%d'%i,(0,.001,0),.0055,.005,2,parent=rotor)
 cylinder('PropCap_%d'%i,(0,.004,0),.002,.002,1,parent=rotor)
 cylinder('LandingFoot_%d'%i,(x,-.032,z),.006,.012,1)

def export_glb():
 binary=bytearray();views=[];access=[];meshes=[];nodes=[]
 def blob(data,target=None):
  while len(binary)%4:binary.append(0)
  off=len(binary);binary.extend(data);view={'buffer':0,'byteOffset':off,'byteLength':len(data)}
  if target:view['target']=target
  views.append(view);return len(views)-1
 def acc(a,typ,ctype,target):
  view=blob(a.tobytes(),target);o={'bufferView':view,'componentType':ctype,'count':len(a),'type':typ}
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
 nodes.append({'name':'Drone','children':roots,'extras':{'reference':'IMG_8675.jpeg','approximate_dimensions':True,'forward':'-Z','units':'metres'}})
 texview=blob(texture)
 doc={'asset':{'version':'2.0','generator':'Reference drone procedural mesh'},'scene':0,'scenes':[{'nodes':[len(nodes)-1]}],'nodes':nodes,'meshes':meshes,'materials':materials,'accessors':access,'bufferViews':views,'buffers':[{'byteLength':len(binary)}],'images':[{'bufferView':texview,'mimeType':'image/png'}],'textures':[{'source':0}]}
 js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*((-len(js))%4);binary+=b'\0'*((-len(binary))%4)
 data=struct.pack('<4sII',b'glTF',2,12+8+len(js)+8+len(binary))+struct.pack('<I4s',len(js),b'JSON')+js+struct.pack('<I4s',len(binary),b'BIN\0')+binary
 (OUT/'drone.glb').write_bytes(data)
 return doc

def render():
 W,H=1200,900;img=np.zeros((H,W,3),dtype=np.uint8);img[:]=[236,239,242];depth=np.full((H,W),-np.inf)
 eye=np.array([.8,.95,1.1]);eye/=np.linalg.norm(eye);right=np.cross([0,1,0],eye);right/=np.linalg.norm(right);up=np.cross(eye,right)
 scale=2900;light=np.array([-.4,1,.4]);light/=np.linalg.norm(light)
 def world(i):
  p=parts[i];t=np.array(p['t'] if p['t'] is not None else [0,0,0],float)
  j=p['parent']
  while j is not None:
   t+=np.array(parts[j]['t'] if parts[j]['t'] is not None else [0,0,0]);j=parts[j]['parent']
  return p['v']+t
 for i,p in enumerate(parts):
  v=world(i);screen=np.stack([v@right*scale+W/2,-v@up*scale+H/2+20,v@eye],axis=1)
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
   norm=u[...,None]*p['n'][face[0]]+w[...,None]*p['n'][face[1]]+t[...,None]*p['n'][face[2]];shade=.50+.50*np.maximum(0,norm@light)
   color=np.broadcast_to(base,(*u.shape,3)).copy()
   if p['uv'] is not None:
    uv=u[...,None]*p['uv'][face[0]]+w[...,None]*p['uv'][face[1]]+t[...,None]*p['uv'][face[2]]
    tx=np.clip((uv[:,:,0]*511).astype(int),0,511);ty=np.clip((uv[:,:,1]*767).astype(int),0,767);color=np.array(im)[ty,tx].astype(float)
   color=np.clip(color*shade[...,None],0,255).astype(np.uint8);img[ymin:ymax+1,xmin:xmax+1][mask]=color[mask];region[mask]=zz[mask]
 output=Image.fromarray(img);d=ImageDraw.Draw(output);font=ImageFont.truetype(fontpath,28);d.text((45,35),'REFERENCE DRONE / GODOT 4',font=font,fill=(50,60,70));d.text((45,H-55),'Y up  ·  separate rotors  ·  embedded materials',font=ImageFont.truetype(fontpath,20),fill=(75,85,95));output.save(OUT/'preview.png')

if __name__=='__main__':
 doc=export_glb();render();print(json.dumps({'meshes':len(parts),'triangles':sum(len(p['f']) for p in parts),'vertices':sum(len(p['v']) for p in parts),'glb_bytes':(OUT/'drone.glb').stat().st_size}))
