class_name Zombie
extends Node2D
## 丧尸。
##
## 与玩家一样不用物理体：移动手工积分，靠 SpaceHash 做邻近判定。
## 每只丧尸每帧只做两件事——朝玩家走一步，和把挤在一起的同伴推开一点。
##
## 本节点由 Main 统一驱动 tick()，不自己开 _process。

const STATE_WALK := "walk"
const STATE_ATTACK := "attack"
const STATE_HURT := "hurt"
const STATE_DEAD := "dead"

const ELITE_SIZE_MULT := 1.55
const ELITE_CHARGE_COOLDOWN := 5.0
const ELITE_CHARGE_WINDUP := 0.72
const ELITE_CHARGE_DURATION := 0.48
const ELITE_CHARGE_SPEED_MULT := 3.4
const ELITE_ART_SCALE := 0.075
const ELITE_ART_ANCHOR := Vector2(0.0, -362.0)
var _boss_frames_cache: SpriteFrames = null

## 世界引用，死亡时回调 world.on_zombie_killed(self)
var world: Node = null

# --- 由 spawn() 决定
var variant: Dictionary = {}
var radius: float = 12.0
var speed: float = 60.0
var damage: float = 7.0
var xp_value: float = 1.0
var max_hp: float = 18.0

# --- 运行时状态
var hp: float = 0.0
var alive: bool = true
var is_elite: bool = false
var is_boss: bool = false
var elite_kind: int = 0 # 0 冲锋 / 1 重装 / 2 毒雾

## 是否参与碰撞与索敌。死亡后立刻置 false，让 Main 在建表时跳过它。
var solid: bool = true

## Main 看到这个为 true 就把节点回收进池
var recycle_ready: bool = false

var _state: String = STATE_WALK
var _current_anim: String = ""
var _attack_cd: float = 0.0
var _stagger: float = 0.0
var _death_timer: float = 0.0
var _facing_left: bool = false

## 上一次算出的分离力（未归一化）。见 tick 里 update_separation 的说明。
var _sep_cache: Vector2 = Vector2.ZERO

## 分离查询的候选容器。**终身复用同一个数组**，不再每次查询分配新的。
## 这是这个游戏里调用最频繁的一次分配：每只丧尸每帧一次。
##
## 声明成 Array[Zombie] 而不是普通 Array 是有意的：类型化数组取出来的元素
## 静态类型已知，循环里就不用再做 `as Zombie` 转换。
## 分离内循环每帧要跑几千次，每次省掉一次类型转换，累积起来很可观。
var _sep_buf: Array[Zombie] = []

## 当前是否因为 LOD 被隐藏（视野外）。避免重复设置 visible。
var _lod_hidden: bool = false

## 走动起伏的相位(0~1)。出池时随机，让整片尸群的摇摆不同步。
##
## 如果所有丧尸用同一个相位，420 只会像阅兵一样整齐地上下抖 ——
## 那种"同步感"比不动更假。
var _wobble_phase: float = 0.0

## 精灵基准 offset（来自变体 anchor）。起伏是在它基础上叠加的。
## 必须记下来：出池时 _anim.offset 会被 anchor 覆盖，但每帧起伏要能还原。
var _base_offset: Vector2 = Vector2.ZERO

## 受击抖动倒计时，> 0 时叠加速度更快的抖动
var _hurt_shake: float = 0.0
var _flash_left: float = 0.0
var _base_tint: Color = Color.WHITE
var _elite_skill_cd: float = 0.0
var _elite_windup: float = 0.0
var _elite_charge_left: float = 0.0
var _elite_charge_dir: Vector2 = Vector2.ZERO
var _elite_aura_cd: float = 0.0

## 本只丧尸的外观修正 {scale_mult, tint_shift, radius_mult}
var _look: Dictionary = {}

## 远程射击参数。**空字典 = 纯近战**，也就是除机枪尸外的全部变体 ——
## 那个分支在 _tick_ranged 里第一行就早退，对现有丧尸是零开销。
var _ranged: Dictionary = {}

## 远程开火冷却。出池时设成一个完整的间隔，让它别一出生就开枪。
var _fire_cd: float = 0.0

