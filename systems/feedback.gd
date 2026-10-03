extends Node2D
## 轻量的世界反馈层：伤害数字、命中闪光、击杀奖励。
## 不创建 Label/GPUParticles 实例，避免割草游戏里频繁击杀造成节点分配尖峰。

var _texts: Array[Dictionary] = []
var _bursts: Array[Dictionary] = []
var _muzzles: Array[Dictionary] = []
var _zaps: Array[Dictionary] = []
var _font: Font

func _ready() -> void:
	_font = ThemeDB.fallback_font
	z_index = 20
	Events.enemy_hurt.connect(_on_enemy_hurt)
	Events.critical_hit.connect(_on_critical_hit)
	Events.enemy_killed.connect(_on_enemy_killed)
	Events.weapon_fired_at.connect(_on_weapon_fired_at)
	Events.chain_zapped.connect(_on_chain_zapped)
	Events.blade_hit.connect(_on_blade_hit)
	Events.run_started.connect(_clear)
	set_process(false)

func _clear() -> void:
	_texts.clear()
	_bursts.clear()
	_muzzles.clear()
	_zaps.clear()
	queue_redraw()
	set_process(false)

func _on_enemy_hurt(pos: Vector2, amount: float) -> void:
	_texts.append({"pos": pos + Vector2(-5.0, -18.0), "text": "-%d" % maxi(1, roundi(amount)), "life": 0.52, "max": 0.52, "color": Color("#fff0c2")})
	_bursts.append({"pos": pos, "life": 0.16, "max": 0.16, "radius": 4.0, "color": Color(1.0, 0.88, 0.58, 0.9)})
	set_process(true)

func _on_critical_hit(pos: Vector2, amount: float) -> void:
	_texts.append({"pos": pos + Vector2(-10.0, -38.0), "text": "暴击  -%d" % maxi(1, roundi(amount)), "life": 0.72, "max": 0.72, "color": Color("#ffd34d")})
	_bursts.append({"pos": pos, "life": 0.24, "max": 0.24, "radius": 8.0, "color": Color(1.0, 0.72, 0.20, 1.0)})
	set_process(true)

func _on_enemy_killed(pos: Vector2, xp: float, elite: bool) -> void:
	var col := Color("#ffd34d") if elite else Color("#8ff0a7")
	_texts.append({"pos": pos + Vector2(-8.0, -28.0), "text": "+%d XP" % maxi(1, roundi(xp)), "life": 0.72, "max": 0.72, "color": col})
	_bursts.append({"pos": pos, "life": 0.28, "max": 0.28, "radius": 8.0 if elite else 5.0, "color": Color(col.r, col.g, col.b, 0.9)})
	set_process(true)

func _on_weapon_fired_at(pos: Vector2, direction: Vector2) -> void:
	_muzzles.append({"pos": pos, "dir": direction, "life": 0.075, "max": 0.075})
	set_process(true)

func _on_chain_zapped(from_pos: Vector2, to_pos: Vector2) -> void:
	_zaps.append({"from": from_pos, "to": to_pos, "life": 0.12, "max": 0.12})
	set_process(true)

func _on_blade_hit(pos: Vector2) -> void:
	_bursts.append({"pos": pos, "life": 0.13, "max": 0.13, "radius": 3.0, "color": Color(1.0, 0.84, 0.32, 0.95)})
	set_process(true)

func _process(delta: float) -> void:
	_advance(_texts, delta)
	_advance(_bursts, delta)
	_advance(_muzzles, delta)
	_advance(_zaps, delta)
	# 漂浮数字单独处理：只有它有额外的运动（向上飘）
	for item in _texts:
		item["pos"] = item["pos"] + Vector2(0.0, -28.0 * delta)
	# 冲击波要扩张
	for item in _bursts:
		item["radius"] = float(item["radius"]) + 42.0 * delta

	# 原地压缩并剔除过期元素。
	#
	# ⚠ 原来用 `_texts = _texts.filter(...)`：每帧四次 filter，
	# 每次都**新建一个数组**把老元素搬过去，然后丢掉旧的。
	# 这个节点只在有反馈时开_process，而割草高峰期光是伤害数字就
	# 能有几十上百个 —— 于是每秒制造 4×60 = 240 个数组，全都是垃圾。
	# 用写指针覆盖保留项，避免 remove_at 反复搬移数组尾部。
	#
	_expire(_texts)
	_expire(_bursts)
	_expire(_muzzles)
	_expire(_zaps)

	queue_redraw()
	if _texts.is_empty() and _bursts.is_empty() and _muzzles.is_empty() and _zaps.is_empty():
		set_process(false)


## 推进一组元素的存活计时。
func _advance(items: Array, delta: float) -> void:
	for item in items:
		item["life"] = float(item["life"]) - delta


## 原地压缩，剔除 life <= 0 的元素，不新建数组。
func _expire(items: Array) -> void:
	var write := 0
	for item in items:
		if float(item["life"]) > 0.0:
			items[write] = item
			write += 1
	items.resize(write)

func _draw() -> void:
	for item in _zaps:
		var ratio := clampf(float(item["life"]) / float(item["max"]), 0.0, 1.0)
		var from_pos: Vector2 = item["from"]
		var to_pos: Vector2 = item["to"]
		var mid := (from_pos + to_pos) * 0.5
		var side := (to_pos - from_pos).orthogonal().normalized() * 8.0
		var col := Color(0.35, 0.86, 1.0, ratio)
		draw_polyline(PackedVector2Array([from_pos, mid + side, to_pos]), col, 3.0, true)
		draw_line(from_pos, to_pos, Color(0.75, 0.96, 1.0, ratio * 0.45), 6.0, true)
	for item in _muzzles:
		var ratio := clampf(float(item["life"]) / float(item["max"]), 0.0, 1.0)
		var pos: Vector2 = item["pos"]
		var dir: Vector2 = item["dir"]
		var side := dir.orthogonal() * 5.0
		var tip := pos + dir * (18.0 + 8.0 * ratio)
		var col := Color(1.0, 0.82, 0.26, ratio)
		draw_colored_polygon(PackedVector2Array([pos - side, tip, pos + side]), col)
		draw_circle(pos, 4.0 * ratio, Color(1.0, 0.96, 0.65, ratio))
	for item in _bursts:
		var ratio := clampf(float(item["life"]) / float(item["max"]), 0.0, 1.0)
		var col: Color = item["color"]
		col.a *= ratio
		draw_arc(item["pos"], float(item["radius"]), 0.0, TAU, 16, col, 2.0, true)
	for item in _texts:
		var ratio := clampf(float(item["life"]) / float(item["max"]), 0.0, 1.0)
		var col: Color = item["color"]
		col.a = minf(1.0, ratio * 1.5)
		var pos: Vector2 = item["pos"]
		draw_string(_font, pos + Vector2(1.0, 1.0), String(item["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(0.0, 0.0, 0.0, col.a * 0.75))
		draw_string(_font, pos, String(item["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, col)
