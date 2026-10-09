extends Node3D

# Полный цикл длится 12 реальных минут; ручная установка времени остаётся доступной. Изменение света и неба не меняет тягу.
var hour := 12.0
var cycling := false
var cycle_seconds := 720.0
var daylight := 1.0
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var sky_material: ShaderMaterial
var environment: Environment

func setup(next_environment: Environment) -> void:
	environment = next_environment
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200.0
	sun.light_color = Color(1, 0.95, 0.83)
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.shadow_enabled = true
	moon.light_color = Color(0.57, 0.69, 1.0)
	moon.shadow_blur = 4.0
	moon.light_angular_distance = 4.0
	moon.directional_shadow_max_distance = 100.0
	add_child(moon)
	var shader := Shader.new()
	shader.code = """shader_type sky;
uniform float daylight = 1.0;
uniform vec3 sun_dir = vec3(0.2,0.8,0.1);
uniform vec3 moon_dir = vec3(-0.2,-0.8,-0.1);
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
void sky(){
 vec3 d=normalize(EYEDIR);
 float up=clamp(d.y,0.0,1.0);
 vec3 night=mix(vec3(0.006,0.009,0.023),vec3(0.001,0.003,0.012),up);
 vec3 day=mix(vec3(0.47,0.67,0.87),vec3(0.09,0.28,0.64),sqrt(up));
 vec3 color=mix(night,day,daylight);
 vec2 uv=vec2(atan(d.z,d.x)/6.2831853+0.5,acos(clamp(d.y,-1.0,1.0))/3.1415926);
 vec2 grid=uv*vec2(640.0,320.0);
 vec2 cell=floor(grid);
 float seed=hash(cell);
 vec2 star_pos=vec2(hash(cell+2.7),hash(cell+8.2))*0.6+0.2;
 float star=(1.0-smoothstep(0.04,0.18,length(fract(grid)-star_pos)))*step(0.989,seed);
 color+=vec3(0.62,0.72,0.95)*star*(1.0-daylight)*smoothstep(0.0,0.12,d.y);
 float sun_disc=smoothstep(cos(0.013),cos(0.009),dot(d,sun_dir));
 float sun_glow=pow(max(dot(d,sun_dir),0.0),180.0)*0.18;
 color+=vec3(1.0,0.83,0.5)*(sun_disc+sun_glow)*daylight;
 float moon_disc=smoothstep(cos(0.019),cos(0.016),dot(d,moon_dir));
 float crater=0.82+0.18*sin(d.x*430.0)*sin(d.z*370.0);
 color+=vec3(0.64,0.72,0.86)*moon_disc*crater*(1.0-daylight);
 if(d.y<0.0){color=mix(vec3(0.002,0.005,0.008),vec3(0.13,0.20,0.14),daylight);}
 COLOR=color;
}
"""
	sky_material = ShaderMaterial.new()
	sky_material.shader = shader
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	environment.sky = sky
	environment.ambient_light_sky_contribution = 0.0
	update(0.0)

func update(delta: float) -> void:
	if cycling:
		hour = fposmod(hour + delta * 24.0 / cycle_seconds, 24.0)
	var phase := (hour - 6.0) / 24.0 * TAU
	var direction := Vector3(cos(phase), sin(phase), 0.25).normalized()
	daylight = smoothstep(-0.12, 0.22, direction.y)
	sun.position = direction * 500.0
	sun.look_at(Vector3.ZERO, Vector3.FORWARD)
	moon.position = -direction * 500.0
	moon.look_at(Vector3.ZERO, Vector3.FORWARD)
	sun.light_energy = daylight * 0.85
	sun.visible = daylight > 0.001
	sun.shadow_blur = 1.5
	moon.light_energy = (1.0 - daylight) * 0.055
	moon.visible = daylight < 0.99
	environment.ambient_light_color = Color(0.35, 0.44, 0.65).lerp(Color(0.63, 0.72, 0.85), daylight)
	environment.ambient_light_energy = lerpf(0.012, 0.30, daylight)
	environment.fog_light_color = Color(0.008, 0.014, 0.03).lerp(Color(0.55, 0.7, 0.88), daylight)
	environment.fog_density = lerpf(0.0015, 0.0006, daylight)
	sky_material.set_shader_parameter("daylight", daylight)
	sky_material.set_shader_parameter("sun_dir", direction)
	sky_material.set_shader_parameter("moon_dir", -direction)

func clock_text() -> String:
	var minutes := int(hour * 60.0) % 1440
	return "%02d:%02d" % [minutes / 60, minutes % 60]
