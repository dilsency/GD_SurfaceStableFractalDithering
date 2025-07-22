shader_type spatial;
render_mode cull_back, unshaded;

uniform sampler2D albedo_tex : source_color;
uniform sampler2D albedo_tex_back : source_color;

uniform vec3 light_position = vec3(0,0,0);

varying vec3 global_vertex_position;

void vertex() {
	// Called for every vertex the material is visible on.

	// from local to world
	// https://www.reddit.com/r/godot/comments/gok070/comment/frga1vb/
	// ZERO clue why this is done in vertex() but normal calculation is done in fragment()
    global_vertex_position= (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Called for every pixel the material is visible on.
	
	// supposedly, NORMAL is in view space for whatever reason
	// https://forum.godotengine.org/t/how-to-calculate-world-and-view-normals/55711/2
	vec3 vertex_normal_world = (INV_VIEW_MATRIX * vec4(NORMAL.xyz, 0.0)).xyz;
	
	vec3 light_normal = normalize(global_vertex_position - light_position);
	
	float dotRes = dot(vertex_normal_world, light_normal);
	
	if(dotRes <= 0.0f)
	{
		ALBEDO    = vec3(1,0,0);   // Will be used in the light() pass
	}
	else {
		ALBEDO = vec3(0,1,0);
	}
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
