@tool
extends Node3D

@export_tool_button("Generate 3D Dither", "Callable") var generate_action = generate_dither

func generate_dither(recursion: int = 3) -> void:
	var bayer_points: Array[Vector2] = get_bayer_points(recursion)
	var dots_per_side: int = int(pow(2.0, float(recursion)))
	var layers: int = dots_per_side * dots_per_side
	var size: int = 16 * dots_per_side
	var bucket_count: int = 256
	var brightness_buckets := PackedInt32Array()
	brightness_buckets.resize(bucket_count)
	var brightness_buckets_2 := PackedInt32Array()
	brightness_buckets_2.resize(bucket_count)
	
	for i in bucket_count:
		brightness_buckets[i] = 0
		brightness_buckets_2[i] = 0

	var slices: Array[Image] = []
	var inv_res: float = 1.0 / float(size)

	for z: int in layers:
		var dot_count: int = z + 1
		var dot_area: float = 0.5 / dot_count
		var dot_radius: float = sqrt(dot_area / PI)
		var slice_img := Image.create(size, size, false, Image.FORMAT_R8)

		for y: int in size:
			for x: int in size:
				var point : Vector2 = Vector2((x + 0.5) * inv_res, (y + 0.5) * inv_res)
				var dist: float = 999999.0
				
				for bp in bayer_points.slice(0, dot_count):
					var vec:Vector2= point - bp
					vec.x = fmod(vec.x + 0.5, 1.0) - 0.5
					vec.y = fmod(vec.y + 0.5, 1.0) - 0.5
					dist = min(dist, vec.length())

				dist = dist / (dot_radius * 2.4)  # Key Rune constant
				var val :float = clampf(1.0 - dist, 0.0, 1.0)
				brightness_buckets[int(val * bucket_count)] += 1
				brightness_buckets_2[int(val * bucket_count)] += 1.5
				slice_img.set_pixel(x, y, Color(val, val, val))
		#slice_img.save_png("res://export/DitherSlice"+str(z)+".png")
		slices.append(slice_img)

	var dither_3d := ImageTexture3D.new()
	dither_3d.create(Image.FORMAT_R8, size, size, layers, false, slices)
	
	var brightness_ramp := compute_brightness_ramp(brightness_buckets, size, layers)
	var ramp_img := generate_ramp_image(brightness_ramp)
	ramp_img.save_png("res://export/DitherRamp.png")
	var ramp_tex := ImageTexture.create_from_image(ramp_img)
	
	var brightness_ramp_2 := compute_brightness_ramp(brightness_buckets_2, size, layers)
	var ramp_img_2 := generate_ramp_image(brightness_ramp_2)
	ramp_img_2.save_png("res://export/DitherRamp2.png")
	var ramp_tex_2 := ImageTexture.create_from_image(ramp_img_2)
	
	var stamp := int(Time.get_unix_time_from_system() * 1000.0)
	#ResourceSaver.save(dither_3d, "res://textures/dither/dither_3d_%d.tres" % stamp)
	#ResourceSaver.save(ramp_tex, "res://textures/dither ramp/full/dither_ramp_%d.tres" % stamp)
	ResourceSaver.save(ramp_tex_2, "res://textures/dither ramp/half/dither_ramp_2_%d.tres" % stamp)

func get_bayer_points(recursion: int) -> Array[Vector2]:
	var points :Array[Vector2]= [
		Vector2(0.00, 0.00), Vector2(0.50, 0.50),
		Vector2(0.50, 0.00), Vector2(0.00, 0.50)
	]
	
	for r in recursion - 1:
		var offset := pow(0.5, r + 1)
		var old_count := points.size()
		for i in range(1,4):
			for j in old_count:
				points.append(points[j] + points[i] * offset)
	
	return points

func compute_brightness_ramp(buckets: PackedInt32Array, size: int, layers: int) -> PackedFloat32Array:
	var pixel_count := float(size * size * layers)
	var ramp_full := PackedFloat32Array()
	ramp_full.resize(buckets.size() + 1)
	
	var accum := 0
	for i in buckets.size():
		var rev_idx := buckets.size() - 1 - i
		accum += buckets[rev_idx]
		ramp_full[i + 1] = float(accum) / pixel_count
	
	var lookup_ramp := PackedFloat32Array()
	lookup_ramp.resize(size)
	var higher_index := 1
	
	for x in size:
		var desired_b := float(x) / (size - 1)
		while higher_index < ramp_full.size() - 1 && ramp_full[higher_index] < desired_b:
			higher_index += 1
		
		var fraction := (desired_b - ramp_full[higher_index - 1]) / \
					   (ramp_full[higher_index] - ramp_full[higher_index - 1])
		lookup_ramp[x] = (higher_index - 1 + fraction) / (ramp_full.size() - 1)
	
	return lookup_ramp

func generate_ramp_image(ramp: PackedFloat32Array) -> Image:
	var img := Image.create(ramp.size(), 1, false, Image.FORMAT_R8)
	for x in ramp.size():
		img.set_pixel(x, 0.0, Color(ramp[x], ramp[x], ramp[x]))
	return img
