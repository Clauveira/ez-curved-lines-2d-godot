extends SceneTree

# Drags every point of a shape through a spiral and checks, at every step, what the
# editor would make of the result.
#
# The failures this catches are positional: they appear at one offset and are gone a
# pixel later, so a handful of directions misses them. A spiral sweeps a whole
# neighbourhood in one pass and keeps crossing the shape's own edges on the way out,
# which is where the awkward topology lives - a cutout swallowing an edge, an outline
# folding through itself, a stroke pinching shut.
#
# Two independent things are watched, because a fix for one can quietly break the other:
#
#  1. Can the editor draw it? A CollisionPolygon2D is drawn by convex-decomposing it and
#     filling each piece, so the contour is only safe if the decomposition succeeds AND
#     every piece triangulates. A degenerate piece of a successful decomposition is the
#     one that hurts: it reports `Invalid polygon data, triangulation failed.` on every
#     redraw, with no failing decomposition anywhere in sight.
#  2. Is the collision still there? A gate that drops a contour it cannot make sense of
#     leaves the shape with less collision than it asked for, or none at all, and
#     nothing about the drawing notices.

const REVOLUTIONS := 3.0
const STEPS := 72
const MAX_RADIUS := 70.0

var failures := 0


func check(label : String, condition : bool, detail := "") -> void:
	if condition:
		print("  ok   - ", label, ("  (%s)" % detail) if detail else "")
	else:
		failures += 1
		print("  FAIL - ", label, ("  (%s)" % detail) if detail else "")


func spiral_offset(step : int) -> Vector2:
	var t := float(step) / float(STEPS)
	return Vector2(MAX_RADIUS * t, 0).rotated(TAU * REVOLUTIONS * t)


func make_shape(radius : float, with_fill : bool, with_stroke : bool, with_body : bool) -> ScalableVectorShape2D:
	var svs := ScalableVectorShape2D.new()
	svs.stroke_width = 20.0
	root.add_child(svs)
	# the dimensions signal that turns shape_type into curve points is only connected
	# once the node is in the tree, so the ellipse is described after adding it
	svs.shape_type = ScalableVectorShape2D.ShapeType.ELLIPSE
	svs.size = Vector2(radius, radius) * 2.0
	if with_fill:
		svs.polygon = Polygon2D.new()
		svs.add_child(svs.polygon)
	if with_stroke:
		svs.line = Line2D.new()
		svs.add_child(svs.line)
	if with_body:
		svs.collision_object = StaticBody2D.new()
		svs.add_child(svs.collision_object)
	return svs


# Everything under [param node] the editor would fail to draw.
func undrawable(node : Node) -> PackedStringArray:
	var problems := PackedStringArray()
	for collider in node.find_children("*", "CollisionPolygon2D", true, false):
		if collider.polygon.size() < 3:
			continue
		var pieces := Geometry2D.decompose_polygon_in_convex(collider.polygon)
		if pieces.is_empty():
			problems.append("%s of %d pts cannot be decomposed" % [
					collider.name, collider.polygon.size()])
			continue
		for i in pieces.size():
			if Geometry2D.triangulate_polygon(pieces[i]).is_empty():
				problems.append("%s piece %d of %d has no surface to fill" % [
						collider.name, i, pieces.size()])
				break
	for polygon in node.find_children("*", "Polygon2D", true, false):
		var points : PackedVector2Array = polygon.polygon
		if points.size() < 3:
			continue
		if polygon.polygons.is_empty():
			if Geometry2D.triangulate_polygon(points).is_empty():
				problems.append("%s of %d pts cannot be triangulated" % [
						polygon.name, points.size()])
			continue
		for ranges in polygon.polygons:
			var sub : PackedVector2Array = []
			for index in ranges:
				if index < points.size():
					sub.append(points[index])
			if sub.size() > 2 and Geometry2D.triangulate_polygon(sub).is_empty():
				problems.append("%s sub-polygon of %d pts cannot be triangulated" % [
						polygon.name, sub.size()])
				break
	return problems