@onready var _anim: AnimatedSprite2D = $Sprite


## 出池后由 Main 调用，把节点恢复成一只全新的丧尸。
## 池化对象的铁律：出池时状态是脏的，必须逐项重置，漏一项就会看到
## 「刚刷新出来的丧尸飘着上一次的死亡动画」这类 bug。
func spawn(
	p_variant: Dictionary,
	wave_hp: float,
	wave_speed: float,
	wave_damage: float,
	p_elite: bool,
	spawn_pos: Vector2,
	p_elite_kind: int = 0,
	p_boss: bool = false
) -> void:
	variant = p_variant
	is_elite = p_elite
	is_boss = p_boss
	elite_kind = p_elite_kind if p_elite else 0

	# --- 外观变体。普通丧尸才抽，精英固定外观 ——
	# 精英是"这一波的标志物"，它长得跟旁边小怪一样花哨就没人认得出。
	_look = GameData.roll_zombie_look() if not p_elite else {
		"scale_mult": 1.0, "tint_shift": Color.WHITE, "radius_mult": 1.0,
	}

	var elite_mult := GameData.ELITE_STAT_MULT if p_elite else 1.0
	if p_boss:
		elite_mult = 6.0
	if p_elite and elite_kind == 1:
		elite_mult *= 1.55
	elif p_elite and elite_kind == 2:
		elite_mult *= 1.18
	radius = (
		float(variant["radius"])
		* (1.95 if p_boss else (1.8 if p_elite and elite_kind == 1 else (1.35 if p_elite and elite_kind == 2 else (ELITE_SIZE_MULT if p_elite else 1.0))))
		* float(_look["radius_mult"])
	)
	speed = GameData.ZOMBIE_BASE_SPEED * float(variant["speed_mult"]) * wave_speed
	damage = GameData.ZOMBIE_BASE_DAMAGE * float(variant["damage_mult"]) * wave_damage * elite_mult
	max_hp = GameData.ZOMBIE_BASE_HP * float(variant["hp_mult"]) * wave_hp * elite_mult
	xp_value = float(variant["xp"]) * (GameData.ELITE_STAT_MULT if p_elite else 1.0)

	hp = max_hp
	alive = true
	solid = true
	recycle_ready = false
	_state = STATE_WALK
	# _current_anim 必须一起清掉。_play() 里有"动画名没变就跳过"的短路，
	# 池化复用时如果上一只丧尸最后停在 walk，新丧尸出池时那次
	# _play("walk") 会被短路掉、AnimatedSprite2D 停在 sprite_frames
	# 刚赋值时的默认动画（第一个动画）上 —— 又是一只不会走的丧尸。
	_current_anim = ""
	_attack_cd = 0.0
	_stagger = 0.0
	_death_timer = 0.0
	_hurt_shake = 0.0
	_flash_left = 0.0
	_elite_skill_cd = 2.2 if p_elite else 0.0
	_elite_windup = 0.0
	_elite_charge_left = 0.0
	_elite_charge_dir = Vector2.ZERO
	_elite_aura_cd = 0.0
	# 分离力缓存必须清掉：池化复用时不重置的话，新丧尸出池后的第一帧
	# 会带着上一只丧尸（可能是几百像素外那只）的推力开始移动，看起来像抽了一下。
	_sep_cache = Vector2.ZERO
	_lod_hidden = false

	# 用外观随机源抽相位，而不是全局 RNG —— 理由同 GameData.roll_zombie_look。
	# 这样整片尸群的摇摆节奏也是可复现的。
	_wobble_phase = GameData.variant_rng.randf()

	position = spawn_pos
	visible = true
	# 图层排序：经验球(-2) < 尸体(-1) < 活丧尸(0) < 子弹(5)
	# 尸体压到活丧尸下面，一堆尸体叠上去时画面才不乱。
	z_index = 0

	_anim.sprite_frames = _frames_for(variant, p_boss, p_elite)
	# 池化对象的铁律：出池逐项重置。这里也要重置远程状态，
	# 否则上一只（可能是纯近战的普通丧尸）的冷却会留给下一只。
	_ranged = variant.get("ranged", {})
	_fire_cd = float(_ranged.get("interval", 1.5)) if not _ranged.is_empty() else 0.0
	if p_boss:
		# 首领也使用同一套 43px Kenney 俯视角角色，只用尺寸和机器人皮肤体现等级。
		_anim.scale = Vector2(2.1, 2.1)
		_base_offset = Vector2(0.0, -21.5)
	else:
		_base_offset = ELITE_ART_ANCHOR if p_elite else variant["anchor"]
		var visual_elite_scale := 1.8 if p_elite and elite_kind == 1 else (1.35 if p_elite and elite_kind == 2 else (ELITE_SIZE_MULT if p_elite else 1.0))
		var art_scale := ELITE_ART_SCALE if p_elite else GameData.ZOMBIE_SCALE
		var s := art_scale * float(variant["scale_mult"]) * float(_look["scale_mult"]) * visual_elite_scale
		_anim.scale = Vector2(s, s)
	_anim.offset = _base_offset
	_anim.rotation = 0.0

	# 底色（变体 tint，用于区分兵种）× 外观偏移（用于区分个体）
	var tint: Color = variant["tint"]
	if p_boss:
		tint = tint.lerp(Color(0.55, 0.20, 0.16), 0.60)
	elif p_elite:
		var elite_color := Color(1.0, 0.35, 0.3) if elite_kind == 0 else (Color(0.78, 0.52, 0.28) if elite_kind == 1 else Color(0.35, 0.95, 0.42))
		tint = tint.lerp(elite_color, 0.55)
	else:
		var shift: Color = _look["tint_shift"]
		tint = Color(tint.r * shift.r, tint.g * shift.g, tint.b * shift.b)
	_base_tint = tint
	_anim.modulate = _base_tint

	_play(STATE_WALK)
	queue_redraw()

