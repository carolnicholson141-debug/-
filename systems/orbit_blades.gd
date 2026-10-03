extends Node2D
## 环绕飞刃：持久碰撞体，不创建每帧临时节点。

var player: Node2D
var grid: SpatialHash
var _angle := 0.0
var _hit_cd: Dictionary = {}
var _expired_hit_ids: Array = []

## 飞刃命中查询的复用缓冲。终身一个，不每帧新建（理由同 projectile._query_buf）。
var _query_buf: Array = []

func reset() -> void:
	_angle = 0.0
	_hit_cd.clear()
	_expired_hit_ids.clear()
	_query_buf.clear()
	queue_redraw()

func tick(delta: float) -> void:
	if player == null or grid == null or not player.alive:
		return
	var count := int(player.stats.get("orbit_count", 0))
	if count <= 0:
		return
	_angle = fmod(_angle + float(player.stats.get("orbit_speed", 2.8)) * delta, TAU)
	_expired_hit_ids.clear()
	for key in _hit_cd:
		_hit_cd[key] = float(_hit_cd[key]) - delta
		if float(_hit_cd[key]) <= 0.0:
			_expired_hit_ids.append(key)
	for key in _expired_hit_ids:
		_hit_cd.erase(key)
	var radius := float(player.stats.get("orbit_radius", 54.0))
	var damage := float(player.stats.get("orbit_damage", 18.0))
	for i in count:
		var blade_pos := player.position + Vector2.RIGHT.rotated(_angle + TAU * float(i) / float(count)) * radius
		grid.query_radius_exact_into(blade_pos, 18.0, _query_buf)
		for enemy in _query_buf:
			var z := enemy as Zombie
			if z == null or not z.solid:
				continue
			var id := z.get_instance_id()
			if _hit_cd.has(id):
				continue
			_hit_cd[id] = 0.28
			z.take_damage(damage)
			Events.blade_hit.emit(blade_pos)
			break
	queue_redraw()

func _draw() -> void:
	var count := int(player.stats.get("orbit_count", 0)) if player != null else 0
	if count <= 0 or player == null:
		return
	var radius := float(player.stats.get("orbit_radius", 54.0))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(1.0, 0.78, 0.25, 0.16), 1.5, true)
	for i in count:
		var p := Vector2.RIGHT.rotated(_angle + TAU * float(i) / float(count)) * radius
		var tangent := p.normalized().orthogonal()
		draw_colored_polygon(PackedVector2Array([p - tangent * 9.0, p + tangent * 9.0, p + p.normalized() * 7.0]), Color("#ffe18a"))
		draw_circle(p, 4.0, Color("#fff6c2"))
