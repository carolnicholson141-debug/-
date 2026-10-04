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

## ---- 阶段1：行为怪状态 ----
## 行为标签，来自 variant["behavior"]：
##   "" 普通追击 / "ripper" 撕裂者(扑咬) / "spitter" 喷吐者(远程+拉扯)
##   / "smasher" 重锤(砸地) / "drowned" 溺亡者(水域怪，速度随水况)
## 空串走原有路径，对存量五种丧尸零开销。
var behavior: String = ""

## 撕裂者扑咬参数（variant["lunge"] 的拷贝）与运行时状态。
var _lunge: Dictionary = {}
var _lunge_cd: float = 0.0
var _lunge_windup: float = 0.0
var _lunge_dash_left: float = 0.0
var _lunge_dir: Vector2 = Vector2.ZERO
var _lunge_hit: bool = false

## 重锤砸地参数与状态。windup > 0 时脚下画扩散红圈（见 _draw）。
var _slam: Dictionary = {}
var _slam_cd: float = 0.0
var _slam_windup: float = 0.0
## 砸地命中后的冲击波显示计时（>0 时 _draw 画扩散环）。
var _slam_flash: float = 0.0

## 外部速度修正（水域减速等），由 Main 每帧写入，默认 1.0。
## 乘在移动积分上而不是 speed 上，出池重置为 1 即可，不污染 wave 速度倍率。
var speed_scale: float = 1.0

## 水况速度倍率（阶段3）。普通怪由 Main 直接写 speed_scale；
## 溺亡者按"在水中/离水"取不同值，Main 读这两个字段。
## 出池时从变体表灌入，普通变体恒为 1.0。
var water_speed_mult: float = 1.0
var land_speed_mult: float = 1.0

## ---- 阶段1：Boss 状态 ----
## 当前阶段（1/2/3）。血量比例越过 GameData.BOSS_PHASE_*_AT 时升阶段。
var boss_phase: int = 1
## 出池时的基准速度。升阶段的速度加成乘在它上面，
## 不然波次速度倍率一变，阶段加成的基数就漂了。
var _boss_base_speed: float = 0.0
var _boss_summon_cd: float = 0.0
var _boss_charge_cd: float = 0.0
var _boss_windup: float = 0.0
var _boss_charge_left: float = 0.0
var _boss_charge_dir: Vector2 = Vector2.ZERO
var _boss_slam_windup: float = 0.0

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
	# ---- 阶段1：行为怪与 Boss 的出池重置 ----
	# 池化铁律：这些状态上一只可能用过，漏一项就会出现
	# "刚刷出来的撕裂者原地冲一刀"这类池化脏状态 bug。
	behavior = String(variant.get("behavior", ""))
	_lunge = variant.get("lunge", {})
	_lunge_cd = 1.2 if not _lunge.is_empty() else 0.0
	_lunge_windup = 0.0
	_lunge_dash_left = 0.0
	_lunge_dir = Vector2.ZERO
	_lunge_hit = false
	_slam = variant.get("slam", {})
	_slam_cd = 1.5 if not _slam.is_empty() else 0.0
	_slam_windup = 0.0
	_slam_flash = 0.0
	speed_scale = 1.0
	# 水况倍率：只有溺亡者的变体表带了这两个键，其余读默认 1.0。
	water_speed_mult = float(variant.get("water_speed_mult", 1.0))
	land_speed_mult = float(variant.get("land_speed_mult", 1.0))
	boss_phase = 1
	_boss_summon_cd = GameData.BOSS_SUMMON_INTERVAL * 0.6
	_boss_charge_cd = float(GameData.BOSS_PHASE_CHARGE_CD[0])
	_boss_windup = 0.0
	_boss_charge_left = 0.0
	_boss_charge_dir = Vector2.ZERO
	_boss_slam_windup = 0.0
	# 首领的阶段速度加成乘在"出池那刻"的速度上，先记基准。
	_boss_base_speed = speed
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
		# 首领用阶段2 自制素材（256px 画布、内容 120px 高、脚底贴底）。
		# 缩放 = 目标屏幕高 ÷ 内容高，随素材尺寸自动换算，不再写死倍率；
		# 锚点 = 画布半径取负，脚底落在节点原点 —— 与 Kenney 帧同一口径。
		var boss_info: Dictionary = GameData.MONSTER_SPRITES.get("boss_abomination", {})
		var content_h := maxf(float(boss_info.get("content_h", 43.0)), 1.0)
		var boss_scale := GameData.BOSS_TARGET_HEIGHT / content_h
		_anim.scale = Vector2(boss_scale, boss_scale)
		_base_offset = Vector2(0.0, -float(boss_info.get("canvas", 64.0)) * 0.5)
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
	# 首领出池就把满血血量广播给 HUD 的首领血条（HUD 常驻连接，时序安全）。
	if p_boss:
		Events.boss_health_changed.emit(hp, max_hp)

