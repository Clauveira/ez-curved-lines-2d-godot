extends Node2D

## Watches the whole configuration matrix being dragged at once.
##
## collision_matrix.tscn holds nine ScalableVectorShape2D covering every combination of
## extrusion_direction and collision_mode, and all nine point at the same Curve2D - so
## moving one point moves all of them, and one spiral sweeps the matrix. Each shape is
## labelled with its combination and turns red the moment the editor would fail to draw
## its collider, which is the part that was hardest to work out by reading logs.
##
## The colliders are drawn here the way the editor draws them: convex-decomposed, one
## fill per piece. A piece the editor could not fill is a piece missing from the
## picture, so the defect is visible rather than merely reported.
##
## Run it with:
##   Godot4.4.exe --path . res://addons/curved_lines_2d/tests/spiral_matrix_visual.tscn

const SCENE_PATH := "res://collision_matrix.tscn"
const REVOLUTIONS := 3.0
const MAX_RADIUS := 80.0
const SECONDS_PER_POINT := 2.5
const SCENE_OFFSET := Vector2(60, 150)

const EXTRUSION_NAMES := ["MIDDLE", "OUTWARD", "INWARD"]
const MODE_NAMES := ["MERGED", "FILL_ONLY", "STROKE_ONLY"]

var scene_root : Node2D
var shapes : Array = []
var everything : Array = []
var dragged_curve : Curve2D
var dragging_clip := false
var point_index := 0
var elapsed := 0.0
var paused := false
var origin := Vector2.ZERO
var offset := Vector2.ZERO
var font : Font
var frame_ms_worst := 0.0
var frame_ms_average := 0.0
var plugin_ms := 0.0
var inspect_ms := 0.0
# collider -> its convex pieces, decomposed once a frame and reused by the drawing.
# Deciding whether a collider is drawable and then drawing it are the same question
# asked twice, and the partitioner is far too expensive to ask twice.
var pieces_of := {}

# per shape, by name
var problem := {}
var shortfall := {}
var ever_failed := {}

@onready var readout : Label = $Readout


func _ready() -> void:
	font = ThemeDB.fallback_font
	if not ResourceLoader.exists(SCENE_PATH):
		readout.text = "%s is not in this project.\nThis runner drives that fixture scene." % SCENE_PATH
		set_process(false)
		return
	scene_root = (load(SCENE_PATH) as PackedScene).instantiate()
	scene_root.position = SCENE_OFFSET
	# a child paints over whatever its parent drew, so the scene has to sit behind this
	# node for the collider overlay to be visible at all
	scene_root.z_index = -1
	add_child(scene_root)
	everything = scene_root.find_children("*", "ScalableVectorShape2D", true, false)
	for svs in everything:
		svs._update_curve()
	shapes = everything.filter(func(s): return is_instance_valid(s.collision_object))
	for svs in shapes:
		ever_failed[svs.name] = false
		problem[svs.name] = ""
		shortfall[svs.name] = 0.0
	_switch_to(false)


func _switch_to(clip : bool) -> void:
	if is_instance_valid(dragged_curve) and shapes.size() > 0:
		dragged_curve.set_point_position(point_index, origin)
		for svs in everything:
			svs._update_curve()
	dragging_clip = clip
	var pool := everything.filter(func(s): return is_instance_valid(s.collision_object) != clip)
	if pool.is_empty():
		return
	dragged_curve = pool[0].curve
	point_index = 0
	elapsed = 0.0
	origin = dragged_curve.get_point_position(0)


func _process(delta : float) -> void:
	if not is_instance_valid(dragged_curve):
		return
	if not paused:
		elapsed += delta
		if elapsed >= SECONDS_PER_POINT:
			elapsed = 0.0
			dragged_curve.set_point_position(point_index, origin)
			point_index = (point_index + 1) % dragged_curve.point_count
			origin = dragged_curve.get_point_position(point_index)
		var t := elapsed / SECONDS_PER_POINT
		offset = Vector2(MAX_RADIUS * t, 0).rotated(TAU * REVOLUTIONS * t)
		dragged_curve.set_point_position(point_index, origin + offset)
		var started := Time.get_ticks_usec()
		for svs in everything:
			svs._update_curve()
		plugin_ms = lerpf(plugin_ms, (Time.get_ticks_usec() - started) / 1000.0, 0.05)
	# the runner recomputes nine shapes every frame, so its frame time is a fair measure
	# of what the plugin costs while a point is being dragged
	var frame_ms := delta * 1000.0
	frame_ms_average = frame_ms if frame_ms_average == 0.0 else lerpf(frame_ms_average, frame_ms, 0.05)
	if not paused:
		frame_ms_worst = maxf(frame_ms_worst, frame_ms)
	var inspect_started := Time.get_ticks_usec()
	_inspect()
	inspect_ms = lerpf(inspect_ms, (Time.get_ticks_usec() - inspect_started) / 1000.0, 0.05)
	queue_redraw()
	readout.text = _status()


