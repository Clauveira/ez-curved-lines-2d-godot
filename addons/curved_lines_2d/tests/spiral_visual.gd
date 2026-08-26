extends Node2D

## Watches the spiral drag happen, instead of only reading that it passed.
##
## The colliders are drawn here the way the editor draws them - convex-decomposed, one
## fill per piece - so a piece the editor could not fill is a piece missing from the
## picture. What the headless test reports as a line of text is a hole you can see.
##
## Run it with:
##   Godot4.4.exe --path . res://addons/curved_lines_2d/tests/spiral_visual.tscn
##
## Space pauses, left/right step through the configurations, R restarts the current one.

const REVOLUTIONS := 3.0
const MAX_RADIUS := 90.0
const SECONDS_PER_POINT := 2.5

const EXTRUSIONS := [
	ScalableVectorShape2D.StrokeExtrusionDirection.MIDDLE,
	ScalableVectorShape2D.StrokeExtrusionDirection.OUTWARD,
	ScalableVectorShape2D.StrokeExtrusionDirection.INWARD,
]
const EXTRUSION_NAMES := ["MIDDLE", "OUTWARD", "INWARD"]
const MODES := [
	ScalableVectorShape2D.CollisionMode.MERGED,
	ScalableVectorShape2D.CollisionMode.FILL_ONLY,
	ScalableVectorShape2D.CollisionMode.STROKE_ONLY,
]
const MODE_NAMES := ["MERGED", "FILL_ONLY", "STROKE_ONLY"]

var shape : ScalableVectorShape2D
var cutout : ScalableVectorShape2D
var configuration := 0
var point_index := 0
var elapsed := 0.0
var paused := false
var origin := Vector2.ZERO
var offset := Vector2.ZERO

var problems := PackedStringArray()
var shortfall := 0.0
var worst_shortfall := 0.0
var undrawable_seen := 0
var collision_lost_seen := 0

@onready var readout : Label = $Readout


func _ready() -> void:
	_build(0)


func _build(which : int) -> void:
	if is_instance_valid(shape):
		shape.queue_free()
	if is_instance_valid(cutout):
		cutout.queue_free()
	configuration = posmod(which, EXTRUSIONS.size() * MODES.size())
	shape = _make_shape(150.0, true)
	shape.position = Vector2(640, 400)
	shape.extrusion_direction = EXTRUSIONS[configuration / MODES.size()]
	shape.collision_mode = MODES[configuration % MODES.size()]
	cutout = _make_shape(70.0, false)
	cutout.position = Vector2(700, 400)
	shape.clip_paths = [cutout] as Array[ScalableVectorShape2D]
	shape._update_curve()
	point_index = 0
	elapsed = 0.0
	worst_shortfall = 0.0
	undrawable_seen = 0
	collision_lost_seen = 0
	origin = shape.curve.get_point_position(0)


func _make_shape(radius : float, with_nodes : bool) -> ScalableVectorShape2D:
	var svs := ScalableVectorShape2D.new()
	svs.stroke_width = 24.0
	add_child(svs)
	# in the tree first: the signal turning shape_type into curve points is connected
	# on entering it, so a shape described before that comes out with no points at all
	svs.shape_type = ScalableVectorShape2D.ShapeType.ELLIPSE
	svs.size = Vector2(radius, radius) * 2.0
	if with_nodes:
		svs.polygon = Polygon2D.new()
		svs.polygon.color = Color(0.25, 0.5, 0.85, 0.5)
		svs.add_child(svs.polygon)
		svs.line = Line2D.new()
		svs.line.default_color = Color(0.9, 0.9, 1.0, 0.6)
		svs.add_child(svs.line)
		svs.collision_object = StaticBody2D.new()
		svs.add_child(svs.collision_object)
	return svs


func _process(delta : float) -> void:
	if not paused:
		elapsed += delta
		if elapsed >= SECONDS_PER_POINT:
			elapsed = 0.0
			shape.curve.set_point_position(point_index, origin)
			point_index = (point_index + 1) % shape.curve.point_count
			origin = shape.curve.get_point_position(point_index)
		var t := elapsed / SECONDS_PER_POINT
		offset = Vector2(MAX_RADIUS * t, 0).rotated(TAU * REVOLUTIONS * t)
		shape.curve.set_point_position(point_index, origin + offset)
		shape._update_curve()
	_inspect()
	queue_redraw()
	readout.text = _status()