## 按变体种类挑帧源。
##
## 优先级：首领 → 阶段2 自制素材（variant["sprite"]）→ 精英表 → Kenney 通用帧。
## 自制素材是单帧 SpriteFrames，动画活性由 wobble/闪白/翻转承担（见 GameData.monster_frames）。
##
## 历史背景：工程里曾有按 variant["sheet"]/["sequence"] 分派 CraftPix 横条表
## 和 gunner 序列帧的路径，素材弃用后这两条分支已删。
func _frames_for(_variant: Dictionary, p_boss: bool, p_elite: bool) -> SpriteFrames:
	if p_boss:
		return _boss_frames()
	var sprite_key := String(variant.get("sprite", ""))
	if sprite_key != "" and GameData.MONSTER_SPRITES.has(sprite_key):
		return GameData.monster_frames(sprite_key)
	if p_elite:
		return GameData.elite_zombie_frames()
	return GameData.kenney_zombie_frames()


func _boss_frames() -> SpriteFrames:
	if _boss_frames_cache != null:
		return _boss_frames_cache
	_boss_frames_cache = GameData.monster_frames("boss_abomination")
	return _boss_frames_cache


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

	# 砸地冲击波的显示计时。放在最前面推进，不受下面任何分支 return 影响
	# （与 _wobble_offset 里 hurt_shake 的处理同一理由）。
	if _slam_flash > 0.0:
		_slam_flash = maxf(0.0, _slam_flash - delta)

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

	# 首领专属：阶段推进 + 冲锋/召唤/震地。返回 true 表示本帧被技能接管。
	if is_boss and _tick_boss(delta, to_player, dist2, player):
		return
	if is_elite and not is_boss and _tick_elite_skill(delta, to_player, dist2, player):
		return
	if is_elite and elite_kind == 2:
		_elite_aura_cd = maxf(0.0, _elite_aura_cd - delta)
		if dist2 <= 125.0 * 125.0 and _elite_aura_cd <= 0.0:
			_elite_aura_cd = 1.35
			player.take_damage(damage * 0.72)
			queue_redraw()

	# ---- 阶段1 行为怪：被技能接管时跳过普通移动 ----
	match behavior:
		"ripper":
			if _tick_lunge(delta, to_player, dist2, player):
				return
		"smasher":
			if _tick_slam(delta, to_player, dist2, player):
				return
		_:
			pass

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
	# 喷吐者被贴脸时倒着拉开距离 —— 全游戏唯一会倒退走的丧尸。
	# 只在"进入攻击距离之前"的近距段生效，真贴到咬人距离就走普通追击。
	if behavior == "spitter":
		var kite := float(variant.get("kite_dist", 190.0))
		if dist2 < kite * kite:
			desired = -desired * 0.85
	var separation := _sep_cache.limit_length(1.0)
	var steer := (desired + separation * GameData.SEPARATION_WEIGHT).normalized()

	position += steer * speed * speed_scale * delta
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


## ---------------------------------------------------------------- 阶段1：行为怪技能
##
## 三个技能共用同一套"蓄力→爆发→冷却"三段式骨架：
## 蓄力期间返回 true（本帧跳过普通移动），爆发帧一次性结算，
## 之后回到普通追击直到冷却转好。预警全靠蓄力本身的视觉信号
## （泛红 / 脚下红圈），不额外开新信号 —— 玩家靠观察躲，不靠 UI 轰炸。

