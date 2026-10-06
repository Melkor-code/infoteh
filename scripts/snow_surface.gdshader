shader_type spatial;
uniform vec4 base_color : source_color = vec4(1.0);
uniform bool use_vertex_color = false;
uniform float snow_amount = 0.0;
varying vec3 world_normal;
varying vec3 world;
void vertex(){
 world_normal=normalize(MODEL_NORMAL_MATRIX*NORMAL);
 world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
void fragment(){
 vec3 base=base_color.rgb*(use_vertex_color?COLOR.rgb:vec3(1.0));
 float patches=0.82+0.18*sin(world.x*0.7)*sin(world.z*0.6);
 float top=smoothstep(0.15,0.8,world_normal.y);
 float cover=clamp(snow_amount*(0.12+top*1.1)*patches,0.0,1.0);
 ALBEDO=mix(base,vec3(0.86,0.89,0.93),cover);
 ROUGHNESS=mix(0.83,0.96,cover);
}
