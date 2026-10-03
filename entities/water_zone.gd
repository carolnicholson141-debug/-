extends Node2D
## 水域：街面积水洼，溺亡者的巢。
##
## 职责三件事：
##   1. 视觉 —— 深色水面 + 持续外扩的涟漪（queue_redraw 驱动，只有 4 片，开销可忽略）；
##   2. 判定 —— contains_point() 椭圆内判定，Main 用它给玩家/丧尸套减速（见 _tick_water）；
##   3. 孵化 —— 每隔 WATER_SPAWN_INTERVAL 浮出一只溺亡者：
##      先 WATER_TELEGRAPH 秒涟漪预警（同时广播 water_warning 给 HUD），
##      倒数结束发 emerge 信号，由 Main 走对象池正式刷怪（上限保护都在 Main 侧）。
##
## 本节点由 Main 统一驱动 tick()，不自己开 _process。

## 某只溺亡者该从本水域浮出了。pos = 浮出点（世界坐标）。
signal emerge(pos: Vector2)

var radius := Vector2(160.0, 120.0)

## 涟漪动画相位。自累加而不是读全局时钟（与 zombie._wobble_phase 同一理由）。
var _ripple_t := 0.0
var _spawn_timer := 0.0
var _telegraph_left := 0.0
var _telegraph_pos := Vector2.ZERO


func setup(p: Vector2, p_radius: Vector2) -> void:
	position = p
	radius = p_radius
	# 开局错开各水域的孵化节奏，别让四片水同时"开锅"。
	_spawn_timer = GameData.WATER_SPAWN_INTERVAL * randf_range(0.6, 1.4)
	queue_redraw()


func _ready() -> void:
	# 与经验球同层（贴地）。经验球后生成、树序靠后，会画在水面上 —— 合理。
	z_index = -2


func _exit_tree() -> void:
	# _clear_entities 里统一 queue_free，这里只为防手动删除时悬空引用
	set_meta("gone", true)


## 椭圆内判定（归一化平方距离）。Main 每帧对玩家/每只丧尸调用，必须保持廉价。
func contains_point(p: Vector2) -> bool:
	var dx := (p.x - position.x) / radius.x
	var dy := (p.y - position.y) / radius.y
	return dx * dx + dy * dy <= 1.0


func tick(delta: float, player_alive: bool) -> void:
	_ripple_t = fmod(_ripple_t + delta, 6.0)
	queue_redraw()

	if not player_alive:
		return

	# 浮出倒计时 → 发 emerge
	if _telegraph_left > 0.0:
		_telegraph_left -= delta
		if _telegraph_left <= 0.0:
			emerge.emit(_telegraph_pos)
		return

	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return
	_spawn_timer = GameData.WATER_SPAWN_INTERVAL * randf_range(0.85, 1.25)

	# 水域内随机取一点（半径平方均匀采样，避免都挤在中心）。
	# 只用内圈 80%：浮出点太贴水缘会看起来像"踩在岸上冒出来"。
	var ang := randf() * TAU
	var rr := sqrt(randf()) * 0.8
	_telegraph_pos = position + Vector2(cos(ang) * radius.x * rr, sin(ang) * radius.y * rr)
	_telegraph_left = GameData.WATER_TELEGRAPH
	Events.water_warning.emit(_telegraph_pos)


func _draw() -> void:
	# ---- 水体：两层椭圆，深色打底 + 略浅内芯
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(radius.x, radius.y))
	draw_circle(Vector2.ZERO, 1.0, Color(0.10, 0.16, 0.20, 0.62))
	draw_circle(Vector2.ZERO, 0.82, Color(0.13, 0.21, 0.26, 0.55))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# ---- 涟漪：三圈错相外扩（0~2s / 2~4s / 4~6s 各一圈）
	# 注意不能用"缩放变换 + draw_arc(半径1)"再除回线宽：draw_arc 的 width
	# 是**变换前**的局部单位，会被缩放一起放大 —— 曾经炸出满屏星芒。
	# 这里手工采样椭圆点，用 draw_polyline 保证线宽恒为屏幕像素。
	for i in 3:
		var phase := fmod(_ripple_t + float(i) * 2.0, 6.0) / 6.0
		var rr := 0.25 + phase * 0.75
		var alpha := 0.30 * (1.0 - phase)
		if alpha <= 0.01:
			continue
		var pts := PackedVector2Array()
		pts.resize(41)
		for k in 41:
			var a := TAU * float(k) / 40.0
			pts[k] = Vector2(cos(a) * radius.x * rr, sin(a) * radius.y * rr)
		draw_polyline(pts, Color(0.55, 0.80, 0.88, alpha), 2.2, true)

	# ---- 浮出预警：倒数期间在出怪点画收缩涟漪圈（越收越快 = 越快浮出）
	if _telegraph_left > 0.0:
		var t := 1.0 - clampf(_telegraph_left / GameData.WATER_TELEGRAPH, 0.0, 1.0)
		var pulse := 0.55 + 0.45 * sin(_telegraph_left * 22.0)
		draw_arc(_telegraph_pos - position, 26.0 * (1.0 - t * 0.7), 0.0, TAU, 24,
			Color(0.45, 0.90, 0.95, 0.35 + 0.45 * pulse * t), 2.5, true)
		draw_arc(_telegraph_pos - position, 34.0, 0.0, TAU, 24,
			Color(0.45, 0.90, 0.95, 0.18 + 0.30 * t), 1.5, true)