## 撕裂者：扑咬。中距离先停 windup 秒（泛红），然后朝锁定方向冲 dash 秒，
## 冲刺途中碰到玩家结算一次伤害。方向锁定在蓄力结束那一刻，横移可躲。
func _tick_lunge(delta: float, to_player: Vector2, dist2: float, player: Node2D) -> bool:
	if _lunge.is_empty():
		return false
	_lunge_cd = maxf(0.0, _lunge_cd - delta)

	if _lunge_windup > 0.0:
		_lunge_windup -= delta
		_anim.modulate = _base_tint.lerp(Color("#ff8fa0"), 0.5)
		if _lunge_windup <= 0.0:
			_lunge_dash_left = float(_lunge["dash"])
			_lunge_dir = to_player.normalized() if dist2 > 0.001 else Vector2.RIGHT
			_lunge_hit = false
		return true

	if _lunge_dash_left > 0.0:
		_lunge_dash_left -= delta
		position += _lunge_dir * speed * float(_lunge["dash_mult"]) * delta
		_anim.flip_h = _lunge_dir.x < -0.05
		_anim.modulate = _base_tint
		if not _lunge_hit and player.alive:
			var hit_range := radius + GameData.PLAYER_RADIUS + 6.0
			if position.distance_squared_to(player.position) <= hit_range * hit_range:
				_lunge_hit = true
				player.take_damage(damage * float(_lunge["damage_mult"]))
		return true

	if _lunge_cd > 0.0:
		return false
	var rmin := float(_lunge["range_min"])
	var rmax := float(_lunge["range_max"])
	if dist2 < rmin * rmin or dist2 > rmax * rmax:
		return false
	_lunge_cd = float(_lunge["cooldown"])
	_lunge_windup = float(_lunge["windup"])
	return true


## 重锤：砸地。贴身时蓄力 windup 秒（脚下扩散红圈，见 _draw），落锤时
## 半径内结算 AoE。重型怪的受击不硬直（见 take_damage），所以蓄力只能打断它。
func _tick_slam(delta: float, to_player: Vector2, dist2: float, player: Node2D) -> bool:
	if _slam.is_empty():
		return false
	_slam_cd = maxf(0.0, _slam_cd - delta)

	if _slam_windup > 0.0:
		_slam_windup -= delta
		_anim.modulate = _base_tint.lerp(Color("#ffb06b"), 0.4)
		queue_redraw()
		if _slam_windup <= 0.0:
			_anim.modulate = _base_tint
			_slam_flash = 0.25
			var hit := float(_slam["radius"])
			if player.alive and position.distance_squared_to(player.position) <= hit * hit:
				player.take_damage(damage * float(_slam["damage_mult"]))
			Events.blade_hit.emit(position)
		return true

	if _slam_cd > 0.0:
		return false
	var trigger := float(_slam["trigger"])
	if dist2 > trigger * trigger:
		return false
	_slam_cd = float(_slam["cooldown"])
	_slam_windup = float(_slam["windup"])
	return true


