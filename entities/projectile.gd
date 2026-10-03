extends Node2D
## 投射物。
##
## 命中判定不走物理引擎，而是每帧用空间哈希查一次「我附近有谁」，
## 然后做精确圆-圆判定。400 只丧尸时，一次查询通常只返回个位数候选。
##
## 由 Main 统一驱动 tick()。

var damage: float = 10.0
var speed: float = 640.0
var life: float = 1.1

## 还能额外穿透几个敌人。0 = 命中一个就消失。
var _pierce_left: int = 0
var _chain_left: int = 0
var _chain_range: float = 115.0
var _crit_chance: float = 0.0
var _crit_multiplier: float = 1.8

## 软锁定追踪：子弹不会瞬移转向，而是按最大角速度逐帧修正。
## 这样能保留"发射方向"的手感，同时让自动火力能追上移动中的丧尸。
##
## ⚠ **手动开火模式下必须关掉。** 这个模块存在的唯一理由是"自动索敌时
## 子弹追得上移动中的目标"；而手动模式的卖点恰恰是"我瞄哪打哪"。
## 开着它的话，子弹一离膛就被 find_nearest 掰向最近的丧尸（哪怕玩家
## 瞄准了完全相反的方向），手动瞄准形同虚设 ——
## 720px 半径内的怪都会被吸走，range 430 的射程设定也失去意义。
var homing_enabled: bool = true
var _homing_target: Node2D = null
## 追踪半径。由 Main 在生成时按玩家的 stats.range 注入，
## 不再写死 720 —— 索敌半径和武器射程必须是同一个数，
## 否则子弹会去追玩家根本够不到的怪。
var _homing_range: float = 430.0
var _homing_turn_rate: float = 5.8

## 本发子弹已经打过的敌人，避免穿透时对同一只重复结算
var _hit: Array[Node2D] = []
## 人类敌人不登记进丧尸空间哈希，由 Main 注入后单独做同样的扫掠判定。
var human_targets: Array = []

var alive: bool = false
var recycle_ready: bool = false

var _life_left: float = 0.0
var _radius: float = 6.0
var _prev_pos: Vector2 = Vector2.ZERO

## 本发子弹的查询缓冲。**终身复用同一个数组**，不在每帧新建。
##
## ⚠ 命中检测每帧每发子弹都要查一次"附近有什么"。原来的
## query_radius_exact() 每次调用都 return 一个新 Array ——
## 哪怕里面只有 2~3 个元素、哪怕下一帧就扔，也是一笔实打实的堆分配。
## 后期场上几十发子弹同时飞 = 每秒上千个短命数组，
## 这和对象池要消除的 GC 抖动是同一类问题（同一个思路：复用容器）。
##
## 出池时只 clear() 不重新赋值，见 spawn()。
var _query_buf: Array = []
# 电击链使用独立缓冲，避免覆盖 tick 正在遍历的命中候选。
var _chain_query_buf: Array = []


func spawn(
	spawn_pos: Vector2,
	direction: Vector2,
	p_damage: float,
	p_speed: float,
	p_pierce: int,
	p_life: float,
	p_chain_count: int = 0,
	p_chain_range: float = 115.0,
	p_crit_chance: float = 0.0,
	p_crit_multiplier: float = 1.8,
	p_homing: bool = true,
	p_homing_range: float = 430.0
) -> void:
	position = spawn_pos
	_prev_pos = spawn_pos
	rotation = direction.angle()
	damage = p_damage
	speed = p_speed
	_pierce_left = p_pierce
	_chain_left = p_chain_count
	_chain_range = p_chain_range
	_crit_chance = p_crit_chance
	_crit_multiplier = p_crit_multiplier
	# 池化对象的铁律：这两个必须重置。不重置的话，手动模式打出的那一发
	# 关掉追踪后，下一局自动模式的第一发会继承 false 而不追踪 ——
	# 而且这种"偶尔有几发子弹不拐弯"的bug极难复现和定位。
	homing_enabled = p_homing
	_homing_range = p_homing_range
	_homing_target = null
	life = p_life
	_life_left = p_life
	_hit.clear()
	# 查询缓冲同样要清：池化对象的铁律是"出池逐项重置"。
	# query_radius_exact_into() 自己也会 clear，这里是显式对齐语义 ——
	# 万一将来给它加了"不清空就复用"的模式，这里不会成为隐藏地雷。
	_query_buf.clear()
	_chain_query_buf.clear()
	alive = true
	recycle_ready = false
	visible = true
	z_index = 5   # 盖在所有丧尸之上，不然子弹会被尸群挡住看不见
	queue_redraw()


