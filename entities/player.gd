extends Node2D
## 玩家角色。
##
## 架构选择：**不用 CharacterBody2D，不用任何物理体**。
## 移动是手工积分（position += dir * speed * delta），碰撞全部交给 SpaceHash 判定。
## 理由：割草游戏同屏几百个动态对象，Godot 物理引擎的 broadphase 和
## move_and_slide 开销是主要瓶颈；而这些碰撞其实都是简单的圆-圆判定，
## 自己算比走引擎快一个数量级，而且行为完全可控（不会出现丧尸被挤飞）。
##
## 本节点由 Main 统一驱动 tick()，不自己开 _process —— 保证更新顺序确定。

## 运行时属性表，开局从 GameData.PLAYER_BASE_STATS 复制一份
var stats: Dictionary = {}

var hp: float = 0.0
var level: int = 1
var xp: float = 0.0
var xp_required: float = 0.0

var alive: bool = true
var kills: int = 0
var inventory: Dictionary = {"grenade": 0, "potion": 0}
var inventory_slots: Array[String] = []
var inventory_capacity := 2
var _dodge_left := 0.0

## 朝向，用于画枪口方向
var _facing: Vector2 = Vector2.RIGHT
## 精灵当前是否朝左（= AnimatedSprite2D.flip_h）。
## 与 _facing 分开：_facing 跟着鼠标/目标任意转、带竖直分量，
## 而这个只在水平分量足够大时才更新 —— 见 _update_face_left()。
var _face_left: bool = false
## 受击无敌倒计时
var _invuln: float = 0.0
## 上一帧是否处于无敌，用于判断要不要重绘
var _was_flashing: bool = false
## 序列帧动画：精灵帧来自 assets/characters/player/sequence/（12 套动作）。
var _visual_time: float = 0.0
var _attack_flash: float = 0.0
## 开火后维持"射击姿态"的倒计时。见 GameData.PLAYER_FIRE_HOLD。
## 不再用固定值：每次开火按当前真实射速（stats.cooldown）动态设，
## 这样升级射速后动作节奏跟着变，不会"子弹打得飞快、动作还慢半拍"。
var _fire_hold: float = 0.0
## 后坐力的方向（开火反方向），用于把角色往后顶一下而非只上移。
## 存下来是因为 _update_visual 是纯视觉帧、拿不到开火事件里的方向。
var _recoil_dir: Vector2 = Vector2.ZERO
var _camera_shake_left: float = 0.0
var _camera_shake_strength: float = 0.0
var _camera_shake_time: float = 0.0
## 脚底落在节点原点这件事交给 AnimatedSprite2D.offset（见 player.tscn），
## 所以基准位置恒为零；bob / 后坐都在它之上叠加。
var _hero_base_pos := Vector2.ZERO
## 在 _ready() 里从 GameData.PLAYER_SPRITE_SCALE 取，不在这里写字面量 ——
## 缩放值属于"可调数值"，按工程约定只能有一个来源。
var _hero_base_scale := Vector2.ONE
## 当前播放的动画名。SpriteFrames.play() 每帧调一次会把播放进度重置，
## 所以用它做短路，只有真的换了状态才 play()。空串 = 还没有状态。
var _anim_name: StringName = &""
## 是否处于奔跑状态。**toggle 切换**：按一下 Shift 进入奔跑、再按一下退回走路，
## 不是按住才跑 —— 这是玩家的明确要求（见 is_sprinting 与 _unhandled_input）。
## 与 is_action_pressed 的差别：这是个持久状态，松开 Shift 也不掉。
var _sprinting: bool = false

## 正在播的一次性动作（dodge / hurt / dead），空串 = 没有。
## 这期间**不切回循环状态**，也不叠加 bob —— 那些动作本身就是要看的，
## 叠上去会揉花；而且受击/闪避被打断会让打击反馈丢掉。
##
## 用"动作名"而不是 bool：受击动画要在每次挨打时**从头重播**，
## 而 dodge 与 hurt 的结束处理不一样（死亡动作永远不会结束）。
var _oneshot: StringName = &""

