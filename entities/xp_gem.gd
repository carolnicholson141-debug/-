extends Node2D
## 经验球。
##
## 两种被吸引方式：玩家靠近到 attract_radius 内就开始飞向玩家，
## 所以实际「捡」的动作是自动的 —— 割草游戏里玩家没空低头捡东西。
##
## 由 Main 统一驱动 tick()。

var value: float = 1.0
var alive: bool = false
var recycle_ready: bool = false

var _size: float = 4.0
var _attracted: bool = false
var _speed: float = 0.0
var _bob: float = 0.0
var _spawn_scale: float = 0.0   # 出生弹出动画，0→1
var _trail_dir: Vector2 = Vector2.ZERO

# 远离玩家的经验球仍要参与吸附判定，但不必持续更新浮动动画。
# 视野外通常有大量掉落物，这个 LOD 能减少无效 queue_redraw。
const VISUAL_RANGE_SQ := 1000.0 * 1000.0
var _visual_active := true


func spawn(spawn_pos: Vector2, p_value: float) -> void:
	position = spawn_pos
	value = p_value
	alive = true
	recycle_ready = false
	_attracted = false
	_speed = 0.0
	_bob = randf() * TAU
	_spawn_scale = 0.0
	_trail_dir = Vector2.ZERO
	_visual_active = true
	# 值越大球越大，让玩家一眼看出哪颗值得绕路去捡
	_size = 3.0 + minf(p_value, 8.0) * 0.55
	visible = true
	z_index = -2   # 贴地，压在尸体和活丧尸下面
	queue_redraw()


## ---------------------------------------------------------------- 每帧更新

func tick(delta: float, player_pos: Vector2, attract_radius: float, pickup_radius: float) -> void:
	if not alive:
		return

	var visual_active := _attracted or position.distance_squared_to(player_pos) <= VISUAL_RANGE_SQ
	if visual_active:
		_bob += delta * 4.0
	if _spawn_scale < 1.0:
		_spawn_scale = minf(1.0, _spawn_scale + delta * 6.0)

	# 距离玩家太远就完全不算 —— 先用一次廉价的平方距离做早退，
	# 避免每颗经验球每帧都做 sqrt。
	var diff := player_pos - position
	var d2 := diff.length_squared()

	if not _attracted and d2 <= attract_radius * attract_radius:
		_attracted = true
		_speed = 240.0

	if _attracted:
		# 越接近越快，造成「嗖」一下被吸走的手感
		_speed = minf(_speed + 1400.0 * delta, 1500.0)
		_trail_dir = diff.normalized()
		position += _trail_dir * _speed * delta

		# 用移动**之后**的位置重算距离。复用上面那个 d2 会晚一帧才判定拾取，
		# 而满速 1500px/s 时一帧要走 25px —— 球会从玩家身上穿过去再折返，
		# 看起来就是"贴着脚边滑过去了却没捡到"。
		if position.distance_squared_to(player_pos) <= pickup_radius * pickup_radius:
			alive = false
			recycle_ready = true

	# 只在画面相关状态变化时重绘：远处静止的球不需要每帧提交自绘命令。
	if visual_active:
		_visual_active = true
		queue_redraw()
	elif _visual_active:
		_visual_active = false
		queue_redraw()
	else:
		_visual_active = false


## 是否已经进入吸附状态。Main 用它挑"还没被吸走"的球来清理堆积 ——
## 挑已经在飞的白费力气：那颗球正在飞，再下一遍命令它也不会更快。
func is_attracted() -> bool:
	return _attracted


## 强制开始吸附，无视距离。
## 由 Main 在场上经验球超过上限时调用，用来清理堆积。
func force_attract() -> void:
	if not alive:
		return
	_attracted = true
	_speed = maxf(_speed, 400.0)


## ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var s := _size * _spawn_scale
	if s <= 0.01:
		return

	var bob_y := sin(_bob) * 1.4
	if _attracted and _trail_dir.length_squared() > 0.01:
		var trail_col := Color(0.55, 0.95, 0.72, 0.28)
		var trail_len := clampf(_speed * 0.018, 4.0, 22.0)
		draw_line(-_trail_dir * trail_len, Vector2.ZERO, trail_col, maxf(1.0, s * 0.7), true)
		draw_arc(Vector2.ZERO, s * 1.8, 0.0, TAU, 16, Color(0.55, 1.0, 0.72, 0.22), 1.5, true)

	# 地面阴影
	draw_set_transform(Vector2(0.0, s * 0.5), 0.0, Vector2(1.0, 0.4))
	draw_circle(Vector2.ZERO, s * 0.9, Color(0.0, 0.0, 0.0, 0.22))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 菱形本体
	var pts := PackedVector2Array([
		Vector2(0.0, -s + bob_y),
		Vector2(s * 0.72, 0.0 + bob_y),
		Vector2(0.0, s + bob_y),
		Vector2(-s * 0.72, 0.0 + bob_y),
	])
	var col := Color("#4fd07a") if value < 3.0 else Color("#ffd34d")
	draw_colored_polygon(pts, col)

	# 描边：把菱形的边线再画一遍，让小球在深色地面上不糊
	var outline := PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]])
	draw_polyline(outline, Color(0.05, 0.25, 0.12, 0.85), 1.4, true)
