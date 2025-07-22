shader_type spatial;
render_mode depth_draw_opaque, cull_back;

// ----------------------------------------------------
//  UNIFORMS
// ----------------------------------------------------

// Base color/albedo texture (sRGB):
uniform sampler2D albedo_tex : source_color;

// 3D fractal dither texture (import as a Volume / 3D texture).
uniform sampler3D dither_tex;
// 1D brightness ramp (in a 2D image, e.g. 256×1), set to CLAMP.
uniform sampler2D dither_ramp_tex;

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

// nilstest
uniform int mode_cutoff = 0;
uniform int mode_alpha = 0;
uniform bool should_use_bands = false;
uniform int amount_bands = 4;
uniform int mode_bell = 0;
uniform vec2 bezier_point_a = vec2(0.0f, 0.0f);
uniform vec2 bezier_point_control = vec2(0.0f, 4.0f);
uniform vec2 bezier_point_b = vec2(1.0f, 0.0f);
uniform float alpha_twin_shift = 4.0f;

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

float get_alpha(float t, float howFastItMaxesOut)
{
    // when howFastItMaxesOut is 1
    // it will be a straight line
    // when howFastItMaxesOut grows
    // it will max out much sooner

    return 1.0f - pow(1.0f - t, howFastItMaxesOut);
}

float get_alpha_bell(float t, float steepness)
{
    return pow(4.0f, steepness) * pow(t * (1.0f - t), steepness);
}

float get_alpha_bell_bezier(float t)
{
    vec2 alpha0 = mix(bezier_point_a, bezier_point_control, t);
    vec2 alpha1 = mix(bezier_point_control, bezier_point_b, t);
    vec2 alpha2 = mix(alpha0, alpha1, t);
    return alpha2.y;
}

float get_alpha_bell_bezier_old(float t)
{
    // https://www.desmos.com/calculator/scz7zhonfw

    vec2 aMinusC = (bezier_point_a - bezier_point_control);
    vec2 bMinusC = (bezier_point_b - bezier_point_control);

    // our x needs to be between 0 and 1 for any of this to make sense
    vec2 a = bezier_point_control + (1.0f - t) * aMinusC;
    vec2 b = bezier_point_control + t * bMinusC;

    // result
    vec2 res = a + t * (b - a);
    return res.y;
}

float get_alpha_band_fade(float t, float left, float right)
{
    //
    float scale = 1.0f / right;
    float normalizedT = t * scale;
    //
    float midpoint = (left + right) / 2.0f;
    //
    if(t < midpoint){return mix(0.0f, 1.0f, t);}
    else {return mix(1.0f, 0.0f, normalizedT);}
}

float get_alpha_band(float t)
{
    // band will go from right to left
    float cutoffPoint = (1.0f / alpha_twin_shift);
    bool isWithinBand = (t >= 0.0f && t <= cutoffPoint);
    // early return: outside of band
    if(!isWithinBand){return 0.0f;}

    return get_alpha_band_fade(t, 0.0f, cutoffPoint);
}

float get_alpha_bell_twin(float t)
{
    // hardcoded for the moment, lol

    float cutoffPoint = (1.0f / alpha_twin_shift);

    if(t >= 0.0f && t <= cutoffPoint)
    {
        // suprisingly not hardcoded
        return -1.0f * alpha_twin_shift * t + 1.0f;
    }
    else if (t >= cutoffPoint && t <= 1.0f)
    {
        // hardcoded lmao
        // because how did they get 1.33? and 0.33? from a multiplier of 4.0, lmao
        // https://www.geogebra.org/m/UyfrABcN
        // (0.25, 0.0) and (1.0, 1.0)
        return 1.33f * t - 0.33f;
    }
    else {
        // we should never arrive here
        return 0.0f;
    }
}

float get_alpha_bell_twin_old(float t)
{
    // if shift is 1
    // the flip will occur when x == 0.5
    // increase shift
    // to move the flip point to the left

    bool isFirstHalf = (t <= (1.0f / alpha_twin_shift));

    if(isFirstHalf)
    {
        return (1.0f - t) * alpha_twin_shift;
    }
    else {
        return t * alpha_twin_shift;
    }
}