## 自动测试模式：非零时忽略键盘，直接用这个方向移动。
## 由 Main 在无头跑平衡测试时驱动，正常游戏时恒为零向量。
var autoplay_dir: Vector2 = Vector2.ZERO

## 本帧的移动输入缓存。由 _input_dir() 惰性填充、
## tick() 开头作废（见那里的注释：同帧内四次查询结果必然相同）。
var _move_dir: Vector2 = Vector2.ZERO
var _move_dir_cached: bool = false

## 由 Main 注入：返回当前应当朝向的方向（手动模式=鼠标方向）。
## 返回零向量表示"没有外部朝向要求"，此时退回跟随移动方向的默认行为。
## 用 Callable 而不是直接持有 InputController 引用，
## 是为了让玩家节点不需要知道"有输入控制器这回事"。
var aim_provider: Callable = Callable()

## 压力测试模式：完全不掉血。由 Main 的 `--stress` 参数设置，正常游戏恒为 false。
##
## 为什么压测必须无敌：420 只丧尸围着玩家会在两三秒内把人打死，
## 而玩家一死，全场就失去负载 —— 测出来的是"尸体堆了多久"，毫无意义。
var invincible: bool = false

## 外部速度修正（阶段3：水域减速）。由 Main 每帧写回，默认 1.0。
## 乘在移动积分上、不乘在闪避位移上 —— 闪避是爆发动作，不该被水面拖住。
var speed_scale: float = 1.0

@onready var camera: Camera2D = $Camera2D
@onready var hero_sprite: AnimatedSprite2D = $HeroSprite


func _ready() -> void:
	Events.weapon_fired.connect(_on_weapon_fired)
	_hero_base_scale = Vector2(GameData.PLAYER_SPRITE_SCALE, GameData.PLAYER_SPRITE_SCALE)
	if hero_sprite != null:
		hero_sprite.sprite_frames = GameData.player_frames()
		hero_sprite.animation_finished.connect(_on_anim_finished)
		# offset 在这里**从常量灌进来**，而不是信任 player.tscn 的字面量。
		# 素材换过一整套（192px 序列帧 -> 43px Kenney 角色），tscn 里那个
		# -96 是旧值，忘了改就会让角色浮空 —— 而这种 bug 光看代码很难发现，
		# 因为两处"看起来都是合理的偏移量"。单一数据源 + 运行时注入，
		# 保证改锚点只需要动 GameData 一处。
		hero_sprite.offset = GameData.PLAYER_SPRITE_OFFSET
	reset()


## 开新一局时调用，把状态恢复成初始值
func reset() -> void:
	stats = GameData.PLAYER_BASE_STATS.duplicate(true)
	hp = float(stats["max_hp"])
	level = 1
	xp = 0.0
	xp_required = GameData.xp_for_level(1)
	alive = true
	kills = 0
	inventory = {"grenade": 0, "potion": 0}
	inventory_slots = []
	inventory_capacity = 2
	_dodge_left = 0.0
	_facing = Vector2.RIGHT
	_face_left = false
	_sprinting = false
	_invuln = 0.0
	_move_dir = Vector2.ZERO
	_move_dir_cached = false
	revive_charges = 0
	_fire_hold = 0.0
	_recoil_dir = Vector2.ZERO
	speed_scale = 1.0
	_attack_flash = 0.0
	_camera_shake_left = 0.0
	_camera_shake_strength = 0.0
	_camera_shake_time = 0.0
	if camera != null:
		camera.offset = Vector2.ZERO
	if hero_sprite != null:
		hero_sprite.modulate = Color.WHITE
		hero_sprite.position = _hero_base_pos
		hero_sprite.scale = _hero_base_scale
		hero_sprite.flip_h = false
	position = Vector2.ZERO

	# 动画状态也必须重置。SpriteFrames.play() 在"动画名没变"时会直接返回，
	# 于是 _anim_name / _oneshot 不清的话，重开一局时会卡在上一局最后一个
	# 状态上不动（比如上一局死在 dodge 上，这局就永远站着不动）——
	# 和池化对象出池要逐项重置是同一个坑。
	_anim_name = &""
	_oneshot = &""
	_tick_anim()

	_apply_camera_limits()
	_emit_all()
	_emit_inventory()
	queue_redraw()


