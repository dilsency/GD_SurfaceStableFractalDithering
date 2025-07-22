shader_type spatial;
render_mode depth_draw_opaque, cull_back, unshaded;

// ----------------------------------------------------
//  UNIFORMS
// ----------------------------------------------------

// Base color/albedo texture (sRGB):
uniform sampler2D albedo_tex : source_color;
uniform sampler2D albedo_tex_back : source_color;

uniform vec3  albedo_col_lit    : source_color    = vec3(0.0);
uniform vec3  albedo_col_unlit    : source_color    = vec3(0.0);

// 3D fractal dither texture (import as a Volume / 3D texture).
uniform sampler3D dither_tex;
// 1D brightness ramp (in a 2D image, e.g. 256×1), set to CLAMP.
uniform sampler2D dither_ramp_tex;
uniform sampler2D dither_ramp_tex_back;

//
uniform vec3 light_position = vec3(0,0,0);

// Must match the Z‐depth (slice count) of your 3D texture.
uniform float dots_total = 256.0;

// log2‐scale for the dot pattern. The actual multiplier is exp2(dither_scale).
uniform float dither_scale = 0.0;

// 0 = dot size shrinks a lot with brightness, 1 = minimal size change
uniform float dot_size_variability = 0.0;

// Makes final pattern more binary. Try ~1.0–2.0
uniform float dot_contrast = 1.0;

// Extra smoothing for angled surfaces
uniform float dot_stretch_smoothness = 1.0;

// Adjust the incoming color brightness
uniform float input_exposure = 1.0;
uniform float input_offset   = 0.0;

// Toggles for advanced features:
uniform bool use_radial_compensation = false;
uniform bool use_quantize_layers     = false;
uniform bool use_inverse_dots        = false;

// 0=Grayscale, 1=RGB, 2=CMYK
uniform int color_mode = 0;

// Basic PBR knobs
uniform float metallic    : hint_range(0,1) = 0.0;
uniform float roughness   : hint_range(0,1) = 0.5;
uniform vec3  emission    : source_color    = vec3(0.0);
uniform float emission_energy          = 1.0;

// Albedo UV transform
uniform vec2 albedo_uv_offset = vec2(0.0);
uniform vec2 albedo_uv_scale  = vec2(1.0);

// ----------------------------------------------------
//  HELPER FUNCTIONS
// ----------------------------------------------------

