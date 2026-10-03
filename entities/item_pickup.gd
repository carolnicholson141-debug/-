extends Node2D
## 地图消耗品：靠近后自动拾取。

var item_id := ""
var item_name := ""
var tint := Color.WHITE
var phase := 0.0
var collected := false

func setup(p: Vector2, id: String, label: String, color: Color) -> void:
	position = p
	item_id = id
	item_name = label
	tint = color
	queue_redraw()

func tick(delta: float, player_pos: Vector2) -> bool:
	# ⚠ 这里**只推进 phase，绝不改写 position**。
	# 原来写的是 `position.y += sin(phase * 3.0) * 0.08` ——
	# 把正弦直接累加进真实坐标，有两个问题：
	#   1. 数学上等于对sin 做累加积分，结果是**持续漂移**而非原地浮动 ——
	#      道具会一点点飘离掉落点，越飘越远（拾取判定也跟着偏）；
	#   2. phase 无限增长，长时间后 float 精度丢失，漂浮变得不规则。
	# 上下浮动本来就该是**纯视觉**效果，而 _draw() 里已经有
	# bob = sin(phase*3)*2.0 在画它了 —— 同一个正弦不需要用两遍。
	phase += delta
	if position.distance_squared_to(player_pos) <= 34.0 * 34.0:
		collected = true
		return true
	queue_redraw()
	return false

func _draw() -> void:
	# 浮动只在这里生效：画的时候偏移，不动节点真实坐标。
	var bob := sin(phase * 3.0) * 2.0
	draw_circle(Vector2(0, bob), 15.0, Color(tint.r, tint.g, tint.b, 0.16))
	draw_circle(Vector2(0, bob), 9.0, tint)
	draw_arc(Vector2(0, bob), 12.0, 0.0, TAU, 20, Color.WHITE, 1.5, true)
	var glyph := "G" if item_id == "grenade" else "+"
	draw_string(ThemeDB.fallback_font, Vector2(-4, 5 + bob), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#17202b"))