## ---------------------------------------------------------------- 每帧更新

func tick(delta: float) -> void:
	if not alive:
		return

	# 新的一帧：作废移动输入缓存，由本帧第一次 _input_dir() 重新采集。
	# 放在最前面，确保下面所有用到输入的地方都拿到同一份、且是本帧的。
	_move_dir_cached = false

	if _invuln > 0.0:
		_invuln = maxf(0.0, _invuln - delta)
	_dodge_left = maxf(0.0, _dodge_left - delta)
	_visual_time += delta
	_attack_flash = maxf(0.0, _attack_flash - delta)
	_fire_hold = maxf(0.0, _fire_hold - delta)
	_camera_shake_left = maxf(0.0, _camera_shake_left - delta)
	_camera_shake_time += delta
	if camera != null:
		var shake_ratio := _camera_shake_left / 0.16
		camera.offset = Vector2(
			sin(_camera_shake_time * 83.0) * _camera_shake_strength * shake_ratio,
			cos(_camera_shake_time * 71.0) * _camera_shake_strength * shake_ratio
		)

	_move(delta)
	_tick_anim()
	_update_visual(delta)
	if float(stats.get("attract_radius", 110.0)) > float(GameData.PLAYER_BASE_STATS.get("attract_radius", 110.0)) + 0.5:
		queue_redraw()

	# 无敌期间闪烁：每 0.16s 切换一次，只有状态真的变了才重绘
	var flashing := _invuln > 0.0
	if hero_sprite != null:
		hero_sprite.modulate = Color(1.0, 0.55, 0.55) if flashing and fmod(_invuln, 0.16) < 0.08 else Color.WHITE
	if flashing != _was_flashing or (flashing and fmod(_invuln, 0.16) < delta):
		_was_flashing = flashing
		queue_redraw()

	# 朝向。
	# 手动开火时枪口必须跟着鼠标 —— 否则玩家瞄了半天，枪管却指着别处，
	# 完全无法建立"我瞄的就是我打的"这个反馈，手动模式就废了。
	# 自动模式保持原逻辑：跟随移动方向，站定时保留上一次朝向。
	if aim_provider.is_valid():
		var aim: Vector2 = aim_provider.call()
		if aim.length_squared() > 0.0001 and aim != _facing:
			_facing = aim.normalized()
			_update_face_left(_facing)
			queue_redraw()
	else:
		var d := _input_dir()
		if d.length_squared() > 0.01:
			_facing = d.normalized()
			_update_face_left(_facing)
			queue_redraw()


## 由武器调用：索敌后把枪口转向目标。
## 站定时朝敌人、移动时朝移动方向 —— 这是 shooter 类游戏的通用观感。
func aim_at(dir: Vector2) -> void:
	if dir.length_squared() < 0.0001:
		return
	_facing = dir.normalized()
	_update_face_left(_facing)
	queue_redraw()


## 决定精灵朝左还是朝右。
##
## ⚠ 不要直接写 `flip_h = _facing.x < 0`。素材是**侧视图**，只有左右两种朝向，
## 而 _facing 是"瞄准/移动方向"、带着竖直分量：
##   - 往正上方走时 _facing.x == 0，`< 0` 为假 → 会突然变成面朝右；
##   - 鼠标移到头顶上方时同理，角色会左右乱闪。
## 所以只在水平分量足够大时才更新朝向；上下移动时**保持上一次的左右朝向**，
## 这也是侧视图素材在四方向移动游戏里的标准处理。
func _update_face_left(dir: Vector2) -> void:
	if absf(dir.x) < GameData.PLAYER_FACE_DEADZONE:
		return
	_face_left = dir.x < 0.0
	if hero_sprite != null:
		hero_sprite.flip_h = _face_left