## 首领：三阶段战斗循环。
##   阶段1 追击 + 中距离冲锋（有蓄力红光预警，复用 elite_charge_warning）；
##   阶段2 提速、冲锋更频繁，开始周期性召唤普通丧尸（走 main 的刷怪通道）；
##   阶段3 狂暴：再提速、贴身解锁震地 AoE（脚下红圈预警）。
## 返回 true 表示本帧被技能接管（蓄力/冲刺/震地期间不走普通移动）。
func _tick_boss(delta: float, to_player: Vector2, dist2: float, player: Node2D) -> bool:
	_update_boss_phase()
	_boss_charge_cd = maxf(0.0, _boss_charge_cd - delta)
	_boss_summon_cd = maxf(0.0, _boss_summon_cd - delta)

	# 阶段2+：周期召唤。走 world.on_boss_summon 让 Main 用对象池正常刷，
	# 数量计入 MAX_ALIVE，不会绕过全局上限。
	if boss_phase >= 2 and _boss_summon_cd <= 0.0 and world != null:
		_boss_summon_cd = GameData.BOSS_SUMMON_INTERVAL
		world.on_boss_summon(GameData.BOSS_SUMMON_COUNT, position)

	# 冲刺进行中：直线碾压，撞到玩家结算一次。
	if _boss_charge_left > 0.0:
		_boss_charge_left -= delta
		position += _boss_charge_dir * speed * 3.0 * delta
		_anim.rotation = sin(_boss_charge_left * 40.0) * 0.05
		queue_redraw()
		if player.alive:
			var hit_range := radius + GameData.PLAYER_RADIUS + 8.0
			if position.distance_squared_to(player.position) <= hit_range * hit_range:
				player.take_damage(damage * 1.5)
				_boss_charge_left = 0.0
				_anim.rotation = 0.0
		return true

	# 冲锋蓄力中：泛红 + 锁定方向。
	if _boss_windup > 0.0:
		_boss_windup -= delta
		_anim.modulate = _base_tint.lerp(Color("#ff6b5e"), 0.45)
		queue_redraw()
		if _boss_windup <= 0.0:
			_boss_charge_left = ELITE_CHARGE_DURATION
			_boss_charge_dir = to_player.normalized() if dist2 > 0.001 else Vector2.RIGHT
			_anim.modulate = _base_tint
		return true

	# 震地进行中（阶段3）。
	if _boss_slam_windup > 0.0:
		_boss_slam_windup -= delta
		queue_redraw()
		if _boss_slam_windup <= 0.0:
			_slam_flash = 0.3
			var hit := float(GameData.BOSS_SLAM["radius"])
			if player.alive and position.distance_squared_to(player.position) <= hit * hit:
				player.take_damage(damage * float(GameData.BOSS_SLAM["damage_mult"]))
			Events.blade_hit.emit(position)
		return true

	_slam_cd = maxf(0.0, _slam_cd - delta)
	if boss_phase >= 3 and _slam_cd <= 0.0:
		var trigger := float(GameData.BOSS_SLAM["trigger"])
		if dist2 <= trigger * trigger:
			_slam_cd = 5.0
			_boss_slam_windup = float(GameData.BOSS_SLAM["windup"])
			return true

	# 发起冲锋：全阶段可用，冷却随阶段缩短。
	if _boss_charge_cd <= 0.0 and dist2 >= 120.0 * 120.0 and dist2 <= 560.0 * 560.0:
		_boss_charge_cd = float(GameData.BOSS_PHASE_CHARGE_CD[boss_phase - 1])
		_boss_windup = ELITE_CHARGE_WINDUP
		Events.elite_charge_warning.emit(position)
		queue_redraw()
		return true

	return false


