#define M_PI 3.14159265359
#define ONE_BY_PI (1 / 3.14159265359)

const vec2 POISSON_DISK_16[16] = vec2[](
	vec2(0.3568125,-0.5825516),
	vec2(-0.2828444,-0.1149732),
	vec2(-0.2575171,-0.579991),
	vec2(0.3328768,-0.0916517),
	vec2(-0.0177952,-0.9652126),
	vec2(0.7636694,-0.3370355),
	vec2(0.9381924,0.05975571),
	vec2(0.6547356,0.373677),
	vec2(-0.1999273,0.4483816),
	vec2(0.167026,0.2838214),
	vec2(0.2164582,0.6978411),
	vec2(-0.7202712,-0.07400024),
	vec2(-0.6624036,0.559697),
	vec2(-0.1909649,0.8721116),
	vec2(-0.6493049,-0.4945979),
	vec2(0.6104985,0.7838438)
);

struct Probe {
	vec4 pos;
	vec4 rot;
	vec4 inner_range;
	vec4 outer_range;
	vec4 sh_coefs0;
	vec4 sh_coefs1;
	vec4 sh_coefs2;
	vec4 sh_coefs3;
	vec4 sh_coefs4;
	vec4 sh_coefs5;
	vec4 sh_coefs6;
	vec4 sh_coefs7;
	vec4 sh_coefs8;
};

struct Light {
	vec4 pos_radius;
	vec4 rot;
	vec4 color_attn;
	int atlas_idx;
	float fov;
	vec2 padding;
};

struct Cluster {
	int offset;
	int lights_count;
	int probes_count;
};

struct Surface {
	vec3 albedo;
	float alpha;
	float roughness;
	float metallic;
	float emission;
	vec3 N;
	vec3 V;
	vec3 wpos;
};

layout(std430, binding = 6) readonly buffer lights
{
	Light b_lights[];
};

layout(std430, binding = 7) readonly buffer clusters
{
	Cluster b_clusters[];
};
	
layout(std430, binding = 8) readonly buffer cluster_maps
{
	int b_cluster_map[];
};

layout(std430, binding = 9) readonly buffer probes
{
	Probe b_probes[];
};


float saturate(float a) { return clamp(a, 0, 1); }
vec2 saturate(vec2 a) { return clamp(a, vec2(0), vec2(1)); }
vec3 saturate(vec3 a) { return clamp(a, vec3(0), vec3(1)); }
vec4 saturate(vec4 a) { return clamp(a, vec4(0), vec4(1)); }

float luminance(vec3 color) {
	return dot(vec3(0.2126729, 0.7151522, 0.0721750), color);
}

vec4 fullscreenQuad(int vertexID, out vec2 uv) {
	uv = vec2((vertexID & 1) * 2, vertexID & 2);
	#ifdef _ORIGIN_BOTTOM_LEFT
		return vec4(uv * 2 - 1, 0, 1);
	#else
		return vec4(uv.x * 2 - 1, -uv.y * 2 + 1, 0, 1);
	#endif
}

float packEmission(float emission)
{
	return log2(1 + emission / 64);
}


float unpackEmission(float emission)
{
	return (exp2(emission) - 1) * 64;
}


// TODO optimize
float toLinearDepth(mat4 inv_proj, float ndc_depth)
{
	vec4 pos_proj = vec4(0, 0, ndc_depth, 1.0);
	
	vec4 view_pos = inv_proj * pos_proj;
	
	return -view_pos.z / view_pos.w;
}