## 枪口在世界坐标里的位置。子弹从这里发出，而不是从身体中心 ——
## 否则看起来像从脚底/肚子打出去（原来就是 player.position + 朝向前方 23px）。
##
## 偏移按**当前动画**取：枪在不同动作里举的高度差很多（站射在肩高、跑动压到腰侧，
## 差 39px ≈ 半个身高）。表里没有的动作退回默认值。
func muzzle_position() -> Vector2:
	var key := ""
	if hero_sprite != null:
		key = String(hero_sprite.animation)
	var off: Vector2 = GameData.PLAYER_MUZZLE_OFFSETS.get(
		key, GameData.PLAYER_MUZZLE_OFFSET_DEFAULT)
	if _face_left:
		off.x = -off.x
	return position + off


## 是否在奔跑。toggle 语义：由 Shift 的「刚按下」翻转（见 _unhandled_input），
## 而不是按住才跑。移速和动画都由此决定，见 GameData.PLAYER_SPRINT_MULT。
func is_sprinting() -> bool:
	if autoplay_dir != Vector2.ZERO:
		return false
	return _sprinting


## 处理 Shift 的点按：每按下一次，奔跑状态翻转一次。
## 用 _unhandled_input 而不是 is_action_just_pressed 在 tick 里轮询 ——
## tick 由 Main 手工驱动、且开局/暂停时可能不跑；而 _unhandled_input 是
## 引擎层的、只要没被 UI 吃掉就会触发，点按这个动作不该丢。
## 用 is_action_pressed（带刚按下检测）避免"长按 Shift"期间连续翻转：
## 按住不动只触发一次，松开再按才触发下一次。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("sprint") and not event.is_echo():
		_sprinting = not _sprinting



func _move(delta: float) -> void:
	var dir := _input_dir()
	if dir == Vector2.ZERO:
		return
	var speed := float(stats["move_speed"])
	if is_sprinting():
		speed *= GameData.PLAYER_SPRINT_MULT
	position += dir * speed * speed_scale * delta
	# 限制在场地内，防止跑出边界后刷怪环算错位置
	var lim := GameData.ARENA_HALF_SIZE
	position.x = clampf(position.x, -lim, lim)
	position.y = clampf(position.y, -lim, lim)


func _update_visual(_delta: float) -> void:
	if hero_sprite == null:
		return
	if _oneshot != &"":
		# 一次性动作（后跳 / 受击 / 倒地）自带位移和收势，叠加 bob 会揉花。
		hero_sprite.position = _hero_base_pos
		hero_sprite.scale = _hero_base_scale
		return
	var moving := _input_dir().length_squared() > 0.01
	var bob_speed := 11.0 if moving else 3.2
	var bob_amount := 2.2 if moving else 0.9
	var bob := sin(_visual_time * bob_speed) * bob_amount
	var squash := 1.0 + sin(_visual_time * bob_speed * 2.0) * (0.018 if moving else 0.008)
	# 后坐力：开火瞬间沿反方向顶一下，随 _attack_flash 衰减。
	# 以前是固定上移 2px，跟朝向无关 —— 侧视图里朝左开枪却往上跳很不协调。
	# 现在 _recoil_dir 由开火方向决定（左右枪反顶、上下枪上顶），幅度仍走原值 2px。
	var recoil_vec := Vector2.ZERO
	if _attack_flash > 0.0:
		var recoil_amount := 2.0 * (_attack_flash / 0.09)
		recoil_vec = _recoil_dir * recoil_amount
	hero_sprite.position = _hero_base_pos + Vector2(0.0, bob) + recoil_vec
	hero_sprite.scale = _hero_base_scale * Vector2(1.0 / squash, squash)


## ---------------------------------------------------------------- 动画

## 循环状态机：静止 → idle；移动 → walk；按住 Shift 移动 → run；
## 开火时在上面叠一层射击姿态（attack / attack_move）。
##
## 走和跑分两个动作而不是按速度快慢自动选：这套素材两套动作的步幅差得不多，
## 自动切会在临界速度上反复横跳。绑到 Shift 上反而清楚 ——
## 玩家按了就明显是"我在冲刺"，而且能自己控制要不要跑起来。
func _tick_anim() -> void:
	if hero_sprite == null or _oneshot != &"":
		return
	var moving := _input_dir().length_squared() > 0.01
	if _fire_hold > 0.0:
		if moving:
			_play(&"attack_move")
		else:
			_play(&"attack")
	elif moving:
		_play(&"run" if is_sprinting() else &"walk")
	else:
		_play(&"idle")