func _boss_frames() -> SpriteFrames:
	if _boss_frames_cache != null:
		return _boss_frames_cache
	_boss_frames_cache = GameData.kenney_boss_frames()
	return _boss_frames_cache


## 按变体种类挑帧源。
##
## 现在工程里只有**一套**丧尸帧：Kenney zoimbie1（43px 画布、内容填满、
## 脚底贴底）。首领用 robot1，玩家用 survivor1。
##
## ⚠ 为什么不给每个变体分配各自的帧源：Kenney 包里一共只有 3 套角色皮肤
## （zoimbie1 / robot1 / survivor1），扣掉首领和玩家能留给"五种丧尸"的
## 只有 1 套 —— 而用玩家皮演丧尸本身就不合适。所以**变体之间的视觉区分
## 只能靠 tint（兵种色）+ scale_mult（体型）+ 血条**，素材层面必然共用。
## 这不是偷懒，是素材数量的硬约束。
##
## 历史上这里曾按 variant["sheet"] / variant["sequence"] 分派到
## CraftPix 128px 横条表和 gunner 整幅序列帧。这两条素材路径现在都已弃用
## （实测见 game_data.gd 里 ZOMBIE_VARIANTS 的 anchor 注释），继续保留
## 分派逻辑只会让人以为"五种丧尸长得不一样"，是纯粹的误导 ——
## 所以下面**显式忽略** sheet/sequence，而不是留一个失效的分支。
##
## 缩放与锚点由变体表里的 scale_mult / anchor 各自指定，这里只负责"帧从哪来"。
func _frames_for(_variant: Dictionary, p_boss: bool, p_elite: bool) -> SpriteFrames:
	if p_boss:
		return _boss_frames()
	if p_elite:
		return GameData.elite_zombie_frames()
	return GameData.kenney_zombie_frames()


## ---------------------------------------------------------------- 每帧更新