func _inspect() -> void:
	problems = PackedStringArray()
	for collider in _colliders():
		if collider.polygon.size() < 3:
			continue
		var pieces := Geometry2D.decompose_polygon_in_convex(collider.polygon)
		if pieces.is_empty():
			problems.append("%s cannot be decomposed" % collider.name)
			continue
		for i in pieces.size():
			if Geometry2D.triangulate_polygon(pieces[i]).is_empty():
				problems.append("%s piece %d of %d cannot be filled" % [
						collider.name, i, pieces.size()])
				break
	if not problems.is_empty():
		undrawable_seen += 1
	var covered := 0.0
	for collider in _colliders():
		covered += Geometry2DUtil.get_polygon_area(collider.polygon)
	var fill : Array[PackedVector2Array] = []
	if shape.clip_paths.is_empty():
		fill = [shape.cached_outline] as Array[PackedVector2Array]
	else:
		fill = shape.cached_clipped_polygons
	var wanted := 0.0
	for contour in shape._get_collision_polygons(fill):
		wanted += Geometry2DUtil.get_polygon_area(contour)
	shortfall = 0.0 if wanted <= 1.0 else 100.0 * (wanted - covered) / wanted
	if shortfall > 0.1:
		collision_lost_seen += 1
	worst_shortfall = maxf(worst_shortfall, shortfall)


func _colliders() -> Array:
	if not is_instance_valid(shape) or not is_instance_valid(shape.collision_object):
		return []
	return shape.collision_object.get_children().filter(
			func(c): return c is CollisionPolygon2D and not c.disabled and c.visible)


func _draw() -> void:
	# the editor's own way of drawing a collider: decompose, then fill every piece. A
	# piece it cannot fill simply does not appear, which is the defect made visible.
	var hue := 0.35
	for collider in _colliders():
		if collider.polygon.size() < 3:
			continue
		for piece in Geometry2D.decompose_polygon_in_convex(collider.polygon):
			hue = fmod(hue + 0.31, 1.0)
			if Geometry2D.triangulate_polygon(piece).is_empty():
				continue
			draw_colored_polygon(_to_world(piece),
					Color.from_hsv(hue, 0.55, 0.95, 0.45))
		var outline := _to_world(collider.polygon)
		outline.append(outline[0])
		draw_polyline(outline, Color(1, 1, 1, 0.35), 1.0)
	if is_instance_valid(shape) and is_instance_valid(shape.curve):
		var handle := shape.to_global(shape.curve.get_point_position(point_index))
		draw_circle(handle, 7.0, Color(1.0, 0.85, 0.1))
		draw_circle(shape.to_global(origin), 4.0, Color(1.0, 0.85, 0.1, 0.45))
		draw_line(shape.to_global(origin), handle, Color(1.0, 0.85, 0.1, 0.35), 1.0)


func _to_world(points : PackedVector2Array) -> PackedVector2Array:
	var out : PackedVector2Array = []
	for p in points:
		out.append(shape.collision_object.to_global(p))
	return out


func _status() -> String:
	var lines := PackedStringArray()
	lines.append("%s / %s   (%d of %d)" % [
			EXTRUSION_NAMES[configuration / MODES.size()],
			MODE_NAMES[configuration % MODES.size()],
			configuration + 1, EXTRUSIONS.size() * MODES.size()])
	lines.append("point %d of %d, offset %s%s" % [
			point_index, shape.curve.point_count, offset.round(),
			"   [paused]" if paused else ""])
	lines.append("%d colliders, %.1f%% of the collision surface missing" % [
			_colliders().size(), shortfall])
	if problems.is_empty():
		lines.append("drawable")
	else:
		lines.append("NOT DRAWABLE: " + ", ".join(problems))
	lines.append("worst so far: %.1f%% missing | %d undrawable frames | %d lossy frames" % [
			worst_shortfall, undrawable_seen, collision_lost_seen])
	lines.append("space pauses, left/right change configuration, R restarts")
	return "\n".join(lines)


func _unhandled_key_input(event : InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			paused = not paused
		KEY_RIGHT:
			_build(configuration + 1)
		KEY_LEFT:
			_build(configuration - 1)
		KEY_R:
			_build(configuration)
		KEY_ESCAPE:
			get_tree().quit()