## 切循环动画。用 _anim_name 短路，避免每帧 play() 把播放进度重置回第 0 帧。
func _play(anim: StringName) -> void:
	if hero_sprite == null or _anim_name == anim:
		return
	var frames := hero_sprite.sprite_frames
	# 守卫必须存在：素材是分批补的，缺的目录会让 SpriteFrames 里少一个动画，
	# 直接 play() 会报 "animation not found"。
	if frames == null or not frames.has_animation(anim):
		return
	_anim_name = anim
	hero_sprite.play(anim)
	# 切到非攻击动作时，把播放倍速复位 —— 攻击时为了跟射速同频会调高 speed_scale，
	# 但那不该影响 walk/idle（否则走路动画也会被加速，观感抽搐）。
	# attack 动作的倍速由 _on_weapon_fired 单独控制，这里只负责"离开攻击时清零"。
	if anim != &"attack" and anim != &"attack_move":
		hero_sprite.speed_scale = 1.0


## 播一次性动作并上锁，播完（_on_anim_finished）才交还控制权。
##
## 刻意**不做**"同名就跳过"的短路：受击动画必须每次挨打都从头重播，
## 否则连续挨打时玩家看不到反馈，只觉得自己在挨打而角色没反应。
func _play_oneshot(anim: StringName) -> bool:
	if hero_sprite == null:
		return false
	var frames := hero_sprite.sprite_frames
	if frames == null or not frames.has_animation(anim):
		return false
	_oneshot = anim
	_anim_name = anim
	hero_sprite.play(anim)
	return true


func _on_anim_finished() -> void:
	if hero_sprite == null:
		return
	var done := hero_sprite.animation
	if done != _oneshot:
		return
	# 死亡动作播完不该回到站姿 —— 玩家已经死了，_tick_anim 也不该再切
	if done == &"dead":
		return
	_oneshot = &""
	_anim_name = &""
	_tick_anim()


func _on_weapon_fired() -> void:
	_attack_flash = 0.09
	# 射击姿态靠这个倒计时维持，必须长于开火间隔、否则连射时会闪回 idle。
	# 但这里**不再用固定 PLAYER_FIRE_HOLD**：升级射速后 cooldown 从 0.55s 一路降到
	# 0.07s，固定 0.62s 会让动作永远慢半拍（子弹已打 8 发、动作还停在一轮里）。
	# 改成"射速 × 1.2"，既保证连射时不闪回、又让动作节奏跟火力同频。
	var cd: float = float(stats.get("cooldown", GameData.PLAYER_BASE_STATS["cooldown"]))
	_fire_hold = cd * GameData.PLAYER_FIRE_HOLD_MULT
	# 后坐力方向 = 开火反方向（角色往后顶一下）。没有朝向时退回纯上移。
	_recoil_dir = -_facing if _facing.length_squared() > 0.0001 else Vector2.UP
	# 射速变快时加快攻击动画播放，让抬手动作跟得上子弹频率。
	# 0.55s 射速 -> 1x；0.07s 射速 -> 上限 2.2x（再快动作会糊成一团，封顶）。
	var base_cd: float = float(GameData.PLAYER_BASE_STATS["cooldown"])
	var speed_scale: float = clampf(base_cd / cd, 1.0, GameData.PLAYER_ATTACK_FPS_MAX_SCALE)
	if hero_sprite != null:
		hero_sprite.speed_scale = speed_scale