## ---------------------------------------------------------------- 每帧更新

func tick(delta: float, grid: SpatialHash) -> void:
	if not alive:
		return

	_life_left -= delta
	if _life_left <= 0.0:
		alive = false
		recycle_ready = true
		return

	_prev_pos = position
	_update_homing(delta, grid)
	var dir := Vector2.RIGHT.rotated(rotation)
	var step := dir * speed * delta
	position += step

	# 命中检测。
	#
	# ⚠ **必须扫掠，不能只测终点。** 只查 position（移动后）的话，
	# 每帧位移超过判定半径时子弹会直接从丧尸身体里跳过去、一滴血不掉：
	#   基础射速 640px/s → 60fps 每帧 10.7px，判定半径 20px，安全；
	#   proj_speed 叠满 5 次 = 640 × 1.22^5 ≈ 1730px/s → 每帧 28.8px > 20px，
	#   **必定穿透**。所以这里查的是"上一帧位置 → 当前位置"整段线段。
	#
	# 查询范围用**扫掠线段的包围球**：中心取中点、半径 = 判定半径 + 半步长。
	# 这样无论一步走多远，_prev_pos 到 position 整段都在候选集里。
	# （只查终点会漏判：子弹终点周围可能一只怪都没有，但路径中段正穿过尸群。）
	var sweep_from := _prev_pos
	var reach := _radius + 14.0
	var step_len := step.length()
	var query_pos := position - step * 0.5
	var query_r := reach + step_len * 0.5

	grid.query_radius_exact_into(query_pos, query_r, _query_buf)
	for enemy in _query_buf:
		var target := enemy as Node2D
		if target == null or not bool(target.get("solid")):
			continue
		if _hit.has(target):
			continue
		# 精确判定：点到**扫掠线段**的距离，而不是到终点的距离。
		# 用目标的实际碰撞半径，这样坦克(radius 17)和普通丧尸(12)
		# 的命中手感一致 —— 旧代码写死 +14，对大体型丧尸偏松。
		var target_radius := 14.0
		if target is Zombie:
			target_radius = (target as Zombie).radius
		if _distance_to_segment(target.position, sweep_from, position) > _radius + target_radius:
			continue

		_hit.append(target)
		var hit_damage := damage
		if _crit_chance > 0.0 and randf() < _crit_chance:
			hit_damage *= _crit_multiplier
			Events.critical_hit.emit(target.position, hit_damage)
		target.take_damage(hit_damage)
		var zombie_target := target as Zombie
		if zombie_target != null:
			_try_chain(zombie_target, grid)

		_pierce_left -= 1
		if _pierce_left < 0:
			# 打不动了。把子弹停在敌人身上，而不是穿过去之后才消失，
			# 这样视觉上「击中的那一瞬间」和伤害结算是对齐的。
			position = target.position
			alive = false
			recycle_ready = true
			return

	# 枪手等人类敌人不在 zombie grid 中，必须补一次命中检测。
	# 否则玩家子弹只会查询丧尸，视觉上经过枪手也不会造成伤害。
	if alive:
		for enemy in human_targets:
			# queue_free() 到数组清理之间可能隔一帧，先验证实例再做类型转换。
			if not is_instance_valid(enemy):
				continue
			var human := enemy as Node2D
			if human == null or not is_instance_valid(human) or not bool(human.get("alive")) or _hit.has(human):
				continue
			if _distance_to_segment(human.position, sweep_from, position) > _radius + 18.0:
				continue
			_hit.append(human)
			human.take_damage(damage)
			_pierce_left -= 1
			if _pierce_left < 0:
				position = human.position
				alive = false
				recycle_ready = true
				return