## update_separation=false 时复用上一次算出的分离力。
## 由 Main 按帧号错开分配（见 main.gd 的 _tick_zombies），不是所有丧尸同步跳过 ——
## 如果全体在同几帧一起偷懒，最坏帧的耗时一点都不会降。
func tick(
	delta: float,
	player_pos: Vector2,
	player: Node2D,
	grid: SpatialHash,
	update_separation: bool = true
) -> void:
	if not alive:
		# 死亡动画播完就交给 Main 回收
		_death_timer -= delta
		# 倒地时把身体落回基准位置，否则会僵在半空中
		_anim.offset = _base_offset
		if _death_timer <= 0.0:
			recycle_ready = true
		return

	_anim.offset = Vector2(
		_base_offset.x,
		_base_offset.y + _wobble_offset(delta)
	)
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		_anim.modulate = Color.WHITE
	else:
		_anim.modulate = _base_tint

	# 受击硬直：挨打时定住一小会儿，让打击感有反馈
	if _stagger > 0.0:
		_stagger -= delta
		if _stagger <= 0.0:
			_state = STATE_WALK
			_play(STATE_WALK)
		return

	var to_player := player_pos - position
	var attack_range := radius + GameData.PLAYER_RADIUS + GameData.ZOMBIE_ATTACK_PADDING
	var dist2 := to_player.length_squared()

	# 远程开火。刻意**不** return —— 机枪尸边走边打，
	# 走位逻辑完全复用下面那套（追人 + 分离），不需要单独的移动模式。
	_tick_ranged(delta, to_player, dist2, player)

	if is_elite and not is_boss and _tick_elite_skill(delta, to_player, dist2, player):
		return
	if is_elite and elite_kind == 2:
		_elite_aura_cd = maxf(0.0, _elite_aura_cd - delta)
		if dist2 <= 125.0 * 125.0 and _elite_aura_cd <= 0.0:
			_elite_aura_cd = 1.35
			player.take_damage(damage * 0.72)
			queue_redraw()

	# 用平方距离比：能进攻击分支的丧尸直接省掉一次开方。
	# 平方距离 >= attack_range² 时才有必要开方求方向，而那时开方是必需的。
	if dist2 <= attack_range * attack_range:
		_do_attack(delta, player)
		return

	# 不在攻击距离内 → 朝玩家走，同时被同伴推开
	if _state != STATE_WALK:
		_state = STATE_WALK
		_play(STATE_WALK)

	if update_separation:
		# 分离力不必每次 tick 都重算：它是短程力，邻居集合每帧只挪一点点，
		# 复用一两帧前的值画面上完全看不出来。省下的却是每只丧尸每次 tick
		# 一次哈希查询 + 最多 16 次邻居判定 —— 同屏 400 只时这是最大的一笔开销。
		#
		# 缓存的是**未归一化**的合力：limit_length 只负责截断过大的推力，
		# 保留原值才能让"越挤推得越狠"这个手感成立。
		_sep_cache = _separation(grid)

	var desired := to_player / sqrt(dist2)
	var separation := _sep_cache.limit_length(1.0)
	var steer := (desired + separation * GameData.SEPARATION_WEIGHT).normalized()

	position += steer * speed * delta
	if is_elite:
		queue_redraw()

	# 横向翻转。单朝向素材最省事的处理方式：往左走就镜像。
	if steer.x < -0.15 and not _facing_left:
		_facing_left = true
		_anim.flip_h = true
	elif steer.x > 0.15 and _facing_left:
		_facing_left = false
		_anim.flip_h = false


## 远程射击。只有配了 "ranged" 的变体（目前只有机枪尸）会走到这里，
## 其余第一行就早退 —— 代价是一次 Dictionary.is_empty()。
##
## 设计取舍：先做"边走边打"的最小版本，**不引入站桩/后撤的移动模式**。
## 理由是与现有追击逻辑零冲突：移动、分离、LOD 全都不用动。
## 等它真的需要"保持距离射击"时再加移动模式，那时改动面才看得清。
func _tick_ranged(delta: float, to_player: Vector2, dist2: float, player: Node2D) -> void:
	if _ranged.is_empty():
		return

	# 冷却每帧都走，哪怕当前不在射程内 ——
	# 这样它一走进射程就能立刻开火，而不是"进来之后还要再等一秒"。
	_fire_cd -= delta
	if _fire_cd > 0.0:
		return

	if world == null or player == null or not player.alive:
		return
	# dist2 < 1 时方向不可靠（与 InputController._update_aim 同一个理由）
	if dist2 < 1.0:
		return

	var reach := float(_ranged["range"])
	if dist2 > reach * reach:
		return

	_fire_cd = float(_ranged["interval"])
	var dir := to_player / sqrt(dist2)
	var muzzle := position + dir * (radius + 10.0)

	# 复用人类反派那条弹道：子弹本身与阵营无关，都是"敌方弹幕打玩家"。
	# 函数名里的 human 是历史遗留（当初只有人类会开枪），这次没顺手重命名 ——
	# 那条链路刚验证过，不想在接新角色的同时动它。重命名留作独立一次改动。
	world.spawn_human_bullet(
		muzzle, dir,
		float(_ranged["speed"]),
		damage * float(_ranged["damage_scale"])
	)
	# 枪口火光：复用同一份反馈层，观感与玩家/人类开火一致。
	Events.weapon_fired_at.emit(muzzle, dir)