#ifdef LUMIX_FRAGMENT_SHADER
	Cluster getCluster(float ndc_depth)
	{
		ivec3 cluster;
		ivec2 fragcoord = ivec2(gl_FragCoord.xy);
		#ifndef _ORIGIN_BOTTOM_LEFT
			fragcoord.y = u_framebuffer_size.y - fragcoord.y - 1;
		#endif

		cluster = ivec3(fragcoord.xy / 64, 0);
		float linear_depth = toLinearDepth(u_camera_inv_projection, ndc_depth);
		cluster.z = int(log(linear_depth) * 16 / (log(10000 / 0.1)) - 16 * log(0.1) / log(10000 / 0.1));
		ivec2 tiles = (u_framebuffer_size + 63) / 64;
		cluster.y = tiles.y - 1 - cluster.y;
		return b_clusters[cluster.x + cluster.y * tiles.x + cluster.z * tiles.x * tiles.y];
	}

	Cluster getClusterLinearDepth(float linear_depth)
	{
		ivec3 cluster;
		ivec2 fragcoord = ivec2(gl_FragCoord.xy);
		#ifndef _ORIGIN_BOTTOM_LEFT
			fragcoord.y = u_framebuffer_size.y - fragcoord.y - 1;
		#endif

		cluster = ivec3(fragcoord.xy / 64, 0);
		cluster.z = int(log(linear_depth) * 16 / (log(10000 / 0.1)) - 16 * log(0.1) / log(10000 / 0.1));
		ivec2 tiles = (u_framebuffer_size + 63) / 64;
		cluster.y = tiles.y - 1 - cluster.y;
		return b_clusters[cluster.x + cluster.y * tiles.x + cluster.z * tiles.x * tiles.y];
	}
#endif

vec2 raySphereIntersect(vec3 r0, vec3 rd, vec3 s0, float sr) {
	vec3 s0_r0 = s0 - r0;
	float tc = dot(s0_r0, rd);
	float d2 = dot(s0_r0, s0_r0) - tc * tc;
	float sr2 = sr * sr;
	if (d2 > sr2) return vec2(-1);
	float td2 = sr2 - d2;
	float td = sqrt(td2);
	return vec2(tc - td, tc + td);
}