func _update_homing(delta: float, grid: SpatialHash) -> void:
	if not homing_enabled or grid == null:
		return

	# 目标死亡、离开追踪范围或被对象池回收后，重新锁定最近的丧尸。
	if _homing_target == null \
			or not is_instance_valid(_homing_target) \
			or not bool(_homing_target.get("solid")) \
			or _homing_target.position.distance_to(position) > _homing_range:
		_homing_target = grid.find_nearest(position, _homing_range)
		var nearest_human: Node2D = null
		var nearest_human_d2 := _homing_range * _homing_range
		for candidate in human_targets:
			# 已释放的对象不能直接 as Node2D，否则 Godot 会报
			# "Trying to cast a freed object"。
			if not is_instance_valid(candidate):
				continue
			var human := candidate as Node2D
			if human == null or not is_instance_valid(human) or not bool(human.get("alive")):
				continue
			var d2 := human.position.distance_squared_to(position)
			if d2 < nearest_human_d2:
				nearest_human_d2 = d2
				nearest_human = human
		if nearest_human != null:
			var current_d2 := INF
			if _homing_target != null and is_instance_valid(_homing_target):
				current_d2 = _homing_target.position.distance_squared_to(position)
			if current_d2 == INF or nearest_human_d2 < current_d2:
				_homing_target = nearest_human

	if _homing_target == null or not is_instance_valid(_homing_target):
		return

	var to_target := _homing_target.position - position
	if to_target.length_squared() < 0.01:
		return

	var desired_angle := to_target.angle()
	# 每帧最多转 _homing_turn_rate 弧度，避免子弹瞬间折返或抖动。
	rotation = rotate_toward(rotation, desired_angle, _homing_turn_rate * delta)


func _try_chain(source: Zombie, grid: SpatialHash) -> void:
	var current := source
	while _chain_left > 0:
		var target: Zombie = null
		var best_d2 := _chain_range * _chain_range
		grid.query_radius_exact_into(current.position, _chain_range, _chain_query_buf)
		for enemy in _chain_query_buf:
			var candidate := enemy as Zombie
			if candidate == null or not candidate.solid or _hit.has(candidate):
				continue
			var d2 := current.position.distance_squared_to(candidate.position)
			if d2 < best_d2:
				best_d2 = d2
				target = candidate
		if target == null:
			return
		_hit.append(target)
		_chain_left -= 1
		target.take_damage(damage * 0.65)
		Events.chain_zapped.emit(current.position, target.position)
		current = target


## 点 p 到线段 ab 的最短距离。
##
## 扫掠命中判定的基础。用来回答"子弹这一步跨过去的时候，
## 有没有从敌人身上碾过" —— 只测终点距离会漏判高速子弹。
##
## 分三段处理（和所有"点到线段"的标准写法一致）：
##   1. 参数 t < 0  → 最近点是 a（起点之前）
##   2. 参数 t > 1  → 最近点是 b（终点之后）
##   3. 否则        → 投影落在段内，取垂距
## 全程避开开方：用平方距离比较，只有确认垂距后才 sqrt 一次。
func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	# 起点终点重合（极端 delta 或零速度）时退化成点距
	if len_sq < 0.000001:
		return p.distance_to(a)
	var t := (p - a).dot(ab) / len_sq
	if t < 0.0:
		return p.distance_to(a)
	if t > 1.0:
		return p.distance_to(b)
	var proj := a + ab * t
	return p.distance_to(proj)


## ---------------------------------------------------------------- 绘制

## 拖尾 + 弹头。用 _draw 而不是贴图，省一次素材加载。
func _draw() -> void:
	var head := Color("#fff0c2")
	var trail := Color(1.0, 0.85, 0.45, 0.35)

	# 拖尾长度按速度缩放，快子弹看起来更长
	var tail_len := clampf(speed / 110.0, 3.0, 9.0)
	draw_line(Vector2(-tail_len, 0.0), Vector2.ZERO, trail, 3.0, true)
	# 弹头贴图负责形状，这个小光点只保留命中前的亮度层。
	draw_circle(Vector2.ZERO, 1.6, head)