func _tick_elite_skill(delta: float, to_player: Vector2, dist2: float, player: Node2D) -> bool:
	if elite_kind != 0:
		return false
	_elite_skill_cd = maxf(0.0, _elite_skill_cd - delta)

	# 蓄力阶段：停下来给玩家一个明确的红圈预警。
	if _elite_windup > 0.0:
		_elite_windup -= delta
		_anim.modulate = _base_tint.lerp(Color("#ffb06b"), 0.45)
		queue_redraw()
		if _elite_windup <= 0.0:
			_elite_charge_left = ELITE_CHARGE_DURATION
			_elite_charge_dir = to_player.normalized() if dist2 > 0.001 else Vector2.RIGHT
		return true

	# 冲刺方向在蓄力结束时锁定，玩家横移可以躲开。
	if _elite_charge_left > 0.0:
		_elite_charge_left -= delta
		position += _elite_charge_dir * speed * ELITE_CHARGE_SPEED_MULT * delta
		_anim.rotation = sin(_elite_charge_left * 44.0) * 0.05
		queue_redraw()
		var hit_range := radius + GameData.PLAYER_RADIUS + 8.0
		if position.distance_squared_to(player.position) <= hit_range * hit_range:
			player.take_damage(damage * 1.45)
			_elite_charge_left = 0.0
			_anim.rotation = 0.0
		return true

	_anim.rotation = 0.0
	if _elite_skill_cd <= 0.0 and dist2 >= 120.0 * 120.0 and dist2 <= 520.0 * 520.0:
		_elite_skill_cd = ELITE_CHARGE_COOLDOWN
		_elite_windup = ELITE_CHARGE_WINDUP
		Events.elite_charge_warning.emit(position)
		queue_redraw()
		return true

	return false


## 走动起伏：静态贴图"活起来"的关键一招。
##
## 用相位累加而不是 `sin(Time.get_ticks_msec())`：
## 后者要读全局时钟，而且 420 只丧尸各读一次系统时间比一次加法贵得多。
## 相位自己 += delta/period 也能在 LOD 降频时天然正确 ——
## 视野外的丧尸用 delta×3 调用，相位也一次走三倍，摇摆节奏和速度完全同步。
##
## 受击时叠加一个更快的小抖动，让"打中了"这件事有肉眼可见的反馈，
## 而不是只靠飘伤害数字。
func _wobble_offset(delta: float) -> float:
	_wobble_phase = fmod(_wobble_phase + delta / GameData.ZOMBIE_WOBBLE_PERIOD, 1.0)

	# 抖动衰减放在最前面推进，不受下面任何分支的 return 影响。
	# 之前把衰减写在攻击分支之后，结果"正在攻击时挨打"的丧尸
	# 抖动值永远不会归零，池化复用时会被下一只继承 —— 出池就自带一哆嗦。
	var shake := 0.0
	if _hurt_shake > 0.0:
		_hurt_shake = maxf(0.0, _hurt_shake - delta)
		shake = sin(_wobble_phase * TAU * 6.0) * GameData.ZOMBIE_HURT_SHAKE_AMP * _hurt_shake

	if _state == STATE_ATTACK:
		# 攻击时向前倾，而不是上下抖 —— 让"扑咬"这个动作更有方向感
		return -GameData.ZOMBIE_WOBBLE_AMP * 0.6 + shake

	return sin(_wobble_phase * TAU) * GameData.ZOMBIE_WOBBLE_AMP + shake