func _input_dir() -> Vector2:
	# 本帧的移动输入。tick() 开头采一次，供整帧复用。
	#
	# ⚠ 原来每次调用都重新跑一遍 Input.get_vector()，而 tick() 一帧里
	# 要问四次（_move / _tick_anim / _update_visual / 朝向）——
	# Input.get_vector 内部要走 InputMap 查找 + 四次动作状态查询 + 合成，
	# 一次不多，但四次就是四倍的固定开销，而**同一帧内结果必然相同**。
	# 缓存成"一帧一份"是安全的：输入在一帧内不会变，
	# 而需要立刻拿到最新值的路径（_unhandled_input）不读这个缓存。
	if _move_dir_cached:
		return _move_dir
	if autoplay_dir != Vector2.ZERO:
		_move_dir = autoplay_dir
	else:
		_move_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	_move_dir_cached = true
	return _move_dir


## ---------------------------------------------------------------- 受伤

func take_damage(amount: float) -> void:
	if not alive or _invuln > 0.0 or invincible:
		return
	hp = maxf(0.0, hp - amount)
	_invuln = float(stats["invuln_time"])
	_camera_shake_left = 0.16
	_camera_shake_strength = clampf(amount * 0.22, 2.5, 8.0)
	_was_flashing = true
	# 受击动作走一次性通道，它会**从头重播**并短暂锁住状态机 ——
	# 否则玩家一边挨打一边跑，动画会被 run 立刻盖掉，挨打完全没反馈。
	# 死亡时 _die() 会用 dead 覆盖掉它，所以这里不用特判。
	_play_oneshot(&"hurt")
	queue_redraw()
	Events.player_health_changed.emit(hp, float(stats["max_hp"]))
	Events.player_hurt.emit(position, amount)

	if hp <= 0.0:
		_die()

func dodge() -> bool:
	if not alive or _dodge_left > 0.0:
		return false
	var dir := _input_dir()
	if dir.length_squared() < 0.01:
		dir = _facing
	dir = dir.normalized()
	position += dir * float(stats.get("dodge_distance", 150.0))
	var lim := GameData.ARENA_HALF_SIZE
	position.x = clampf(position.x, -lim, lim)
	position.y = clampf(position.y, -lim, lim)
	_dodge_left = float(stats.get("dodge_cooldown", 2.2))
	_invuln = maxf(_invuln, 0.42)
	_camera_shake_left = 0.08
	_camera_shake_strength = 2.0

	# 位移仍然是瞬移 —— 玩法数值一行没动，动画只负责把"这一下"演出来。
	# 素材是 22 帧的后跳：起手就腾空带残影、落到收势，正好接在瞬移之后，
	# 读起来就是"窜出去、然后落地"。
	if not _play_oneshot(&"dodge"):
		# 素材缺失时不把状态卡死：没有 dodge 动画就当一次瞬移，
		# 否则 _oneshot 永远非空，玩家会定在原地不动。
		_oneshot = &""
		_anim_name = &""
		_tick_anim()

	queue_redraw()
	Events.player_dodged.emit(position)
	return true


func heal(amount: float) -> void:
	if not alive:
		return
	hp = minf(float(stats["max_hp"]), hp + amount)
	Events.player_health_changed.emit(hp, float(stats["max_hp"]))


func _die() -> void:
	# 复活药剂在倒下瞬间自动饮下。这里**必须**赶在 alive=false 之前拦截 ——
	# alive 一变 false，Main 那边就开始结算，整局就结束了。
	if revive_charges > 0:
		revive_charges -= 1
		Events.revive_changed.emit(revive_charges)
		hp = float(stats["max_hp"]) * GameData.REVIVE_HP_RATIO
		_invuln = GameData.REVIVE_INVULN
		# 打断正在播的死亡/受击动作，直接回到战斗姿态。
		_oneshot = &""
		_anim_name = &""
		_tick_anim()
		Events.player_health_changed.emit(hp, float(stats["max_hp"]))
		Events.player_revived.emit(position)
		return

	alive = false
	# 倒地动作不循环、也不会被 _on_anim_finished 清掉（见那里的 dead 特判）——
	# 玩家已经死了，不该再回到站姿。素材包里没有专门的死亡动作，
	# 用受伤2 顶替（见 GameData.PLAYER_SEQ_PLANS 的 dead 那行）。
	_play_oneshot(&"dead")
	# 只广播"我死了"这个事实。
	# 存活时长、击杀数这些要凑成一局总结，由 Main 负责组装 ——
	# 玩家节点不需要知道这一局跑了多久。
	Events.player_died.emit()