float get_alpha_bell_twin_old_2(float t)
{
    // if shift is 1
    // the flip will occur when x == 0.5
    // increase shift
    // to move the flip point to the left

    bool isFirstHalf = (t <= (1.0f / alpha_twin_shift));

    if(isFirstHalf)
    {
        return t * alpha_twin_shift;
    }
    else {
        return (1.0f - t) * alpha_twin_shift;
    }
}

float get_band_ndotl(float NdotL, int numberOfBands)
{
    if(numberOfBands <= 1)
    {
        return NdotL >= 0.5f ? 1.0f : 0.0f;
    }

    // NdotL is hopefully between 0 and 1?
    return floor(NdotL * float(numberOfBands)) / float(numberOfBands - 1);
}

// Apply dithering in Grayscale, RGB, or CMYK space.
vec3 dither_color(vec2 uv, vec2 dx, vec2 dy, vec3 col_in, float dotFirst, float NdotL)
{
    // dotFirst has a range of -1 to 1
    // NdotL has a range of 0 to 1, but half will be missing!

    //-------------------------------------------------------------------
    // Keep the same exposure + offset from your original:
    //   col_in -> col_in * input_exposure + input_offset
    //   (then clamp 0..1 so we don't feed negative or >1 into dithering)
    //-------------------------------------------------------------------
    vec3 col = col_in * input_exposure + input_offset;
    col = clamp(col, 0.0, 1.0);

    // you know what
    // let's just use another dither ramp texture
    // one that doesn't go to 0
    if(mode_bell < 0 && dotFirst < 0.0f)
    {
        // the unlit side
        float r = get_dither_3d(uv, dx, dy, col.r);
        float g = get_dither_3d(uv, dx, dy, col.g);
        float b = get_dither_3d(uv, dx, dy, col.b);
        return vec3(r,g,b) * 1.0f;
    }
    /*
    if(dotFirst < 0.0f)
    {
        vec2 dxTime = vec2(mod(dx.x + TIME, 2.0f), mod(dx.y + TIME, 2.0f));
        vec2 dyTime = vec2(mod(dy.x + TIME, 2.0f), mod(dy.y + TIME, 2.0f));

        dxTime = dx;
        dyTime = dy;

        // the unlit side
        float r = get_dither_3d(uv, dxTime, dyTime, col.r);
        float g = get_dither_3d(uv, dxTime, dyTime, col.g);
        float b = get_dither_3d(uv, dxTime, dyTime, col.b);
        return vec3(r,g,b) * 10.0f;
    }
    */

    if(mode_cutoff == 1)
    {
        float alphaBaseColor = 0.0f;
        float alphaDither = 1.0f;

        if(mode_alpha == 0)
        {
            // base
            alphaBaseColor = dotFirst;
            //alphaBaseColor = (dotFirst + 1.0f) / 2.0f;
            //
            alphaBaseColor = get_alpha(alphaBaseColor, 6.0f);
            //alphaBaseColor = max(alphaBaseColor + 20.5f, 1.0f);
            //alphaBaseColor = min(alphaBaseColor, 5.0f);



            //const float offset = 0.9f;
            //alpha += offset;
            //alphaInverse += offset;
            /*if(NdotL >= (1.0f - offset))
            {
                alpha += offset;
                alphaInverse += offset;
            }*/
        }
        else
        {
            alphaBaseColor = get_grayscale(col);
            /*alphaMin = 0.08;
            alphaMax = 0.28;
            alpha -= alphaMin;
            alpha /= (alphaMax - alphaMin);*/
        }

        // get banded alpha instead of lerped alpha
        if(should_use_bands && amount_bands != 1)
        {
            alphaBaseColor *= float(amount_bands);
            alphaBaseColor = floor(alphaBaseColor);
            alphaBaseColor /= float(amount_bands - 1);
        }

        // test only
        // round up some of the alpha
        //if(alphaBaseColor > 0.2f){alphaBaseColor = 1.0f;}

        //
        if(mode_bell == 0)
        {
            alphaDither = ((alphaBaseColor + 1.0f) / 2.0f);
            alphaDither = get_alpha_bell_bezier(alphaDither);
        }
        else if(mode_bell == 1) {
            alphaDither = mix(get_alpha_bell(alphaBaseColor, 1.5f), alphaBaseColor - 2.5f, 1.0f - alphaBaseColor);
            alphaDither *= 2.5f;
        }
        else if (mode_bell == 2)
        {
            alphaDither
            = get_alpha_bell_twin(
                dotFirst//((dotFirst + 1.0f) / 2.0f)
                );
        }
        else if (mode_bell == 3)
        {
            alphaDither
            = get_alpha_bell_twin_old(
                dotFirst//((dotFirst + 1.0f) / 2.0f)
                );
        }
        else if (mode_bell == 4)
        {
            alphaDither
            = get_alpha_bell_twin_old_2(
                dotFirst//((dotFirst + 1.0f) / 2.0f)
                );
        }
        else if (mode_bell == 5)
        {
            alphaDither
            = get_alpha_band(
                dotFirst//((dotFirst + 1.0f) / 2.0f)
                );
        }
        else if(mode_bell == 6) {
            alphaDither = 1.0f - alphaBaseColor;
            alphaDither = mix(alphaDither, 0.0f, alphaDither - 1.0f);
        }
        else {
            alphaDither = ((alphaBaseColor + 1.0f) / 2.0f);
        }

        //if(alphaDither > 0.1f){alphaDither = 1.0f - alphaDither;}
        //alphaDither = sin(alphaBaseColor * 3.14f * -2.0f);

        // Separate RGB channels
        float r = get_dither_3d(uv, dx, dy, col.r);
        float g = get_dither_3d(uv, dx, dy, col.g);
        float b = get_dither_3d(uv, dx, dy, col.b);

        // compensate in brightness for moving the alpha
        vec3 res = vec3(r, g, b) * 1.0f;

        // we blend colors
        // between the dither color
        // and our other two colors
        // based on our alpha
        // (that needs to be rescaled)
        // (to between 0 and 1)

        return (res * alphaDither) + (col * alphaBaseColor);

        /*
        float lumA = get_grayscale(col);
        if(lumA <= 0.08f)
        {
            return vec3(col * 0.2);
        }
        else if(lumA <= 0.12){

            return vec3(r, g, b) * 0.2;
            //return vec3(r,g,b);
        }
        else if (lumA >= 0.28)
        {
            return vec3(col);
        }
        else {
            return vec3(col);

            // Separate RGB channels
            float r = get_dither_3d(uv, dx, dy, col.r);
            float g = get_dither_3d(uv, dx, dy, col.g);
            float b = get_dither_3d(uv, dx, dy, col.b);
            return vec3(r, g, b);
        }
        */
    }
    else
    {
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
}

// ----------------------------------------------------
//  VERTEX
// ----------------------------------------------------
void vertex()
{
    // Pass UV directly, no special changes
}

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

	if (color_mode==-0){
		float lum = get_grayscale(base_col);
		ALBEDO = vec3(lum);
	}
	else{
    	ALBEDO    = base_col;   // Will be used in the light() pass
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
    // Basic lambert:
    float dotFirst = dot(NORMAL, LIGHT);
    dotFirst += 0.25f;// we can increase this to wrap around the model more
    float NdotL = dotFirst;
    NdotL = max(NdotL, 0.0);

    float alpha = dotFirst;

        float NdotLBanded = get_band_ndotl(NdotL, amount_bands);//NdotL;

        vec3 lambert_color = ALBEDO * LIGHT_COLOR * ATTENUATION * NdotLBanded;

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
        vec3 dithered = dither_color(UV, dx, dy, lambert_color, dotFirst, NdotL);

        // Optionally clamp again if you want to ensure no blow-out
        dithered = clamp(dithered, 0.0, 1.0);

        // Add to the total diffuse:
        vec3 resultDither = dithered;

        DIFFUSE_LIGHT += resultDither;

        // mix is a lerp, btw
        if(alpha >= 0.5f){
            //DIFFUSE_LIGHT += mix(vec3(0,0,0), vec3(1,0,0), alpha);
        }

        // (Optional) You can do a custom specular with dithering similarly:
        // float spec_angle = max(dot(reflect(-LIGHT, NORMAL), VIEW), 0.0);
        // float specular_strength = SPECULAR_AMOUNT;
        // vec3 spec_col = LIGHT_COLOR * pow(spec_angle, 64.0) * specular_strength * ATTENUATION;
        // vec3 dithered_spec = dither_color(UV, dx, dy, spec_col);
        // SPECULAR_LIGHT += clamp(dithered_spec, 0.0, 1.0);
}