## LOD 用：视野外的丧尸整只藏起来。
##
## 为什么要在逻辑层手动藏，而不是靠引擎的视口剔除：
## 引擎剔除发生在渲染阶段，那时画布项的收集、z 排序、纹理绑定都已经做完了。
## 同屏 400 只、一多半在视野外时，把 visible 提前置 false 等于让它们
## 连渲染队列都进不去。
##
## 用标记位挡住重复赋值：visible 的 setter 会触发可见性通知并往上冒泡，
## 丧尸在分界线附近来回晃的时候，每帧一次无谓的通知也是白烧的 CPU。
func set_lod_hidden(hidden: bool) -> void:
	if hidden == _lod_hidden:
		return
	_lod_hidden = hidden
	visible = not hidden


## 与邻近丧尸的分离力。
## 返回的是各方向推力的**未归一化累加**（越挤推力越大），
## 由调用方乘权重后再与移动方向混合。
##
## 用限量查询而不是全量：格子里的候选顺序随插入顺序变，插入顺序又被生死回收的
## 交换删除不断打乱，所以"取前 N 个"在统计上等价于随机抽样。
## 分离力是短程力（只在双方半径之和内起作用），抽样完全够用 ——
## 但这一改把最坏情况的 O(n²) 压成了 O(n·16)。
func _separation(grid: SpatialHash) -> Vector2:
	var push := Vector2.ZERO
	# 结果写进 _sep_buf（自己的复用数组），而不是让哈希新建一个返回。
	# 这一处改动把"每只丧尸每帧一次堆分配"变成了"每个丧尸终身一次"。
	grid.query_radius_limited_into(position, radius * 2.0, GameData.SEPARATION_NEIGHBOR_CAP, _sep_buf)

	# 提到循环外：下面每条分支都要用，别每次去读一遍成员变量。
	var my_pos := position
	var my_radius := radius

	for other in _sep_buf:
		if other == self:
			continue

		var diff := my_pos - other.position
		var min_dist := my_radius + other.radius

		# **先算距离，再判 solid** —— 这个顺序是省下来的关键。
		# 候选是按格子给的，查询半径只有 24px 而格子有 96px，
		# 所以大部分候选其实在 24px 外，它们在这里就被丢掉了。
		# 把 solid 检查放在前面的话，等于为这些根本不重叠的邻居也读一次属性。
		var d2 := diff.length_squared()
		if d2 >= min_dist * min_dist:
			continue

		# 真到了这一步说明确实重叠。尸体此时已经退出碰撞(solid=false)，
		# 不该再互相推 —— 否则打完一堆尸体后会看到活丧尸被"尸体"顶开。
		if not other.solid:
			continue

		var d := sqrt(d2)
		if d < 0.001:
			# 完全重叠：必须给一个方向，否则两只会永远黏在一起。
			#
			# 用实例 id 生成确定性方向，而不是 randf_range ——
			# 后者会消耗全局随机数，而分离的计算次数会随 LOD 设置变化，
			# 于是"消耗了几个随机数"也跟着变，后面所有随机序列全错位，
			# 固定种子跑出来的两局就不再可比了。
			# 实例 id 在池化复用后不变，所以这个方向对同一只丧尸恒定，也够用。
			diff = Vector2.RIGHT.rotated(float(get_instance_id() & 7) * 0.7853982)
			d = 1.0

		# 合并成一次向量乘法：diff/d * (1 - d/min_dist) == diff * ((1 - d/min_dist) / d)
		# 原来是"先除再乘"，两个向量运算；现在只剩一个。
		push += diff * ((1.0 - d / min_dist) / d)

	return push


func _do_attack(delta: float, player: Node2D) -> void:
	_attack_cd -= delta

	# 攻击动画播完 → 回到站立姿态等冷却
	if _state == STATE_ATTACK and not _anim.is_playing():
		_state = STATE_WALK
		_play(STATE_WALK)

	if _attack_cd > 0.0:
		return

	_attack_cd = GameData.ZOMBIE_ATTACK_INTERVAL
	_state = STATE_ATTACK
	_play(STATE_ATTACK, true)   # 强制从头播，否则第二下攻击会停在上一轮的末帧
	player.take_damage(damage)