vec3 getWorldNormal(vec2 frag_coord)
{
	float z = 1;
	#ifdef _ORIGIN_BOTTOM_LEFT
		vec4 posProj = vec4(frag_coord * 2 - 1, z, 1.0);
	#else
		vec4 posProj = vec4(vec2(frag_coord.x, 1-frag_coord.y) * 2 - 1, z, 1.0);
	#endif
	vec4 wpos = u_camera_inv_view_projection * posProj;
	wpos /= wpos.w;
	vec3 view = (u_camera_inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz - wpos.xyz;

	return -normalize(view);
}

vec3 getViewPosition(sampler2D depth_buffer, mat4 inv_view_proj, vec2 tex_coord, out float ndc_depth)
{
	float z = texture(depth_buffer, tex_coord).r;
	#ifdef _ORIGIN_BOTTOM_LEFT
		vec4 pos_proj = vec4(vec2(tex_coord.x, tex_coord.y) * 2 - 1, z, 1.0);
	#else 
		vec4 pos_proj = vec4(vec2(tex_coord.x, 1-tex_coord.y) * 2 - 1, z, 1.0);
	#endif
	vec4 view_pos = inv_view_proj * pos_proj;
	ndc_depth = z;
	return view_pos.xyz / view_pos.w;
}

vec3 getViewPosition(sampler2D depth_buffer, mat4 inv_view_proj, vec2 tex_coord)
{
	float z = texture(depth_buffer, tex_coord).r;
	#ifdef _ORIGIN_BOTTOM_LEFT
		vec4 pos_proj = vec4(vec2(tex_coord.x, tex_coord.y) * 2 - 1, z, 1.0);
	#else 
		vec4 pos_proj = vec4(vec2(tex_coord.x, 1-tex_coord.y) * 2 - 1, z, 1.0);
	#endif
	vec4 view_pos = inv_view_proj * pos_proj;
	return view_pos.xyz / view_pos.w;
}

float random (vec2 st) {
    return fract(sin(dot(st.xy, vec2(12.9898,78.233))) * 43758.5453123);
}

float getShadowSimple(sampler2D shadowmap, vec3 wpos)
{
	#ifdef LUMIX_FRAGMENT_SHADER
		vec4 pos = vec4(wpos, 1);

		vec2 sm_size = 3.0 / textureSize(shadowmap, 0);
		for (int slice = 0; slice < 4; ++slice) {
			vec4 sc = u_shadowmap_matrices[slice] * pos;
			sc = sc / sc.w;
			if (all(lessThan(sc.xyz, vec3(0.99))) && all(greaterThan(sc.xyz, vec3(0.01)))) {
				vec2 sm_uv = vec2(sc.x * 0.25 + slice * 0.25, sc.y);
				float shadow = 0;
				float receiver = sc.z;
				float occluder = textureLod(shadowmap, sm_uv, 0).r;
				return saturate((receiver - occluder) * 10e3);
			}
		}
	#endif
	return 1;
}

float getShadow(sampler2D shadowmap, vec3 wpos, vec3 N)
{
	#ifdef LUMIX_FRAGMENT_SHADER
		vec4 pos = vec4(wpos, 1);

		vec2 sm_size = 3.0 / textureSize(shadowmap, 0);
		float offsets[] = float[](0.0002, 0.0005, 0.0014, 0.004);
		float bias = max(0.05 * (1.0 - saturate(dot(N, u_light_direction.xyz))), 0.005); 
		float NdL = saturate(dot(N, u_light_direction.xyz));
		for (int slice = 0; slice < 4; ++slice) {
			vec4 sc = u_shadowmap_matrices[slice] * pos;
			sc = sc / sc.w;
			if (all(lessThan(sc.xyz, vec3(0.99))) && all(greaterThan(sc.xyz, vec3(0.01)))) {
				// TODO use texture instead
				float rnd = random(vec2(gl_FragCoord));
				float c = cos(rnd); 
				float s = sin(rnd); 
				mat2 rot = mat2(c, s, -s, c);
				vec2 sm_uv = vec2(sc.x * 0.25 + slice * 0.25, sc.y);
				float shadow = 0;
				float receiver = sc.z;
				float offset = offsets[slice] * (4 - 3 * NdL * NdL);
				for (int j = 0; j < 16; ++j) {
					vec2 uv = sm_uv + POISSON_DISK_16[j] * rot * sm_size;

					float occluder = textureLod(shadowmap, uv, 0).r;
					shadow += saturate((receiver + offset - occluder) * 10e3);
				}
				return shadow / 16;
			}
		}
	#endif
	return 1;
}

float D_GGX(float ndoth, float roughness)
{
	float a = roughness * roughness;
	float a2 = a * a;
	float f = max(1e-5, (ndoth * ndoth) * (a2 - 1) + 1);
	return a2 / (f * f * M_PI);
}
		

float G_SmithSchlickGGX(float ndotl, float ndotv, float roughness)
{
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;
	float l = ndotl / (ndotl * (1.0 - k) + k);
	float v = ndotv / (ndotv * (1.0 - k) + k);
	return l * v;
}


vec3 F_Schlick(float cos_theta, vec3 F0)
{
	return mix(F0, vec3(1), pow(1.0 - cos_theta, 5.0)); 
}

vec3 computeDirectLight(Surface surface, vec3 L, vec3 light_color)
{
	vec3 F0 = vec3(0.04);
	F0 = mix(F0, surface.albedo, surface.metallic);		
	
	float ndotv = abs(dot(surface.N, surface.V)) + 1e-5f;
	vec3 H = normalize(surface.V + L);
	float ldoth = saturate(dot(L, H));
	float ndoth = saturate(dot(surface.N, H));
	float ndotl = saturate(dot(surface.N, L));
	float hdotv = saturate(dot(H, surface.V));
	
	// D GGX
	float a = surface.roughness * surface.roughness;
	float a2 = a * a;
	float f = max(1e-5, (ndoth * ndoth) * (a2 - 1) + 1);
	float D = a2 / (f * f * M_PI);

	// V Smith GGX height-correlated approximation
    float GGXV = ndotl * (ndotv * (1.0 - a) + a);
    float GGXL = ndotv * (ndotl * (1.0 - a) + a);
	float V = 0.5 / (GGXV + GGXL);

	// F Schlick 
	vec3 F = F_Schlick(hdotv, F0);// mix(F0, vec3(1), pow(1.0 - hdotv, 5.0)); 
	
	vec3 specular = D * V * F * 0.25;
	
	vec3 kD = vec3(1.0) - F;
	kD *= 1.0 - surface.metallic;
	
	return (kD * surface.albedo / M_PI + specular) * light_color * ndotl;
}	


vec3 env_brdf_approx (vec3 F0, float roughness, float NoV)
{
	vec4 c0 = vec4(-1, -0.0275, -0.572, 0.022 );
	vec4 c1 = vec4(1, 0.0425, 1.0, -0.04 );
	vec4 r = roughness * c0 + c1;
	float a004 = min( r.x * r.x, exp2( -9.28 * NoV ) ) * r.x + r.y;
	vec2 AB = vec2( -1.04, 1.04 ) * a004 + r.zw;
	return F0 * AB.x + AB.y;
}

vec3 computeIndirectDiffuse(vec3 irradiance, Surface surface) {
	float ndotv = abs(dot(surface.N , surface.V)) + 1e-5f;
	vec3 F0 = mix(vec3(0.04), surface.albedo, surface.metallic);		
	vec3 F = F_Schlick(ndotv, F0);
	vec3 kd = mix(vec3(1.0) - F, vec3(0.0), surface.metallic);
	return surface.albedo * irradiance;
}


vec3 computeIndirectSpecular(samplerCube radiancemap, Surface surface) {
	float ndotv = abs(dot(surface.N , surface.V)) + 1e-5f;
	vec3 F0 = mix(vec3(0.04), surface.albedo, surface.metallic);		
	float lod = surface.roughness * 5;
	vec3 RV = reflect(-surface.V, surface.N);
	vec4 radiance_rgbm = textureLod(radiancemap, RV, lod);
	vec3 radiance = radiance_rgbm.rgb * radiance_rgbm.a * 4;
	return radiance * env_brdf_approx(F0, surface.roughness, ndotv);
}

vec3 evalSH(Probe probe, vec3 N) {
	return probe.sh_coefs0.rgb
	+ probe.sh_coefs1.rgb * (N.y)
	+ probe.sh_coefs2.rgb * (N.z)
	+ probe.sh_coefs3.rgb * (N.x)
	+ probe.sh_coefs4.rgb * (N.y * N.x)
	+ probe.sh_coefs5.rgb * (N.y * N.z)
	+ probe.sh_coefs6.rgb * (3.0 * N.z * N.z - 1.0)
	+ probe.sh_coefs7.rgb * (N.z * N.x)
	+ probe.sh_coefs8.rgb * (N.x * N.x - N.y * N.y);
}

vec3 rotateByQuat(vec4 rot, vec3 pos)
{
	vec3 uv = cross(rot.xyz, pos);
	vec3 uuv = cross(rot.xyz, uv);
	uv *= (2.0 * rot.w);
	uuv *= 2.0;

	return pos + uv + uuv;
}

vec3 envProbesLighting(Cluster cluster, Surface surface) {
	float remaining_w = 1;
	vec3 probe_light = vec3(0);
	int from = cluster.offset + cluster.lights_count;
	int to = from + cluster.probes_count;
	for (int i = from; i < to; ++i) {
		int probe_idx = b_cluster_map[i]; 
		vec3 lpos = b_probes[probe_idx].pos.xyz - surface.wpos.xyz;
		vec4 rot = b_probes[probe_idx].rot;
		vec3 outer_range = b_probes[probe_idx].outer_range.xyz;
		vec3 inner_range = b_probes[probe_idx].inner_range.xyz;
			
		lpos = rotateByQuat(rot, lpos);
		lpos = max(abs(lpos) - inner_range, vec3(0));
		vec3 range = max(outer_range - inner_range, vec3(1e-5));

		vec3 rel = saturate(abs(lpos / range));
		float w = 1 - max(max(rel.x, rel.z), rel.y);
		if (w < 1e-5) continue;
			
		w = min(remaining_w, w);
		remaining_w -= w;

		vec3 irradiance = evalSH(b_probes[probe_idx], surface.N);
		irradiance = max(vec3(0), irradiance);
		vec3 indirect = computeIndirectDiffuse(irradiance, surface);
		probe_light += (indirect * u_light_indirect_intensity) * w / M_PI;
		if (remaining_w <= 0) break;
	}
	return remaining_w < 1 ? probe_light / (1 - remaining_w) : vec3(0);
}

vec3 pointLightsLighting(Cluster cluster, Surface surface, sampler2D shadow_atlas) {
	vec3 res = vec3(0);
	for (int i = cluster.offset; i < cluster.offset + cluster.lights_count; ++i) {
		int light_idx = b_cluster_map[i]; 
		vec3 lpos = surface.wpos.xyz - b_lights[light_idx].pos_radius.xyz;
		float dist = length(lpos);
		float attn = pow(max(0, 1 - dist / b_lights[light_idx].pos_radius.w), b_lights[light_idx].color_attn.w);
		vec3 L = -lpos / dist;
		if (attn > 1e-5) {
			vec3 direct_light = computeDirectLight(surface, L, b_lights[light_idx].color_attn.rgb);
			int atlas_idx = b_lights[light_idx].atlas_idx;
			if (atlas_idx >= 0) {
				vec4 proj_pos = u_shadow_atlas_matrices[atlas_idx] * vec4(lpos, 1);
				proj_pos /= proj_pos.w;

				vec2 shadow_uv = proj_pos.xy;
				float occluder = textureLod(shadow_atlas, shadow_uv, 0).r;
				float receiver = proj_pos.z;
				attn *= receiver * 1.01 > occluder ? 1 : 0;
			}

			float fov = b_lights[light_idx].fov;
			if (fov < M_PI) {
				// TODO replace rot with dir
				vec3 dir = rotateByQuat(b_lights[light_idx].rot, vec3(0, 0, -1));
				vec3 L = lpos / max(dist, 1e-5);
				float cosDir = dot(normalize(dir), L);
				float cosCone = cos(fov * 0.5);

				attn *= cosDir < cosCone ? 0 : (cosDir - cosCone) / (1 - cosCone);
			}

			res += direct_light * attn;
		}
	}
	return res;
}

float rand(vec3 seed)
{
	float dot_product = dot(seed, vec3(12.9898,78.233,45.164));
	return fract(sin(dot_product) * 43758.5453);
}

vec3 vegetationAnim(vec3 obj_pos, vec3 vertex_pos) {
	obj_pos += u_camera_world_pos.xyz;
	vertex_pos.x += vertex_pos.y > 0.1 ? cos((obj_pos.x + obj_pos.y + obj_pos.z * 2) * 0.3 + u_time * 2) * vertex_pos.y * vertex_pos.y * 0.001 : 0;
	return vertex_pos;
}

void packSurface(Surface surface, out vec4 gbuffer0, out vec4 gbuffer1, out vec4 gbuffer2) {
	gbuffer0 = vec4(surface.albedo.rgb, surface.roughness);
	gbuffer1 = vec4(surface.N * 0.5 + 0.5, surface.metallic);
	gbuffer2 = vec4(packEmission(surface.emission), 0, 0, 1);
}

Surface unpackSurface(vec2 uv, sampler2D gbuffer0, sampler2D gbuffer1, sampler2D gbuffer2, sampler2D gbuffer_depth, out float ndc_depth) {
	vec4 gb0 = texture(gbuffer0, uv);
	vec4 gb1 = texture(gbuffer1, uv);
	vec4 gb2 = texture(gbuffer2, uv);

	Surface surface;
	surface.albedo = gb0.rgb;
	surface.N = gb1.rgb * 2 - 1;
	surface.roughness = gb0.a;
	surface.metallic = gb1.a;
	surface.emission = unpackEmission(gb2.x);
	surface.wpos = getViewPosition(gbuffer_depth, u_camera_inv_view_projection, uv, ndc_depth);
	surface.V = normalize(-surface.wpos);
	return surface;
}

vec3 computeLighting(Cluster cluster, Surface surface, vec3 light_direction, vec3 light, sampler2D shadowmap, sampler2D shadow_atlas) {
	float shadow = getShadow(shadowmap, surface.wpos, surface.N);
	vec3 res = computeDirectLight(surface
		, light_direction
		, light * shadow);
	res += surface.emission * surface.albedo;
	res += pointLightsLighting(cluster, surface, shadow_atlas);
	res += envProbesLighting(cluster, surface);
	return res;
}