func _inspect() -> void:
	pieces_of.clear()
	for svs in shapes:
		problem[svs.name] = ""
		for collider in _colliders(svs):
			if collider.polygon.size() < 3:
				continue
			var pieces := Geometry2D.decompose_polygon_in_convex(collider.polygon)
			pieces_of[collider.get_instance_id()] = pieces
			if pieces.is_empty():
				problem[svs.name] = "%s cannot be decomposed" % collider.name
				break
			var failed := false
			for i in pieces.size():
				if Geometry2D.triangulate_polygon(pieces[i]).is_empty():
					problem[svs.name] = "%s piece %d of %d" % [collider.name, i, pieces.size()]
					failed = true
					break
			if failed:
				break
		if problem[svs.name] == "" and is_instance_valid(svs.polygon):
			var fill_points : PackedVector2Array = svs.polygon.polygon
			if fill_points.size() > 2:
				if svs.polygon.polygons.is_empty():
					if Geometry2D.triangulate_polygon(fill_points).is_empty():
						problem[svs.name] = "fill of %d pts" % fill_points.size()
				else:
					for ranges in svs.polygon.polygons:
						var sub : PackedVector2Array = []
						for index in ranges:
							if index < fill_points.size():
								sub.append(fill_points[index])
						if sub.size() > 2 and Geometry2D.triangulate_polygon(sub).is_empty():
							problem[svs.name] = "fill piece of %d pts" % sub.size()
							break
		var covered := 0.0
		for collider in _colliders(svs):
			covered += Geometry2DUtil.get_polygon_area(collider.polygon)
		var fill : Array[PackedVector2Array] = []
		if svs.clip_paths.is_empty():
			fill = [svs.cached_outline] as Array[PackedVector2Array]
		else:
			fill = svs.cached_clipped_polygons
		var wanted := 0.0
		for contour in svs._get_collision_polygons(fill):
			wanted += Geometry2DUtil.get_polygon_area(contour)
		shortfall[svs.name] = 0.0 if wanted <= 1.0 else 100.0 * (wanted - covered) / wanted
		if problem[svs.name] != "" or shortfall[svs.name] > 0.1:
			ever_failed[svs.name] = true


func _colliders(svs) -> Array:
	if not is_instance_valid(svs.collision_object):
		return []
	return svs.collision_object.get_children().filter(
			func(c): return c is CollisionPolygon2D and not c.disabled and c.visible)


func _draw() -> void:
	for svs in shapes:
		var broken : bool = problem.get(svs.name, "") != "" or shortfall.get(svs.name, 0.0) > 0.1
		var hue := 0.35
		for collider in _colliders(svs):
			if collider.polygon.size() < 3:
				continue
			for piece in pieces_of.get(collider.get_instance_id(), []):
				hue = fmod(hue + 0.31, 1.0)
				if Geometry2D.triangulate_polygon(piece).is_empty():
					continue  # the editor cannot fill it either: leave the hole visible
				var colour := Color(0.95, 0.2, 0.2, 0.5) if broken \
						else Color.from_hsv(hue, 0.5, 0.95, 0.4)
				draw_colored_polygon(_to_world(svs, piece), colour)
			var outline := _drawable(_to_world(svs, collider.polygon))
			if outline.size() > 2:
				outline.append(outline[0])
				draw_polyline(outline, Color(1, 1, 1, 0.3), 1.0)
		_label(svs, broken)
	if is_instance_valid(dragged_curve):
		for svs in everything:
			if svs.curve != dragged_curve:
				continue
			var handle : Vector2 = svs.to_global(dragged_curve.get_point_position(point_index))
			draw_circle(handle, 6.0, Color(1.0, 0.85, 0.1))
			draw_line(svs.to_global(origin), handle, Color(1.0, 0.85, 0.1, 0.4), 1.0)