## 血量比例越过阈值时升阶段：提速、换警示色、广播事件。
## 阶段只升不降（血量不会回涨，但用绝对判断写成幂等，防御未来加治疗）。
func _update_boss_phase() -> void:
	var ratio := hp_ratio()
	var new_phase := 3 if ratio <= GameData.BOSS_PHASE_3_AT else (2 if ratio <= GameData.BOSS_PHASE_2_AT else 1)
	if new_phase == boss_phase:
		return
	boss_phase = new_phase
	speed = _boss_base_speed * float(GameData.BOSS_PHASE_SPEED[boss_phase - 1])
	# 狂暴化视觉：底色往血红偏一档。_base_tint 在出池时重算，池化安全。
	_base_tint = _base_tint.lerp(Color(0.85, 0.20, 0.16), 0.22)
	_anim.modulate = _base_tint
	Events.boss_phase_changed.emit(boss_phase, position)
	queue_redraw()


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
	# 首领血条必须跟着掉。这条广播原先只在出池那一刻发过一次，
	# 结果是 HUD 底部的首领血条整场停在满血（阶段标签会变、血条纹丝不动），
	# 只有怪头顶那条自己 _draw 的血条在动。
	if is_boss:
		Events.boss_health_changed.emit(maxf(hp, 0.0), max_hp)

	if hp > 0.0:
		_hurt_shake = clampf(amount / maxf(max_hp, 0.001), 0.25, 1.0)
		# 重锤是重型单位：受击抖动保留（反馈还在），但不进硬直、不切 hurt 状态 ——
		# 否则它会被任何 DPS 永久钉在原地，"最肉的怪"就名不副实了。
		if behavior != "smasher":
			_state = STATE_HURT
			_stagger = GameData.ZOMBIE_HURT_STAGGER
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
	if is_boss:
		# 首领掉落走独立事件：HUD 收血条、Main 撒奖励，都从这一声分开。
		Events.boss_defeated.emit(position)
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
	if not alive:
		return

	# ---- 砸地预警 / 冲击波（重锤与阶段3首领共用）----
	# 这两个状态各自在 windup/flash 期间才 queue_redraw，普通丧尸不会走到这里。
	if _slam_windup > 0.0 or _boss_slam_windup > 0.0:
		var is_own: bool = _slam_windup > 0.0
		var total: float = float(_slam["windup"]) if is_own else float(GameData.BOSS_SLAM["windup"])
		var left: float = _slam_windup if is_own else _boss_slam_windup
		var warn_r: float = float(_slam["radius"]) if is_own else float(GameData.BOSS_SLAM["radius"])
		var t := 1.0 - clampf(left / maxf(total, 0.001), 0.0, 1.0)
		var pulse := 0.55 + 0.45 * sin(left * 26.0)
		# 内圈随蓄力进度扩张到伤害半径，外圈恒定提示边界 —— 一眼能读出"躲到圈外"。
		draw_arc(Vector2.ZERO, warn_r * (0.3 + 0.7 * t), 0.0, TAU, 32,
			Color(1.0, 0.22, 0.1, 0.3 + 0.45 * pulse * t), 3.0, true)
		draw_arc(Vector2.ZERO, warn_r, 0.0, TAU, 32, Color(1.0, 0.3, 0.15, 0.18 + 0.45 * t), 2.0, true)
	if _slam_flash > 0.0:
		var fade := clampf(_slam_flash / 0.3, 0.0, 1.0)
		draw_arc(Vector2.ZERO, (1.0 - fade) * 150.0, 0.0, TAU, 36,
			Color(1.0, 0.6, 0.2, 0.5 * fade), 4.0, true)

	if not is_elite:
		return

	# ---- 精英/首领血条 ----
	var width := 72.0 if is_boss else 42.0
	# 首领血条 y 与首领屏幕高是一对：内容 120px × 缩放后正好等于
	# BOSS_TARGET_HEIGHT(110)——头顶在 -110，血条（高 5px）下沿 -118，
	# 留 6px 空隙，与精英的观感一致。（原 -78/-123 是旧素材时代的校准值。）
	var y := (-GameData.BOSS_TARGET_HEIGHT - 12.0) if is_boss else -52.0
	draw_rect(Rect2(-width * 0.5, y, width, 5.0), Color(0.08, 0.04, 0.05, 0.9), true)
	var hp_col := Color("#c93c35") if is_boss else (Color("#ff6b5e") if elite_kind == 0 else (Color("#e9a14e") if elite_kind == 1 else Color("#65e887")))
	draw_rect(Rect2(-width * 0.5, y, width * hp_ratio(), 5.0), hp_col, true)
	draw_rect(Rect2(-width * 0.5 - 1.0, y - 1.0, width + 2.0, 7.0), Color(1.0, 0.78, 0.36, 0.75), false, 1.0)
	draw_circle(Vector2(0.0, y - 5.0), 2.0, Color("#ffd35c"))
	if is_boss:
		draw_arc(Vector2.ZERO, radius + 24.0, 0.0, TAU, 40, Color(1.0, 0.18, 0.12, 0.30), 3.0, true)
		# 阶段3 狂暴环：一圈红色脉冲，和 HUD 的阶段提示互相印证。
		if boss_phase >= 3:
			var rage := 0.3 + 0.25 * sin(Time.get_ticks_msec() * 0.009)
			draw_arc(Vector2.ZERO, radius + 30.0, 0.0, TAU, 40, Color(1.0, 0.14, 0.08, rage), 3.5, true)
	if _elite_windup > 0.0:
		var pulse2 := 0.65 + 0.35 * sin(_elite_windup * 28.0)
		var warning := Color(1.0, 0.18, 0.10, pulse2)
		draw_arc(Vector2.ZERO, radius + 8.0, 0.0, TAU, 28, warning, 3.0, true)
		draw_arc(Vector2.ZERO, radius + 14.0, 0.0, TAU, 28, Color(1.0, 0.5, 0.2, pulse2 * 0.55), 2.0, true)
	if elite_kind == 2 and _elite_aura_cd > 0.0:
		draw_arc(Vector2.ZERO, radius + 18.0, 0.0, TAU, 32, Color(0.30, 1.0, 0.40, 0.25), 2.0, true)
