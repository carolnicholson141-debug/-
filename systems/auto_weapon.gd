extends Node
## 武器。
##
## 两种开火模式（由 InputController 决定）：
##   auto   —— 冷却一好就朝索敌结果开火。割草游戏的本体体验：
##             玩家的注意力全放在走位上，打是自动的。
##   manual —— 按住开火键才射击，弹道朝鼠标方向。
##             瞄准完全交给玩家，换来的是操作感。
##
## 索敌用空间哈希的 find_nearest，而不是遍历全部丧尸：
## 同屏 400 只时，遍历是每帧 400 次距离计算，哈希查询通常只看十几只。
## 手动模式虽然用鼠标定方向，但仍然要查一次哈希 —— 用来判断"射程内有没有敌人"，
## 没有敌人的时候按住不放也不该空放（那会让玩家以为自己打中了什么）。

## 由 Main 注入：真正的「生成一发子弹」动作。
## 用 Callable 而不是 get_parent() 去找对象池，是为了让武器不需要知道
## 子弹是从哪来的、怎么回收的 —— 换弹幕实现、换成近战挥砍，都不用改这里。
var spawn_projectile: Callable = Callable()

## 索敌用的哈希表
var grid: SpatialHash = null

## 武器持有者
var player: Node2D = null

## 由 Main 注入：开火模式控制器。
## 传 null 时退化成"永远自动"，这样无头测试不接线也能跑。
var input_ctl: Node = null

## 由 Main 注入：返回"射程内最近的存活人类反派"，没有则 null。
## 人类不进丧尸的分离哈希（否则会污染 zombie._separation 的类型化缓冲），
## 所以武器索敌在 grid 里找不到目标时，要额外问这个 Callable 一次。
## 人类数量只有个位数，直接线性遍历即可，无需专门哈希。
var human_nearest: Callable = Callable()

var _cd: float = 0.0


func reset() -> void:
	_cd = 0.0


func tick(delta: float) -> void:
	if player == null or grid == null or not spawn_projectile.is_valid():
		return
	if not player.alive:
		return

	_cd -= delta
	if _cd > 0.0:
		return

	var stats: Dictionary = player.stats
	var range_val := float(stats["range"])

	# 手动模式下，方向由玩家的瞄准决定；自动模式下由索敌决定。
	# 但两种模式都要查一次哈希：自动模式是要目标，手动模式是要知道"射程内有没有人"。
	#
	# 这里显式取布尔值而不是 `var manual := input_ctl.is_manual()`：
	# input_ctl 声明成 Node，GDScript 静态推断不出那个方法的返回类型，
	# 用 := 会因为"无法推断"直接编译失败。
	var manual: bool = input_ctl != null and bool(input_ctl.is_manual())

	var base_dir := Vector2.ZERO
	if manual:
		if not bool(input_ctl.is_firing()):
			return
		# 射程内没有敌人时不消耗冷却、也不开火。
		# 冷却是要消耗的 —— 否则玩家可以对着空气连点，听到一堆空枪音效。
		if grid.find_nearest(player.position, range_val) == null \
				and not _has_human_in_range(range_val):
			return
		base_dir = input_ctl.aim_dir
	else:
		var target: Node2D = grid.find_nearest(player.position, range_val)
		if target == null:
			target = _nearest_human(range_val)
		if target == null:
			# 没敌人时不进入冷却，这样敌人一进范围就能立刻开火 ——
			# 否则玩家会感觉「明明有怪却要等一下才打」。
			return
		base_dir = (target.position - player.position).normalized()

	_cd = float(stats["cooldown"])
	player.aim_at(base_dir)

	var count := int(stats["projectiles"])
	var spread := deg_to_rad(float(stats["spread_deg"]))

	# 子弹从**枪口**出，不是从身体中心出。
	# 原来写的是 player.position + 朝向前方 23px —— 那是脚底高度，
	# 看起来像从腿/肚子打出来。枪口位置由 Player 按当前动画给（见 muzzle_position）。
	#
	# 注意：player 声明成 Node2D，GDScript 静态查不到这个自定义方法，
	# 所以必须显式标类型、不能用 := （同上面 input_ctl 那段的理由）。
	var muzzle_pos: Vector2 = player.muzzle_position()

	for i in count:
		# 单发时正中目标；多发时以目标方向为中心左右均分。
		# 手动模式下这个扇形是固定张角 —— 玩家瞄哪、扇形就朝哪，
		# 相当于用"面"来弥补鼠标精度的不足，反而比单发更好用。
		var offset := 0.0
		if count > 1:
			offset = (float(i) - float(count - 1) * 0.5) * spread
		var dir := base_dir.rotated(offset)
		# 手动模式关掉软锁定：那个模块只为"自动索敌追得上移动目标"服务，
		# 而手动模式的卖点就是玩家自己瞄准。开着的话子弹会被掰向最近的
		# 丧尸，玩家瞄准的方向完全不起作用。
		# 追踪半径直接取 stats["range"]，保证"子弹会追的目标"始终在
		# 玩家的索敌范围内 —— 写死 720 会让子弹去追够不到的怪。
		spawn_projectile.call(
			muzzle_pos,
			dir,
			float(stats["damage"]),
			float(stats["proj_speed"]),
			int(stats["pierce"]),
			float(stats["proj_life"]),
			int(stats["chain_count"]),
			float(stats["chain_range"]),
			float(stats["crit_chance"]),
			float(stats["crit_multiplier"]),
			not manual,
			range_val
		)

	Events.weapon_fired.emit()
	Events.weapon_fired_at.emit(muzzle_pos, base_dir)


## 射程内是否还有存活的人类反派（给"手动模式判空"用）。
func _has_human_in_range(range_val: float) -> bool:
	if not human_nearest.is_valid():
		return false
	return human_nearest.call(range_val) != null


## 射程内最近的存活人类，没有则 null。兜底：没接线时返回 null。
func _nearest_human(range_val: float) -> Node2D:
	if not human_nearest.is_valid():
		return null
	return human_nearest.call(range_val)
