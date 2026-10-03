extends Node2D
## 手榴弹：先沿抛物线飞行，落点再爆炸。

var start_pos := Vector2.ZERO
var target_pos := Vector2.ZERO
var elapsed := 0.0
var flight_time := 0.42
var exploded := false
var explosion_time := 0.0
var on_detonate: Callable = Callable()

func setup(origin: Vector2, target: Vector2, callback: Callable) -> void:
	start_pos = origin
	target_pos = target
	position = origin
	on_detonate = callback
	queue_redraw()

func tick(delta: float) -> bool:
	if not exploded:
		elapsed += delta
		var t := clampf(elapsed / flight_time, 0.0, 1.0)
		position = start_pos.lerp(target_pos, t)
		position.y -= sin(t * PI) * 92.0
		rotation += delta * 9.0
		queue_redraw()
		if t >= 1.0:
			exploded = true
			explosion_time = 0.0
			if on_detonate.is_valid():
				on_detonate.call(target_pos)
			queue_redraw()
		return false

	explosion_time += delta
	queue_redraw()
	return explosion_time >= 0.52

func _draw() -> void:
	if not exploded:
		# 阴影与飞行中的手榴弹
		_draw_grenade_ellipse(Vector2(0, 9), 8.0, 3.0, Color(0, 0, 0, 0.28))
		draw_circle(Vector2.ZERO, 6.0, Color("#4d6b35"))
		draw_circle(Vector2(-2, -2), 3.0, Color("#8aa84b"))
		draw_line(Vector2(3, -5), Vector2(6, -9), Color("#d6c08a"), 2.0)
		return

	var t := clampf(explosion_time / 0.52, 0.0, 1.0)
	var radius := 18.0 + t * 88.0
	var alpha := 1.0 - t
	# 冲击波
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, Color(1.0, 0.72, 0.18, alpha * 0.85), 4.0, true)
	draw_arc(Vector2.ZERO, radius * 0.68, 0.0, TAU, 24, Color(1.0, 0.95, 0.45, alpha * 0.7), 3.0, true)
	# 放射状火焰
	for i in 12:
		var angle := TAU * float(i) / 12.0
		var length := radius * (0.65 + 0.2 * sin(float(i) * 2.1))
		var dir := Vector2.RIGHT.rotated(angle)
		draw_line(dir * 8.0, dir * length, Color(1.0, 0.38, 0.06, alpha), 6.0, true)
		draw_line(dir * 7.0, dir * (length * 0.72), Color(1.0, 0.92, 0.3, alpha), 3.0, true)
	draw_circle(Vector2.ZERO, 24.0 * (1.0 - t * 0.35), Color(1.0, 0.86, 0.25, alpha * 0.9))
	draw_circle(Vector2.ZERO, 11.0 * (1.0 - t * 0.25), Color(1.0, 1.0, 0.82, alpha))

func _draw_grenade_ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(1.0, ry / maxf(rx, 0.01)))
	draw_circle(Vector2.ZERO, rx, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