func _label(svs, broken : bool) -> void:
	var anchor : Vector2 = svs.global_position + Vector2(0, -12)
	var text := "%s  %s / %s" % [svs.name, EXTRUSION_NAMES[svs.extrusion_direction],
			MODE_NAMES[svs.collision_mode]]
	if broken:
		text += "   BROKEN"
		if problem.get(svs.name, "") != "":
			text += ": " + problem[svs.name]
		elif shortfall.get(svs.name, 0.0) > 0.1:
			text += ": %.0f%% collision missing" % shortfall[svs.name]
	elif ever_failed.get(svs.name, false):
		text += "   (failed earlier)"
	var colour := Color(1.0, 0.35, 0.35) if broken else (
			Color(1.0, 0.8, 0.4) if ever_failed.get(svs.name, false) else Color(0.8, 0.9, 1.0))
	draw_string(font, anchor + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color(0, 0, 0, 0.9))
	draw_string(font, anchor, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, colour)


## Fills a polygon from a triangulation this runner works out itself.
## draw_colored_polygon() triangulates internally and reports `Invalid polygon data`
## when it cannot - the very message this runner exists to look for - so it is never
## called: an alarm raised by the alarm is worse than no alarm at all. The triangles
## are drawn one at a time, which needs no triangulating and so cannot fail.
func _fill(points : PackedVector2Array, colour : Color) -> void:
	var indices := Geometry2D.triangulate_polygon(points)
	var colours := PackedColorArray([colour, colour, colour])
	var index := 0
	while index + 2 < indices.size():
		draw_primitive(PackedVector2Array([
				points[indices[index]], points[indices[index + 1]],
				points[indices[index + 2]]]), colours, PackedVector2Array())
		index += 3


## The polygon in a form worth drawing at all: no repeated points, some surface, and a
## triangulation that exists.
func _drawable(points : PackedVector2Array) -> PackedVector2Array:
	var clean : PackedVector2Array = []
	for i in points.size():
		if clean.is_empty() or not clean[clean.size() - 1].is_equal_approx(points[i]):
			clean.append(points[i])
	while clean.size() > 1 and clean[0].is_equal_approx(clean[clean.size() - 1]):
		clean.resize(clean.size() - 1)
	if clean.size() < 3:
		return PackedVector2Array()
	if absf(Geometry2DUtil.get_polygon_area(clean)) < 0.5:
		return PackedVector2Array()
	if Geometry2D.triangulate_polygon(clean).is_empty():
		return PackedVector2Array()
	return clean


func _to_world(svs, points : PackedVector2Array) -> PackedVector2Array:
	var out : PackedVector2Array = []
	for p in points:
		out.append(svs.collision_object.to_global(p))
	return out


func _status() -> String:
	var broken_now := 0
	var broken_ever := 0
	for svs in shapes:
		if problem.get(svs.name, "") != "" or shortfall.get(svs.name, 0.0) > 0.1:
			broken_now += 1
		if ever_failed.get(svs.name, false):
			broken_ever += 1
	var lines := PackedStringArray()
	lines.append("dragging the shared %s - point %d of %d, offset %s%s" % [
			"clip path" if dragging_clip else "shape outline",
			point_index, dragged_curve.point_count if is_instance_valid(dragged_curve) else 0,
			offset.round(), "   [paused]" if paused else ""])
	lines.append("%d of %d shapes broken right now, %d have broken at some point" % [
			broken_now, shapes.size(), broken_ever])
	lines.append("%d fps | frame %.1f ms (worst %.1f)" % [
			Engine.get_frames_per_second(), frame_ms_average, frame_ms_worst])
	lines.append("   of which: %.1f ms recomputing %d shapes, %.1f ms in this runner's own checks" % [
			plugin_ms, everything.size(), inspect_ms])
	lines.append("space pauses | TAB drags the clip instead | R clears history and timings | ESC quits")
	return "\n".join(lines)


func _unhandled_key_input(event : InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			paused = not paused
		KEY_TAB:
			_switch_to(not dragging_clip)
		KEY_R:
			for svs in shapes:
				ever_failed[svs.name] = false
			frame_ms_worst = 0.0
			frame_ms_average = 0.0
		KEY_ESCAPE:
			get_tree().quit()