float get_grayscale(vec3 c) {
    // Standard luminance256
    return clamp(dot(c, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
}

vec2 rotate_uv(vec2 uv, vec2 dir) {
    // dir = (cos θ, sin θ)
    return vec2(
        uv.x * dir.x - uv.y * dir.y,
        uv.x * dir.y + uv.y * dir.x
    );
}

// Convert from RGB <-> CMYK
vec4 rgb_to_cmyk(vec3 rgb) {
    float k   = min(1.0 - rgb.r, min(1.0 - rgb.g, 1.0 - rgb.b));
    float inv = 1.0 - k;
    vec3 cmy  = vec3(0.0);
    if (inv > 0.0) {
        cmy = (1.0 - rgb - k) / inv;
    }
    return vec4(clamp(cmy, 0.0, 1.0), k);
}

vec3 cmyk_to_rgb(vec4 cmyk) {
    // cmyk=(C,M,Y,K). Basic formula: rgb=1−(cmyk.rgb*(1−k)+k)
    vec3 rgb = 1.0 - (cmyk.rgb * (1.0 - cmyk.w) + cmyk.w);
    return clamp(rgb, 0.0, 1.0);
}

// Sample brightness ramp similarly to RuneVision (with half‐texel offset)
float sample_brightness_ramp(float brightness) {
    float w = float(textureSize(dither_ramp_tex, 0).x);
    float inv_w = 1.0 / w;
    float samp_x = 0.5 * inv_w + (1.0 - inv_w) * brightness;
    return texture(dither_ramp_tex, vec2(samp_x, 0.5)).r;
}

// Core fractal dithering that takes derivatives for scale.
float get_dither_3d(
    vec2 uv,
    vec2 dx,
    vec2 dy,
    float brightness
){
    float b = use_inverse_dots ? (1.0 - brightness) : brightness;

    // Look up brightness ramp
    float corrected_b = sample_brightness_ramp(b);

    //------------------------
    // SVD derivative for freq
    //------------------------
    mat2 M = mat2(dx, dy);
    vec4 v = vec4(dx, dy);
    float Q = dot(v, v);      // sum of squares
    float R = determinant(M);  // ad - bc
    float disc_sq = max(0.0, Q*Q - 4.0 * R*R);
    float disc    = sqrt(disc_sq);
    // freq.x=larger singular value, freq.y=smaller
    vec2 freq = sqrt(0.5 * vec2(Q + disc, Q - disc));

    float spacing = freq.y; // use the smaller one as "spacing"
    float scale_exp = exp2(dither_scale);
    spacing *= scale_exp;

    // Dot size depends on brightness if dot_size_variability < 1.0
    float brightness_factor = pow(corrected_b * 2.0 + 0.001, -(1.0 - dot_size_variability));
    spacing *= brightness_factor;

    float spacing_log = log2(spacing);
    float lvl_floor   = floor(spacing_log);
    float f           = spacing_log - lvl_floor;

    // fractal uv
    vec2 fractal_uv = uv * exp2(-lvl_floor);

    // sub‐layer in 3D texture
    float sub_layer = mix(0.25 * dots_total, dots_total, 1.0 - f);
    float threshold_tweak = 1.0;
    if (use_quantize_layers) {
        float orig = sub_layer;
        sub_layer = floor(sub_layer + 0.5);
        threshold_tweak = sqrt(sub_layer / orig);
    }
    sub_layer = (sub_layer - 0.5) / dots_total;

    // 3D sample
    float pattern_val = texture(dither_tex, vec3(fractal_uv, sub_layer)).r;

    // Dot contrast, also factoring in freq ratio
    float contrast = dot_contrast * scale_exp * brightness_factor * 0.1;
    // scale by freq.y/freq.x ^ dot_stretch_smoothness
    contrast *= pow(freq.y / freq.x, dot_stretch_smoothness);

    float base_val = mix(0.5, b, clamp(1.05 / (1.0 + contrast), 0.0, 1.0));

    float thr = (1.0 - corrected_b);
    if (use_quantize_layers) {
        thr *= threshold_tweak;
    }

    float bw = clamp((pattern_val - thr) * contrast + base_val, 0.0, 1.0);

    // Re‐invert if needed
    if (use_inverse_dots) {
        bw = 1.0 - bw;
    }
    return bw;
}

// Apply dithering in Grayscale, RGB, or CMYK space.
vec3 dither_color(vec2 uv, vec2 dx, vec2 dy, vec3 col_in)
{
    //-------------------------------------------------------------------
    // Keep the same exposure + offset from your original:
    //   col_in -> col_in * input_exposure + input_offset
    //   (then clamp 0..1 so we don't feed negative or >1 into dithering)
    //-------------------------------------------------------------------
    vec3 col = col_in * input_exposure + input_offset;
    col = clamp(col, 0.0, 1.0);

    if (color_mode == 0) {
        // Grayscale
        float lum = get_grayscale(col);
        float v   = get_dither_3d(uv, dx, dy, lum);
        return vec3(v);
    }
    else if (color_mode == 1) {
        // Separate RGB channels
        float r = get_dither_3d(uv, dx, dy, col.r);
        float g = get_dither_3d(uv, dx, dy, col.g);
        float b = get_dither_3d(uv, dx, dy, col.b);
        return vec3(r, g, b);
    }
    else {
        // CMYK with halftone angles
        vec4 cmyk = rgb_to_cmyk(col);
        // Example angles: 15°, 75°, 0°, 45°
        cmyk.x = get_dither_3d(rotate_uv(uv, vec2(0.966, 0.259)), dx, dy, cmyk.x);
        cmyk.y = get_dither_3d(rotate_uv(uv, vec2(0.259, 0.966)), dx, dy, cmyk.y);
        cmyk.z = get_dither_3d(rotate_uv(uv, vec2(1.0,   0.0)),   dx, dy, cmyk.z);
        cmyk.w = get_dither_3d(rotate_uv(uv, vec2(0.707, 0.707)), dx, dy, cmyk.w);
        return cmyk_to_rgb(cmyk);
    }
}

varying vec3 global_vertex_position;

// ----------------------------------------------------
//  VERTEX
// ----------------------------------------------------
void vertex()
{
    // Pass UV directly, no special changes

	// from local to world
	// https://www.reddit.com/r/godot/comments/gok070/comment/frga1vb/
	// ZERO clue why this is done in vertex() but normal calculation is done in fragment()
    global_vertex_position= (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

const float alpha_cutoff = 0.3f;

// ----------------------------------------------------
//  FRAGMENT
//     Here we simply set the base ALBEDO and PBR properties.
//     We do NOT do dithering here. That happens in light().
// ----------------------------------------------------
void fragment()
{
    // Albedo UV transform
    vec2 uv_albedo = UV * albedo_uv_scale + albedo_uv_offset;

    // Sample base color from texture
    vec3 base_col = texture(albedo_tex, uv_albedo).rgb;
    vec3 back_col = texture(albedo_tex_back, uv_albedo).rgb;

	// supposedly, NORMAL is in view space for whatever reason
	// https://forum.godotengine.org/t/how-to-calculate-world-and-view-normals/55711/2
	vec3 vertex_normal_world = (INV_VIEW_MATRIX * vec4(NORMAL.xyz, 0.0)).xyz;

	vec3 light_normal = normalize(global_vertex_position - light_position);

	float dotRes = dot(vertex_normal_world, light_normal);

	vec2 dx = dFdx(UV);
   	vec2 dy = dFdy(UV);

	if(dotRes <= 0.0f)
	{
		// Apply fractal dithering (and exposure+offset) [[per-light]]:
	    vec3 dithered = dither_color(UV, dx, dy, albedo_col_unlit);
		// here, we COULD recolor all dots to be the unlit col
		// or check what dither_color actually does
		if(length(dithered) > 0.0f)
		{
			dithered = vec3(-0.5,-0.5,-0.5) + albedo_col_unlit * 10.0f;
		}

		bool isEdge;

		// both of these work
		//isEdge = (alpha_cutoff + dotRes) >= 0.0f;
		isEdge = dotRes >= -alpha_cutoff;

		ALBEDO = base_col + (isEdge ? dithered : vec3(0,0,0));
		//ALBEDO = base_col + mix(vec3(0,0,0), dithered, alpha);
	}
	else {
		// Apply fractal dithering (and exposure+offset) [[per-light]]:
	    vec3 dithered = dither_color(UV, dx, dy, albedo_col_lit);
		// here, we COULD recolor all dots to be the unlit col
		// or check what dither_color actually does
		if(length(dithered) > 0.0f)
		{
			dithered = albedo_col_lit;
		}

		bool isEdge = dotRes <= alpha_cutoff;

		ALBEDO = back_col + (isEdge ? dithered : vec3(0,0,0));
		//ALBEDO = back_col + mix(vec3(0,0,0), dithered, alpha);
	}

    METALLIC  = metallic;
    ROUGHNESS = roughness;
    EMISSION  = emission * emission_energy;
}

// ----------------------------------------------------
//  LIGHT
//    Called once per light. We compute the lambert (or
//    other) contribution, pass it into dither_color(),
//    then add it into DIFFUSE_LIGHT.
//
//    If multiple lights overlap, each will run this code
//    and sum into DIFFUSE_LIGHT.
// ----------------------------------------------------
void light()
{
	vec3 res = vec3(0,0,0);

		// Basic lambert:
	float dotRes = dot(NORMAL, LIGHT);
    float NdotL = max(dotRes, 0.0);
    vec3 lambert_color = ALBEDO * LIGHT_COLOR * ATTENUATION * NdotL;

	res = lambert_color;

	if(true == false) {

	    // We must compute dFdx, dFdy ourselves in the light pass:
	    vec2 dx = dFdx(UV);
	    vec2 dy = dFdy(UV);

	    if (use_radial_compensation) {
	        vec2 screen_uv = FRAGCOORD.xy / VIEWPORT_SIZE; // 0..1
	        vec2 ndc = screen_uv * 2.0 - 1.0;              // -1..+1
	        float fov_x = 1.0 / PROJECTION_MATRIX[0][0];
	        float fov_y = 1.0 / PROJECTION_MATRIX[1][1];
	        vec2 view_dir = vec2(ndc.x * fov_x, ndc.y * fov_y);
	        float radial_factor = dot(view_dir, view_dir) + 1.0;
	        dx *= radial_factor;
	        dy *= radial_factor;
	    }

	    // Apply fractal dithering (and exposure+offset) per-light:
	    vec3 dithered = dither_color(UV, dx, dy, lambert_color);

	    // Optionally clamp again if you want to ensure no blow-out
	    dithered = clamp(dithered, 0.0, 1.0);

		res = dithered;
	}

    // Add to the total diffuse:
    DIFFUSE_LIGHT += res;

    // (Optional) You can do a custom specular with dithering similarly:
    // float spec_angle = max(dot(reflect(-LIGHT, NORMAL), VIEW), 0.0);
    // float specular_strength = SPECULAR_AMOUNT;
    // vec3 spec_col = LIGHT_COLOR * pow(spec_angle, 64.0) * specular_strength * ATTENUATION;
    // vec3 dithered_spec = dither_color(UV, dx, dy, spec_col);
    // SPECULAR_LIGHT += clamp(dithered_spec, 0.0, 1.0);
}