## ---------------------------------------------------------------- 受伤 / 死亡

func take_damage(amount: float) -> void:
	if not alive:
		return
	hp -= amount
	_flash_left = 0.075
	Events.enemy_hurt.emit(position, amount)

	if hp > 0.0:
		_state = STATE_HURT
		_stagger = GameData.ZOMBIE_HURT_STAGGER
		# 受击抖动强度按"这一击占它多少血"给，而不是恒定值：
		# 打坦克一枪它几乎不抖，打残血小怪一枪它抖得厉害 —— 手感信息量更大。
		_hurt_shake = clampf(amount / maxf(max_hp, 0.001), 0.25, 1.0)
		_play(STATE_HURT)
	else:
		_start_death()


func _start_death() -> void:
	alive = false
	solid = false          # 立刻退出碰撞与索敌，尸体不再挡子弹
	z_index = -1           # 降到活丧尸之下
	_state = STATE_DEAD
	_play(STATE_DEAD)
	_death_timer = GameData.ZOMBIE_DEATH_LINGER
	Events.enemy_killed.emit(position, xp_value, is_elite)
	if world != null:
		world.on_zombie_killed(self)
	queue_redraw()


## ---------------------------------------------------------------- 内部

func _play(anim: String, restart: bool = false) -> void:
	if _anim.sprite_frames == null or not _anim.sprite_frames.has_animation(anim):
		return
	if anim == _current_anim and not restart:
		return
	_current_anim = anim
	_anim.play(anim)


## 掉血比例，精英用来画血条
func hp_ratio() -> float:
	return clampf(hp / maxf(max_hp, 0.001), 0.0, 1.0)


func _draw() -> void:
	if not is_elite or not alive:
		return
	var width := 72.0 if is_boss else 42.0
	# 首领的 -142 与 GameData.BOSS_TARGET_HEIGHT 是一对，不能单独改：
	# 110px 高的首领头顶在 -110，血条下沿 -137 正好留出 27px 空隙，
	# 与精英（头顶 -66.8、血条 -102、空隙 30px）的观感一致。
	# 当初这句和首领的缩放是分别写的，缩放沿着了 128px 帧的公式，
	# 于是首领被画成 817px 高 —— 血条反而插进了身体中部。
	var y := -78.0 if is_boss else -52.0
	draw_rect(Rect2(-width * 0.5, y, width, 5.0), Color(0.08, 0.04, 0.05, 0.9), true)
	var hp_col := Color("#c93c35") if is_boss else (Color("#ff6b5e") if elite_kind == 0 else (Color("#e9a14e") if elite_kind == 1 else Color("#65e887")))
	draw_rect(Rect2(-width * 0.5, y, width * hp_ratio(), 5.0), hp_col, true)
	draw_rect(Rect2(-width * 0.5 - 1.0, y - 1.0, width + 2.0, 7.0), Color(1.0, 0.78, 0.36, 0.75), false, 1.0)
	draw_circle(Vector2(0.0, y - 5.0), 2.0, Color("#ffd35c"))
	if is_boss:
		draw_arc(Vector2.ZERO, radius + 24.0, 0.0, TAU, 40, Color(1.0, 0.18, 0.12, 0.30), 3.0, true)
	if _elite_windup > 0.0:
		var pulse := 0.65 + 0.35 * sin(_elite_windup * 28.0)
		var warning := Color(1.0, 0.18, 0.10, pulse)
		draw_arc(Vector2.ZERO, radius + 8.0, 0.0, TAU, 28, warning, 3.0, true)
		draw_arc(Vector2.ZERO, radius + 14.0, 0.0, TAU, 28, Color(1.0, 0.5, 0.2, pulse * 0.55), 2.0, true)
	if elite_kind == 2 and _elite_aura_cd > 0.0:
		draw_arc(Vector2.ZERO, radius + 18.0, 0.0, TAU, 32, Color(0.30, 1.0, 0.40, 0.25), 2.0, true)
