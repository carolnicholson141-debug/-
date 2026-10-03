extends Node2D
## 持枪人类反派：保持距离并向玩家射击。
##
## 渲染用像素士兵贴图（tools/slice_soldiers.py 从 AI 生成图切出），
## 不再用 _draw() 色块小人。_draw() 只保留阴影和仇恨圈。
## 贴图枪固定朝右，朝向玩家左侧时 flip_h 翻转 —— 与主角的侧视处理同一套口径。

const TEX_BY_KIND: Array[Texture2D] = [
	preload("res://assets/characters/kenney/survivor1_gun.png"),
	preload("res://assets/characters/kenney/survivor1_gun.png"),
	preload("res://assets/characters/kenney/survivor1_gun.png"),
]

## 贴图统一画布 96x96、内容高 88px、脚底贴画布底。
## 目标屏幕高 ≈ 55px：比主角(70px)小一号，与 radius=15 的碰撞圈协调。
const SPRITE_SCALE := 1.0
## 脚底落的本地 y —— 沿用旧 _draw 时代的"地面线"（阴影中心 y=13，脚在 16）。
const GROUND_Y := 16.0

var world: Node = null
var alive := true
var hp := 42.0
var fire_cooldown := 0.0
var phase := 0.0
var strafe_sign := 1.0
var radius := 15.0
var solid := true
var kind := 0 # 0 步枪兵，1 霰弹兵，2 狙击手
var damage := 9.0
var bullet_speed := 360.0

var _spr: Sprite2D = null
## 开火白闪倒计时（s）。贴图没有开火帧，用 modulate 提亮代替。
var _flash := 0.0
var _base_color := Color.WHITE

func setup(p: Vector2, owner: Node, p_kind: int = 0) -> void:
	position = p
	world = owner
	kind = p_kind
	_base_color = [Color("#ffb0a8"), Color("#ffd36e"), Color("#b8c7ff")][clampi(kind, 0, 2)]
	if kind == 1:
		hp = 58.0
		damage = 7.0
		bullet_speed = 310.0
	elif kind == 2:
		hp = 34.0
		damage = 22.0
		bullet_speed = 560.0
	strafe_sign = -1.0 if randf() < 0.5 else 1.0
	_ensure_sprite()
	queue_redraw()

## 贴图精灵。centered 模式下画布中心 = 节点原点，画布底(+48) × scale 后在
## y=+29.8 —— 直接用会半身入土。把精灵上移，让**画布底**对齐 GROUND_Y。
func _ensure_sprite() -> void:
	if _spr != null:
		return
	_spr = Sprite2D.new()
	_spr.texture = TEX_BY_KIND[clampi(kind, 0, 2)]
	_spr.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	_spr.position = Vector2(0.0, GROUND_Y - 28.0 * SPRITE_SCALE)
	add_child(_spr)

func tick(delta: float, player: Node2D) -> void:
	if not alive or player == null or not player.alive:
		return
	phase += delta
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	_flash = maxf(0.0, _flash - delta)
	var to_player := player.position - position
	var dist := to_player.length()
	var dir := to_player.normalized() if dist > 0.01 else Vector2.RIGHT
	var move := dir * (1.0 if dist > 320.0 else (-0.65 if dist < 220.0 else 0.0))
	move += dir.rotated(PI * 0.5) * strafe_sign * 0.32
	position += move.normalized() * 48.0 * delta
	position.x = clampf(position.x, -GameData.ARENA_HALF_SIZE + 50.0, GameData.ARENA_HALF_SIZE - 50.0)
	position.y = clampf(position.y, -GameData.ARENA_HALF_SIZE + 50.0, GameData.ARENA_HALF_SIZE - 50.0)
	var attack_range := 720.0 if kind == 2 else 680.0
	if dist < attack_range and fire_cooldown <= 0.0:
		fire_cooldown = 2.35 if kind == 1 else (2.8 if kind == 2 else 1.55)
		_flash = 0.12
		var muzzle := position + dir * 22.0
		if kind == 1:
			for spread in [-0.16, 0.0, 0.16]:
				world.spawn_human_bullet(muzzle, dir.rotated(spread), bullet_speed, damage)
		else:
			world.spawn_human_bullet(muzzle, dir, bullet_speed, damage)
		Events.weapon_fired_at.emit(muzzle, dir)
	# 视觉：呼吸 bob + 朝向翻转 + 开火白闪。
	if _spr != null:
		_spr.position.y = GROUND_Y - 28.0 * SPRITE_SCALE + sin(phase * 7.0) * 1.2
		_spr.flip_h = dir.x < -0.01
		_spr.modulate = _base_color.lerp(
			Color(1.7, 1.7, 1.4), clampf(_flash / 0.12, 0.0, 1.0))
	queue_redraw()

func take_damage(amount: float) -> void:
	if not alive:
		return
	hp -= amount
	Events.enemy_hurt.emit(position, amount)
	if hp <= 0.0:
		alive = false
		var reward := 3.0 if kind == 0 else (4.0 if kind == 1 else 5.0)
		Events.enemy_killed.emit(position, reward, true)
		if world != null and world.has_method("on_human_killed"):
			world.on_human_killed(self, reward)
		queue_free()

func _draw() -> void:
	var bob := sin(phase * 7.0) * 1.2
	draw_shadow(Vector2(0, 13 + bob), 16.0, 6.0, Color(0, 0, 0, 0.3))
	# 红色仇恨圈：提示"这是会主动打你的敌人"，保留但只在这几帧里画。
	draw_arc(Vector2.ZERO, 22.0, 0.0, TAU, 24, Color(1.0, 0.25, 0.25, 0.22), 1.5, true)

func draw_shadow(center: Vector2, rx: float, ry: float, color: Color) -> void:
	draw_set_transform(center, 0.0, Vector2(1.0, ry / maxf(rx, 0.01)))
	draw_circle(Vector2.ZERO, rx, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
