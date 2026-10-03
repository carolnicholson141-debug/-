extends Node2D
## 地图宝箱：靠近后按 E 开启，奖励升级卡或消耗品。

var opened := false
var pulse := 0.0
var _sprite: Sprite2D

func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = load("res://assets/ui/chest.png")
	_sprite.scale = Vector2(0.42, 0.42)
	_sprite.position = Vector2(0, -22)
	add_child(_sprite)

func setup(p: Vector2) -> void:
	position = p
	queue_redraw()

func tick(delta: float, player_pos: Vector2) -> bool:
	pulse += delta
	queue_redraw()
	if opened:
		return false
	var close_enough := position.distance_squared_to(player_pos) <= 120.0 * 120.0
	var interact := Input.is_key_pressed(KEY_E) or Input.is_action_pressed("ui_accept")
	return close_enough and interact

func open() -> void:
	if opened:
		return
	opened = true
	queue_redraw()

func _draw() -> void:
	var glow := 0.55 + sin(pulse * 4.0) * 0.15
	if _sprite != null and _sprite.texture != null:
		draw_circle(Vector2(0, -20), 34.0, Color(1.0, 0.72, 0.18, glow * 0.12))
		if opened:
			_sprite.modulate = Color(0.55, 0.62, 0.68, 1.0)
		return
	if opened:
		draw_circle(Vector2(0, -4), 24.0, Color(0.25, 0.9, 0.72, 0.12))
		draw_rect(Rect2(-18, -8, 36, 22), Color("#53606b"), true)
		draw_line(Vector2(-18, -8), Vector2(18, -8), Color("#9aa7ae"), 3.0)
		return
	draw_circle(Vector2.ZERO, 27.0, Color(1.0, 0.78, 0.22, glow * 0.16))
	draw_rect(Rect2(-19, -10, 38, 24), Color("#8d4d2d"), true)
	draw_rect(Rect2(-19, -10, 38, 8), Color("#c67a39"), true)
	draw_line(Vector2(-19, 2), Vector2(19, 2), Color("#e0a44e"), 3.0)
	draw_rect(Rect2(-3, -1, 6, 8), Color("#ffe27b"), true)
	draw_arc(Vector2.ZERO, 25.0, 0.0, TAU, 24, Color(1.0, 0.82, 0.25, glow), 1.5, true)
	draw_string(ThemeDB.fallback_font, Vector2(-7, -31), "E", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#ffe18a"))