# The surface the colliders cover, against the surface the shape asked for before any of
# the gates deciding which contours are worth a node had a say.
func collision_shortfall(svs : ScalableVectorShape2D) -> float:
	if not is_instance_valid(svs.collision_object):
		return 0.0
	var covered := 0.0
	for collider in svs.collision_object.get_children():
		if collider is CollisionPolygon2D and not collider.disabled and collider.visible:
			covered += Geometry2DUtil.get_polygon_area(collider.polygon)
	var fill : Array[PackedVector2Array] = []
	if svs.clip_paths.is_empty():
		fill = [svs.cached_outline] as Array[PackedVector2Array]
	else:
		fill = svs.cached_clipped_polygons
	var wanted := 0.0
	for contour in svs._get_collision_polygons(fill):
		wanted += Geometry2DUtil.get_polygon_area(contour)
	if wanted <= 1.0:
		return 0.0
	return 100.0 * (wanted - covered) / wanted


func spiral_through(label : String, svs : ScalableVectorShape2D, watched : Node) -> void:
	print("\n[%s]" % label)
	var worst_shortfall := 0.0
	var worst_where := ""
	var drawing_problem := ""
	var problem_where := ""
	var steps := 0
	for point_index in svs.curve.point_count:
		var original : Vector2 = svs.curve.get_point_position(point_index)
		for step in STEPS + 1:
			var offset := spiral_offset(step)
			svs.curve.set_point_position(point_index, original + offset)
			svs._update_curve()
			steps += 1
			if drawing_problem.is_empty():
				var problems := undrawable(watched)
				if not problems.is_empty():
					drawing_problem = problems[0]
					problem_where = "point %d at %s" % [point_index, offset]
			var shortfall := collision_shortfall(svs)
			if shortfall > worst_shortfall:
				worst_shortfall = shortfall
				worst_where = "point %d at %s" % [point_index, offset]
		svs.curve.set_point_position(point_index, original)
		svs._update_curve()
	check("the spiral actually moved something", steps > 0,
			"%d curve points, %d steps" % [svs.curve.point_count, steps])
	check("%d steps leave nothing the editor cannot draw" % steps,
			drawing_problem.is_empty(),
			"%s: %s" % [problem_where, drawing_problem] if drawing_problem else "")
	check("no collision is lost on the way",
			worst_shortfall < 0.1,
			"worst %.2f%% missing at %s" % [worst_shortfall, worst_where] if worst_shortfall > 0.0 else "")


func run_case(label : String, with_cutout : bool, extrusion : int, mode : int) -> void:
	var svs := make_shape(100.0, true, true, true)
	svs.extrusion_direction = extrusion
	svs.collision_mode = mode
	var host : Node = svs
	if with_cutout:
		var cutout := make_shape(45.0, false, false, false)
		cutout.position = Vector2(30, 0)
		svs.clip_paths = [cutout] as Array[ScalableVectorShape2D]
	svs._update_curve()
	spiral_through(label, svs, host)
	svs.free()


# The work happens on the first frame rather than in _initialize: a node added to the
# tree before it is running never gets _enter_tree, and ScalableVectorShape2D connects
# the signal that turns shape_type into curve points there - so the shapes would come
# out empty and every check would pass on nothing.
func _process(_delta : float) -> bool:
	var extrusions := {
		ScalableVectorShape2D.StrokeExtrusionDirection.MIDDLE: "MIDDLE",
		ScalableVectorShape2D.StrokeExtrusionDirection.OUTWARD: "OUTWARD",
		ScalableVectorShape2D.StrokeExtrusionDirection.INWARD: "INWARD",
	}
	var modes := {
		ScalableVectorShape2D.CollisionMode.MERGED: "MERGED",
		ScalableVectorShape2D.CollisionMode.FILL_ONLY: "FILL_ONLY",
		ScalableVectorShape2D.CollisionMode.STROKE_ONLY: "STROKE_ONLY",
	}
	for extrusion in extrusions:
		for mode in modes:
			run_case("%s / %s, cutout dragged through the outline" % [
					extrusions[extrusion], modes[mode]], true, extrusion, mode)
	run_case("MIDDLE / MERGED, no cutout", false,
			ScalableVectorShape2D.StrokeExtrusionDirection.MIDDLE,
			ScalableVectorShape2D.CollisionMode.MERGED)
	print("")
	print("FAILURES: ", failures)
	quit(1 if failures > 0 else 0)
	return true