## ---------------------------------------------------------------- 经验与升级

func add_xp(amount: float) -> void:
	if not alive:
		return
	xp += amount

	var leveled := false
	while xp >= xp_required:
		xp -= xp_required
		level += 1
		xp_required = GameData.xp_for_level(level)
		leveled = true

	Events.player_xp_changed.emit(xp, xp_required)

	if leveled:
		Events.player_level_changed.emit(level)
		Events.level_up_requested.emit(level)


func register_kill(xp_value: float) -> void:
	kills += 1
	Events.kills_changed.emit(kills)
	add_xp(xp_value)

func add_item(item_id: String, amount: int = 1) -> void:
	for _i in amount:
		# **相同物品叠加**：同名物品共用一个格子，只涨计数；
		# 格子满了只拦"新种类"，已持有的种类仍能继续叠 ——
		# 否则会出现"手里有药水却捡不了同款药水"的怪相。
		if inventory_slots.has(item_id):
			inventory[item_id] = int(inventory[item_id]) + 1
			continue
		if inventory_slots.size() >= inventory_capacity:
			return
		inventory_slots.append(item_id)
		inventory[item_id] = int(inventory.get(item_id, 0)) + 1
	_emit_inventory()

## 复活药剂的被动充能。不进行囊、不能用数字键"使用" ——
## 对着一具尸体喝复活药没有意义，它就该在倒下瞬间自动生效。
## 商店购买后由 Main 在开局时注入。
var revive_charges := 0

func add_revive_charge(amount: int = 1) -> void:
	revive_charges += maxi(0, amount)
	Events.revive_changed.emit(revive_charges)

func unlock_inventory_slot() -> bool:
	if inventory_capacity >= 5:
		return false
	inventory_capacity += 1
	_emit_inventory()
	return true

func use_slot(slot_index: int) -> bool:
	if not alive or slot_index < 0 or slot_index >= inventory_slots.size():
		return false
	var item_id := inventory_slots[slot_index]
	inventory[item_id] = maxi(0, int(inventory.get(item_id, 0)) - 1)
	# 叠加制：用完最后一个才释放格子，否则一个格子永远占着 0 个物品。
	if int(inventory[item_id]) <= 0:
		inventory.erase(item_id)
		inventory_slots.remove_at(slot_index)
	_emit_inventory()
	Events.item_used.emit(item_id, position)
	return true

func _emit_inventory() -> void:
	var snapshot := inventory.duplicate()
	snapshot["_slots"] = inventory_slots.duplicate()
	snapshot["_capacity"] = inventory_capacity
	Events.inventory_changed.emit(snapshot)


## ---------------------------------------------------------------- 升级应用

## 由 UpgradeSystem 调用。op 为 "add" 或 "mul"。
func apply_upgrade(upgrade: Dictionary) -> void:
	var stat := String(upgrade["stat"])
	var value := float(upgrade["value"])
	var op := String(upgrade["op"])

	if not stats.has(stat):
		push_warning("升级引用了不存在的属性：%s" % stat)
		return

	var current := float(stats[stat])
	if op == "add":
		current += value
	elif op == "mul":
		current *= value
	else:
		push_warning("未知的 op：%s" % op)
		return

	# 夹到下限，避免「开火间隔 -18%」叠十次之后变成负数
	if GameData.STAT_FLOOR.has(stat):
		current = maxf(current, float(GameData.STAT_FLOOR[stat]))
	stats[stat] = current

	# 附带影响的属性（例如「磁场手套」同时加拾取半径和吸附半径）
	if upgrade.has("also"):
		var also: Dictionary = upgrade["also"]
		for key: String in also:
			if stats.has(key):
				stats[key] = float(stats[key]) * float(also[key])

	if bool(upgrade.get("heal", false)):
		heal(value)

	Events.player_health_changed.emit(hp, float(stats["max_hp"]))
	Events.upgrade_applied.emit(upgrade)


