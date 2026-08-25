extends SceneTree

# Runs the spiral drag over a scene whose shapes all share one curve, so a single drag
# exercises every configuration at once and says which of them broke.
#
# topology_bug2.tscn is built for this: nine ScalableVectorShape2D covering all nine
# combinations of extrusion_direction and collision_mode, every one of them pointing at
# the same Curve2D, each with its own clip path pointing at a second shared Curve2D.
# Moving one point moves all nine shapes, so the whole matrix is swept in one pass and
# a failure comes back labelled with the combination that produced it - which is the
# thing that took longest to work out by hand.
#
# The scene is a fixture rather than a unit: if it is not in the project the suite says
# so and passes, rather than failing for a reason that has nothing to do with the code.

const SCENE_PATH := "res://collision_matrix.tscn"
const REVOLUTIONS := 3.0
const STEPS := 192
const MAX_RADIUS := 80.0

const EXTRUSION_NAMES := ["MIDDLE", "OUTWARD", "INWARD"]
const MODE_NAMES := ["MERGED", "FILL_ONLY", "STROKE_ONLY"]

var failures := 0


func check(label : String, condition : bool, detail := "") -> void:
	if condition:
		print("  ok   - ", label, ("  (%s)" % detail) if detail else "")
	else:
		failures += 1
		print("  FAIL - ", label, ("  (%s)" % detail) if detail else "")


func configuration_of(svs) -> String:
	return "%s / %s" % [EXTRUSION_NAMES[svs.extrusion_direction],
			MODE_NAMES[svs.collision_mode]]


# What would fail to draw in this one shape, if anything - collider or fill.
#
# The fill matters as much as the collider and fails independently: a Polygon2D renders
# in a running game, not just in the editor, so an outline the triangulator refuses is a
# hole in the shape wherever it is used.
func undrawable(svs) -> String:
	if is_instance_valid(svs.polygon):
		var points : PackedVector2Array = svs.polygon.polygon
		if points.size() > 2:
			if svs.polygon.polygons.is_empty():
				if Geometry2D.triangulate_polygon(points).is_empty():
					return "fill of %d pts cannot be triangulated" % points.size()
			else:
				for ranges in svs.polygon.polygons:
					var sub : PackedVector2Array = []
					for index in ranges:
						if index < points.size():
							sub.append(points[index])
					if sub.size() > 2 and Geometry2D.triangulate_polygon(sub).is_empty():
						return "fill piece of %d pts cannot be triangulated" % sub.size()
	if not is_instance_valid(svs.collision_object):
		return ""
	for collider in svs.collision_object.get_children():
		if not (collider is CollisionPolygon2D) or collider.disabled or not collider.visible:
			continue
		if collider.polygon.size() < 3:
			continue
		var pieces := Geometry2D.decompose_polygon_in_convex(collider.polygon)
		if pieces.is_empty():
			return "%s of %d pts cannot be decomposed" % [
					collider.name, collider.polygon.size()]
		for i in pieces.size():
			if Geometry2D.triangulate_polygon(pieces[i]).is_empty():
				return "%s piece %d of %d cannot be filled" % [
						collider.name, i, pieces.size()]
	return ""


# How much of the collision surface this shape asked for never reached a node.
func shortfall(svs) -> float:
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


func spiral_offset(step : int) -> Vector2:
	var t := float(step) / float(STEPS)
	return Vector2(MAX_RADIUS * t, 0).rotated(TAU * REVOLUTIONS * t)


# Drags every point of [param curve] through a spiral, reporting per shape.
func sweep(label : String, curve : Curve2D, shapes : Array, roots : Array) -> void:
	print("\n[%s]" % label)
	var worst_loss := {}
	var worst_where := {}
	var first_undrawable := {}
	var steps := 0
	for point_index in curve.point_count:
		var original := curve.get_point_position(point_index)
		for step in STEPS + 1:
			var offset := spiral_offset(step)
			curve.set_point_position(point_index, original + offset)
			for svs in roots:
				svs._update_curve()
			steps += 1
			for svs in shapes:
				var where := "point %d at %s" % [point_index, offset.round()]
				var problem := undrawable(svs)
				if problem != "" and not first_undrawable.has(svs.name):
					first_undrawable[svs.name] = "%s - %s" % [where, problem]
				var missing := shortfall(svs)
				if missing > worst_loss.get(svs.name, 0.0):
					worst_loss[svs.name] = missing
					worst_where[svs.name] = where
		curve.set_point_position(point_index, original)
		for svs in roots:
			svs._update_curve()
	check("the spiral moved something", steps > 0,
			"%d points, %d steps, %d shapes watched" % [
					curve.point_count, steps, shapes.size()])
	for svs in shapes:
		var name := "%-7s %s" % [svs.name, configuration_of(svs)]
		check("%s stays drawable" % name,
				not first_undrawable.has(svs.name),
				first_undrawable.get(svs.name, ""))
		var missing : float = worst_loss.get(svs.name, 0.0)
		check("%s keeps its collision" % name, missing < 0.1,
				"worst %.2f%% missing at %s" % [missing, worst_where.get(svs.name, "")] \
						if missing > 0.0 else "")


func _process(_delta : float) -> bool:
	if not ResourceLoader.exists(SCENE_PATH):
		print("\n[skipped] %s is not in this project" % SCENE_PATH)
		print("  This suite drives a fixture scene of nine shapes sharing one curve.")
		print("  Without it there is nothing to sweep - test_spiral_drag.gd covers the")
		print("  same ground on shapes it builds itself.")
		print("")
		print("FAILURES: ", failures)
		quit(0)
		return true
	var instance := (load(SCENE_PATH) as PackedScene).instantiate()
	root.add_child(instance)
	var everything := instance.find_children("*", "ScalableVectorShape2D", true, false)
	for svs in everything:
		svs._update_curve()
	# the shapes that own a collision body are the ones under test; the rest are the
	# clip paths they cut themselves with
	var shapes := everything.filter(func(s): return is_instance_valid(s.collision_object))
	var clips := everything.filter(func(s): return not is_instance_valid(s.collision_object))
	check("the fixture holds every configuration", shapes.size() == 9,
			"%d shapes with a collision body" % shapes.size())
	if not shapes.is_empty():
		sweep("dragging the shared shape outline", shapes[0].curve, shapes, everything)
	if not clips.is_empty():
		sweep("dragging the shared clip path", clips[0].curve, shapes, everything)
	print("")
	print("FAILURES: ", failures)
	quit(1 if failures > 0 else 0)
	return true