## ---------------------------------------------------------------- 内部

func _apply_camera_limits() -> void:
	if camera == null:
		return
	var lim := GameData.ARENA_HALF_SIZE
	camera.limit_left = int(-lim)
	camera.limit_right = int(lim)
	camera.limit_top = int(-lim)
	camera.limit_bottom = int(lim)


func _emit_all() -> void:
	Events.player_health_changed.emit(hp, float(stats["max_hp"]))
	Events.player_xp_changed.emit(xp, xp_required)
	Events.player_level_changed.emit(level)
	Events.kills_changed.emit(kills)


## ---------------------------------------------------------------- 绘制

## 用 _draw() 画占位形象，完全不依赖素材。
## 以后有正式角色图了，把这个节点的绘制去掉、换成 AnimatedSprite2D 即可，
## 玩法代码一行都不用改。
func _draw() -> void:
	var r := GameData.PLAYER_RADIUS
	var has_art := hero_sprite != null and hero_sprite.sprite_frames != null

	# 地面阴影（压扁的椭圆），让角色在纯色地面上有立体感。
	# 有正式素材时**不画** —— 这套序列帧在帧内烘焙了自己的地面投影，
	# 两层叠在脚下会糊成一团；而且跳跃帧里那个投影会跟着离地，比程序化阴影准。
	if not has_art:
		draw_set_transform(Vector2(0.0, r * 0.42), 0.0, Vector2(1.0, 0.42))
		draw_circle(Vector2.ZERO, r * 1.05, Color(0.0, 0.0, 0.0, 0.28))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 拾取范围升级后的可视化。只在超过基础范围时绘制，避免开局一直有大圆圈。
	var attract_radius := float(stats.get("attract_radius", 110.0))
	var base_attract := float(GameData.PLAYER_BASE_STATS.get("attract_radius", 110.0))
	if attract_radius > base_attract + 0.5:
		var ratio := clampf((attract_radius - base_attract) / 180.0, 0.0, 1.0)
		draw_arc(Vector2.ZERO, attract_radius, 0.0, TAU, 64, Color(0.35, 0.88, 0.82, 0.12 + ratio * 0.12), 1.5, true)
		draw_arc(Vector2.ZERO, attract_radius - 4.0, _visual_time * 0.8, _visual_time * 0.8 + PI * 0.7, 24, Color(0.55, 1.0, 0.86, 0.35), 2.0, true)

	# 角色本体交给序列帧绘制。
	# 这样后续换素材（甚至换成 Spine 节点）都不需要改移动、血量和武器逻辑。
	if has_art:
		return

	# 身体：受击无敌时闪白。用简单的几何图形保持原型零依赖，
	# 但加入头盔、背包和肩膀后，玩家在尸群里能一眼认出来。
	var body := Color("#4a7fc1")
	if _invuln > 0.0 and fmod(_invuln, 0.16) < 0.08:
		body = Color("#ffffff")

	draw_circle(Vector2(0.0, 2.0), r * 0.82, Color("#243b5c"))
	draw_circle(Vector2(0.0, -2.0), r * 0.72, body)
	draw_arc(Vector2(0.0, -2.0), r * 0.72, 0.0, TAU, 28, Color("#16324f"), 2.0, true)
	draw_circle(Vector2(-r * 0.34, -r * 0.75), r * 0.22, Color("#e6b58a"))
	draw_circle(Vector2(r * 0.34, -r * 0.75), r * 0.22, Color("#e6b58a"))
	draw_arc(Vector2(0.0, -r * 0.62), r * 0.52, PI, TAU, 16, Color("#18263d"), 4.0, true)
	draw_rect(Rect2(-r * 0.52, r * 0.18, r * 0.26, r * 0.58), Color("#9a6a43"), true)

	# 枪口方向
	var muzzle := _facing * (r + 9.0)
	draw_line(_facing * (r - 5.0), muzzle, Color("#dbe8f6"), 5.0, true)
