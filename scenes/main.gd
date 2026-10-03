extends Node2D
## 世界根节点 —— 整个游戏的编排层。
##
## 这里刻意做了一件"不那么 Godot"的事：**所有实体由 Main 在 _physics_process 里
## 统一顺序驱动，实体自己不开 _process**。
##
## 为什么：
## 1. 确定性。Godot 的节点处理顺序依赖场景树顺序和 process_priority，
##    一旦有人在编辑器里拖动了节点顺序，行为就悄悄变了。显式驱动杜绝这种问题。
## 2. 性能。400 只丧尸各开一个 _process 回调，光调度开销就不小；
##    集中在一个循环里还能顺手共享 grid 等局部引用，少一层成员查找。
## 3. 可读性。一屏就能看完整帧干了什么，新人接手不用去挖各个脚本。
##
## 帧内顺序（不能随便换）：
##   建空间哈希 → 玩家 → 武器 → 丧尸 → 子弹 → 经验球 → 波次 → 回收
## 建表必须最先，回收必须最后。

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ZOMBIE_SCENE := preload("res://scenes/zombie.tscn")
const PROJECTILE_SCENE := preload("res://scenes/projectile.tscn")
const XP_GEM_SCENE := preload("res://scenes/xp_gem.tscn")
const CHEST_SCRIPT := preload("res://entities/chest.gd")
const ITEM_SCRIPT := preload("res://entities/item_pickup.gd")
const HUMAN_ENEMY_SCRIPT := preload("res://entities/human_enemy.gd")
const HUMAN_BULLET_SCRIPT := preload("res://entities/human_bullet.gd")
const GRENADE_SCRIPT := preload("res://entities/grenade.gd")

const ZOMBIE_PREWARM := 260
# 超出存活上限的余量留给尚未播完死亡动画的尸体。
const ZOMBIE_POOL_RESERVE := 64
const ZOMBIE_PREWARM_PER_FRAME := 16
const PROJECTILE_PREWARM := 200
const GEM_PREWARM := 200

var player: Node2D = null
var weapon: Node = null
var orbit_blades: Node = null
var director: Node = null
var upgrades: Node = null
var hud: CanvasLayer = null
var menu: Control = null
var start_screen: CanvasLayer = null
var _coins := 0
## 商店里每种商品的**历史购买次数**。价格 = base * growth^次数（见 GameData.SHOP_ITEMS），
## 所以这些计数既是"下局发多少货"的依据，也是"下一个卖多少钱"的依据。
## 计数跨局持久化（见 _load_meta / _save_meta）。
var _shop_upgrade_count := 0
var _shop_grenade_count := 0
var _shop_potion_count := 0
var _shop_revive_count := 0
var _inventory_slot_count := 2
var _pending_start_upgrades := 0
var _pending_start_items := {"grenade": 0, "potion": 0}
## 复活药剂不进行囊：作为被动充能，开局注入玩家（见 _apply_pending_start_rewards）。
var _pending_start_revives := 0

## 开火模式控制器（自动 / 手动）。挂在 Main 下而不是玩家下 ——
## 它代表"这一局玩家选的输入策略"，玩家节点重开时会 reset，而策略应当跨局保持。
var input_ctl: Node = null

## 实体容器。**必须固定在原点不动** —— 实体的 position 被当作世界坐标使用
## （见 SpatialHash 的注释），一旦移动这个节点，所有距离计算都会错位。
var entities: Node2D = null

var zombie_pool: ObjectPool = null
var projectile_pool: ObjectPool = null
var gem_pool: ObjectPool = null
var _zombie_pool_warmed := false

## 活跃实体列表。顺序不重要，所以回收时用"交换删除"保证 O(1)。
var zombies: Array[Zombie] = []
var projectiles: Array[Node] = []
var gems: Array[Node] = []
var chests: Array[Node] = []
var item_pickups: Array[Node] = []
var human_enemies: Array[Node] = []
var human_bullets: Array[Node] = []
var grenades: Array[Node] = []
var _human_spawn_timer := 12.0
var _melee_timer := 0.0
var _item_key_lock := 0.0

## 已生成精英的累计数。只用于给精英分配种类（冲锋/重装/毒雾），
## 刻意**不**用 zombies.size() —— 那个数组长度每帧都在变（见 _reap的
## 交换删除），拿它当输入会让固定种子下的两次运行分叉。
## 它是纯粹的计数器、不消耗任何 RNG，所以不破坏随机序列的可复现性。
## start_run() 里归零，保证同一颗种子重开一局得到同样的精英配置。
var _elite_serial := 0

var grid: SpatialHash = null

var _game_over: bool = false
var _best_survived: float = 0.0
var _best_kills: int = 0
## 平滑后的帧率，用于 F3 调试面板
var _fps_smooth: float = 60.0

## 帧序号。LOD 的错开调度靠它取模，见 _tick_zombies。
var _frame: int = 0

## LOD 分界距离：超过它的丧尸降频更新并隐藏。
## 由实际视口算出来（见 _refresh_lod_range），不硬编码 ——
## 窗口比例一旦变化(stretch aspect=expand)，实际可见范围就跟着变。
var _lod_far_dist: float = 820.0

## 上一帧的 LOD 分布（调试用）：视野内每帧更新的 / 视野外分帧的。
## 这两个数的比例直接决定 LOD 省了多少 —— 视野外占比越高，收益越大。
var _lod_near: int = 0
var _lod_far: int = 0

## 实际使用的 LOD 周期，命令行 `--lod N` 可覆盖（默认取 GameData.LOD_PERIOD）。
##
## 留这个开关是为了能做**受控对比**：同一个种子、同一个二进制，只改这一个值，
## 量出来的差就纯粹是分帧摊平带来的。若拿两局随机性不同的长跑去比总耗时，
## 差异里混着"这局多活了两分钟"，什么都证明不了。
var _lod_period: int = 1

## 视野内丧尸的分离判定间隔（帧）。1 = 每帧都算。
## --lod 1 会把它也设成 1，这样一个参数就能整体回到"优化前"的调度方式。
var _sep_stride: int = 1

## ---------------------------------------------------------------- 压力测试

## `-- --stress N`：开局把场上维持在恒定 N 只丧尸，并让玩家无敌。
##
## 为什么必须单独留这个入口：靠 autoplay 打到高波次来测峰值**完全不可靠** ——
## 固定种子之后机器人可能第 6 波就阵亡（同屏才 39 只），
## 那时 zombie 段 0.07ms/帧 好看得毫无意义。
## 性能验收要的是一个确定的场景："同屏 420 只、稳定持续"，而不是碰运气。
##
## 无敌也是必须的：420 只围着玩家两三秒就能把人打死，
## 玩家一死全场负载就没了，测出来的是"尸体堆了多久"。
var _stress_count: int = 0

## 压测用的属性倍率取第几波。选 12 是因为原来那个 4.23ms 的峰值就出现在第 12 波，
## 用同一档倍率才能和旧数据对齐着看。
var _stress_wave: int = 12

## 每帧最多补刷多少只。一次补满会把分配开销全堆在单帧上，
## 那个尖峰是初始化的代价、不是稳态性能，不该混进测量结果。
const STRESS_REFILL_PER_FRAME := 40

## `-- --boss`：开局立即刷一只首领。给首领血条/阶段/掉落的开发与验收用 ——
## 正常要打到第 10 波（约 4 分钟）才见首领，没有这个入口每次验证都要等。
var _boss_test: bool = false

## 无头自动测试：自动走位 + 自动选升级。
## 存在的意义是让"调平衡"这件事可以无人值守地跑 —— 割草游戏的平衡就是它的全部，
## 靠手打一局一局试太慢了。用法：
##   Godot --headless --path <工程> --fixed-fps 60 --quit-after 9000
## 会打出一份"存活多久 / 到第几级 / 击杀多少"的账单。
var autoplay: bool = false
var _autoplay_timer: float = 0.0
var _autoplay_query_buf: Array = []

## 分段计时器，命令行加 `-- --profile` 启用。
## headless 长跑时用它定位热点，比开编辑器 profiler 更快 ——
## 因为报告能和"第几波 / 几只丧尸 / 几颗经验球"直接对上，
## 一眼就能看出耗时是随哪个量增长的。
var _profile: bool = false
var _prof_acc: Dictionary = {}
var _prof_frames: int = 0
const _PROF_WINDOW := 600   # 每 600 帧（10 秒游戏时间）打一份报告

## 自动截图：命令行 `-- --shot 1800 [输出路径]`，跑到第 1800 帧抓一张图再退出。
##
## 为什么需要它：headless 只能验逻辑，验不了"东西到底画出来没有"。
## 经验球曾经漏了 queue_redraw，永远停在出生那一帧，画面上只剩个几乎看不见的小点 ——
## 这种 bug 跑一万帧 headless 也不会报一个错。
## 留一个能自动出图的入口，改完美术/特效立刻能看一眼，不用开窗口手动玩进去。
var _shot_countdown: int = -1
var _shot_path: String = ""

## 真实性能采样：命令行 `-- --perf`，每 60 帧打一行。
##
## 和 --profile 的分工：
##   --profile 用 Time.get_ticks_usec 给我们**自己代码**的各段掐表，
##             只覆盖 Main 主循环里显式标记过的那几段；
##   --perf    读引擎的 Performance 监视器，反映**整帧**的真实开销，
##             包含渲染提交、CanvasItem 变换、场景树通知、AnimatedSprite2D
##             自己推进动画的那部分 —— 这些都在我们的主循环之外。
##
## 两者的差额就是"引擎侧"的成本。而这个成本在 headless 下几乎不存在，
## 必须开着窗口量，所以两条路径都得留着。
var _perf: bool = false
var _perf_frames: int = 0


func _parse_shot_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--shot" and i + 1 < args.size():
			_shot_countdown = int(args[i + 1])
			if i + 2 < args.size() and not args[i + 2].begins_with("--"):
				_shot_path = args[i + 2]
			elif _shot_path.is_empty():
				_shot_path = "res://debug_shot.png"
			print("已开启截图模式：第 %d 帧 → %s" % [_shot_countdown, _shot_path])
			return


## 固定随机种子，命令行 `-- --seed 12345`。
##
## 存在的意义：性能对比必须可重复。割草是高度随机的 —— 刷怪位置、变体权重、
## 升级三选一，两局跑出来的"存活时长 / 击杀数"能差一倍。
## 那样优化前后的总耗时根本没法比（可能只是因为少活了一分钟）。
## 固定种子之后两次运行的随机序列完全一致，耗时差就只剩代码改动带来的那部分。
func _apply_seed_arg() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--seed" and i + 1 < args.size():
			var s := int(args[i + 1])
			# 只设全局种子就够了：刷怪用 randf()、变体权重用 randf()、
			# 升级抽卡用 Array.shuffle()，全都读同一个全局 RNG，
			# 没有哪个系统自己 randomize() 过独立随机源。
			seed(s)
			# 外观变体走的是独立随机源（GameData.variant_rng），必须一并设种，
			# 否则"这一批丧尸长什么样"依然是随机的 ——
			# 而外观会影响 radius_mult，进而影响分离计算的结果，对比就不干净了。
			# 用 s 异或一个常数是为了让两条序列错开：
			# 同种子喂给两个 RNG 会让它们产生完全相同的序列，
			# 于是"丧尸长相"和"刷怪位置"出现可见的相关性。
			GameData.seed_variants(s ^ 0x5f3a91c7)
			print("已固定随机种子：%d" % s)
			return


## 解析 `--lod N`，默认走 GameData.LOD_PERIOD。
##
## period = 1 是个特殊值：它表示"不降频"，此时视野内的分离隔帧也一并关掉，
## 于是 --lod 1 整体等价于优化前的调度方式，可以作为干净的参照组。
func _parse_lod_args() -> void:
	_lod_period = GameData.LOD_PERIOD
	_sep_stride = 2 if _lod_period > 1 else 1

	var args := OS.get_cmdline_user_args()
	var has_lod := false
	for i in args.size():
		if args[i] == "--lod" and i + 1 < args.size():
			_lod_period = maxi(1, int(args[i + 1]))
			_sep_stride = 2 if _lod_period > 1 else 1
			has_lod = true

	# --sep 单独再扫一遍：它要能覆盖 --lod 定下的默认值。
	# 调参时经常要固定 LOD 周期、只动分离间隔；把 --sep 100000 传进去
	# 就等于"基本不算分离"，用它量一次就能知道分离在全帧里占多大比重 ——
	# 先量再改，比凭猜去优化某一段可靠得多。
	for i in args.size():
		if args[i] == "--sep" and i + 1 < args.size():
			_sep_stride = maxi(1, int(args[i + 1]))

	if has_lod or "--sep" in args:
		print("LOD 周期 = %d 帧，视野内分离间隔 = %d 帧" % [_lod_period, _sep_stride])


## 解析 `--stress N`
func _apply_stress_arg() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--stress" and i + 1 < args.size():
			_stress_count = maxi(0, int(args[i + 1]))
			if _stress_count > 0:
				print("压力测试：维持 %d 只丧尸（第 %d 波倍率），玩家无敌" % [_stress_count, _stress_wave])
			return


## 解析 `--boss`（首领即刷，开发验收用）
func _apply_boss_arg() -> void:
	_boss_test = "--boss" in OS.get_cmdline_user_args()
	if _boss_test:
		print("首领测试：开局立即刷一只首领")


## 每帧补足丧尸数量。
##
## 放在主循环最前面（建哈希之前）：这样新刷出来的丧尸当帧就进哈希、
## 当帧就会被 tick，不会有一帧"看得见但打不到"的滞后。
func _maintain_stress() -> void:
	if _stress_count <= 0 or _game_over or not player.alive:
		return

	var need := mini(_stress_count - grid.object_count(), STRESS_REFILL_PER_FRAME)
	if need <= 0:
		return

	var ppos := player.position
	var hp_mult := GameData.wave_hp_mult(_stress_wave)
	var spd_mult := GameData.wave_speed_mult(_stress_wave)
	var dmg_mult := GameData.wave_damage_mult(_stress_wave)

	for _k in need:
		var ang := randf() * TAU
		# 撒在视野外沿：它们会自己挤过来，几秒内就在玩家面前堆成密集包围 ——
		# 这正是要测的最坏场景，不需要手工摆位。
		var dist := randf_range(_lod_far_dist * 0.85, _lod_far_dist * 1.05)
		var z: Zombie = zombie_pool.acquire()
		z.world = self
		z.spawn(
			GameData.pick_zombie_variant(_stress_wave),
			hp_mult, spd_mult, dmg_mult,
			false,
			ppos + Vector2.RIGHT.rotated(ang) * dist
		)
		zombies.append(z)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_best_record()
	randomize()
	autoplay = _detect_autoplay()
	_profile = "--profile" in OS.get_cmdline_user_args()
	_perf = "--perf" in OS.get_cmdline_user_args()
	_parse_shot_args()
	# 必须在 randomize() 之后：randomize 会用时间重置全局种子。
	_apply_seed_arg()
	_parse_lod_args()
	_apply_stress_arg()
	_apply_boss_arg()
	grid = SpatialHash.new(GameData.CELL_SIZE)


	_build_nodes()
	_warm_assets()
	_build_pools()

	Events.player_died.connect(_on_player_died)
	Events.item_used.connect(_on_item_used)
	Events.boss_defeated.connect(_on_boss_defeated)

	if autoplay:
		start_screen.hide_screen()
		start_run()
	else:
		_show_start_screen()


## 无头运行时自动开启；也可以手动加 --autoplay 参数在有窗口的情况下看它自己打。
func _detect_autoplay() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	for arg in OS.get_cmdline_user_args():
		if arg == "--autoplay":
			return true
	return false


## ---------------------------------------------------------------- 搭骨架

func _build_nodes() -> void:
	# --- 地面。必须最先加、且 z_index 极低，理由见 ArenaBackground 的注释：
	# 它若挂在 Main 自己的 _draw() 上（z_index = 0），会把经验球(-2)和尸体(-1)整个盖住。
	var bg: Node2D = preload("res://scenes/arena_background.gd").new()
	bg.name = "ArenaBackground"
	add_child(bg)

	entities = Node2D.new()
	entities.name = "Entities"
	add_child(entities)

	# --- 玩家
	player = PLAYER_SCENE.instantiate()
	entities.add_child(player)

	# --- 输入策略。必须在武器之前建好，武器拿到引用才能判模式。
	input_ctl = preload("res://systems/input_controller.gd").new()
	input_ctl.name = "InputController"
	# 屏幕坐标 → 世界坐标的换算注入进来，而不是让控制器自己去读
	# get_global_mouse_position()：后者在无头测试里恒为 (0,0)，
	# 会把瞄准方向永远钉在左上角。注入之后这个依赖可以被替换掉。
	input_ctl.world_mouse_provider = _mouse_world_pos
	add_child(input_ctl)

	# --- 武器挂在玩家身上
	weapon = player.get_node("Weapon")
	weapon.grid = grid
	weapon.player = player
	weapon.input_ctl = input_ctl
	weapon.spawn_projectile = _spawn_projectile
	weapon.human_nearest = _nearest_human_in_range
	# 玩家在手动模式下要朝鼠标。返回零向量时玩家会自行退回"跟随移动方向"。
	player.aim_provider = _aim_dir_for_player
	orbit_blades = preload("res://systems/orbit_blades.gd").new()
	orbit_blades.name = "OrbitBlades"
	orbit_blades.player = player
	orbit_blades.grid = grid
	player.add_child(orbit_blades)

	# --- 玩法系统
	director = preload("res://systems/wave_director.gd").new()
	director.name = "WaveDirector"
	director.on_spawn = _on_director_spawn
	add_child(director)

	upgrades = preload("res://systems/upgrade_system.gd").new()
	upgrades.name = "UpgradeSystem"
	upgrades.player = player
	upgrades.autoplay = autoplay
	add_child(upgrades)

	# --- UI
	var feedback := preload("res://systems/feedback.gd").new()
	feedback.name = "Feedback"
	entities.add_child(feedback)

	var audio := preload("res://systems/audio_manager.gd").new()
	audio.name = "AudioManager"
	add_child(audio)

	hud = preload("res://ui/hud.gd").new()
	hud.name = "HUD"
	hud.debug_provider = _debug_info
	add_child(hud)
	hud.restart_requested.connect(_return_to_start)
	hud.resume_requested.connect(_resume_from_pause)
	hud.inventory_provider = _inventory_info

	var menu_layer := CanvasLayer.new()
	menu_layer.name = "MenuLayer"
	menu_layer.layer = 2
	add_child(menu_layer)

	menu = preload("res://ui/upgrade_menu.gd").new()
	menu.name = "UpgradeMenu"
	menu_layer.add_child(menu)
	start_screen = preload("res://ui/start_screen.gd").new()
	start_screen.name = "StartScreen"
	add_child(start_screen)
	start_screen.start_requested.connect(_begin_from_start_screen)
	start_screen.buy_requested.connect(_buy_from_shop)

	# --- 接线
	upgrades.menu = menu
	menu.choice_picked.connect(upgrades.choose)
	menu.stack_provider = upgrades.stack_count
	# 卡片要显示"12.0 → 15.0"，得能读到玩家当前属性
	menu.stats_provider = _player_stats

	# 开火模式变化要通知 HUD 更新指示器
	input_ctl.mode_changed.connect(hud._on_fire_mode)
	# 新一局开始时 HUD 要显示**当前真实模式**（模式跨局保持，见 hud.fire_mode_provider）
	hud.fire_mode_provider = _current_fire_mode
	_spawn_map_loot()


## 当前开火模式。给 HUD 的 fire_mode_provider 用。
func _current_fire_mode() -> String:
	return input_ctl.mode if input_ctl != null else GameData.FIRE_MODE_DEFAULT


## 供菜单读取玩家当前属性表（空表时菜单会跳过数值行，不会崩）
func _player_stats() -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	return player.stats


## 鼠标的世界坐标。
## 用 viewport + canvas_transform 手工换算，而不是 get_global_mouse_position()：
## 相机有平滑(position_smoothing)，两者在同一帧里可能差一两个像素，
## 而枪口朝向对这点误差很敏感 —— 会看到准星和枪管方向对不上。
func _mouse_world_pos() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return player.position if player != null else Vector2.ZERO
	return vp.get_canvas_transform().affine_inverse() * vp.get_mouse_position()


## 玩家当前应该朝哪。
## 只有手动模式才返回鼠标方向 —— 自动模式下枪口应该跟着走位方向转，
## 否则玩家一边跑一边枪管牢牢指着鼠标，看起来像在倒着跑。
func _aim_dir_for_player() -> Vector2:
	if input_ctl == null or not input_ctl.is_manual():
		return Vector2.ZERO
	if autoplay or _stress_count > 0:
		# 无头测试里没有真实鼠标，让它保持默认朝向逻辑，
		# 免得所有子弹都朝屏幕左上角飞、压测数据失真。
		return Vector2.ZERO
	return input_ctl.aim_dir


## 预热素材：把实际会显示的帧源提前切好。
## 否则第一波刷怪时会现场 load PNG，正好卡在玩家最专注的那一刻。
##
## ⚠ 这里只预热**真正会被渲染的**三套帧。原来的实现遍历 ZOMBIE_VARIANTS
## 去调 zombie_frames(sheet) / sequence_frames(sequence)，会加载 CraftPix 的
## 4 张 1280x128 横条表和 gunner 的整幅序列帧 —— 共 20+ 张 PNG、上百个
## AtlasTexture，而 zombie.gd 的 _frames_for 早已统一返回 Kenney 帧，
## 这些资源一张都不会显示。纯浪费启动时间和内存。
func _warm_assets() -> void:
	# 丧尸（所有非首领变体共用）
	GameData.kenney_zombie_frames()
	# 精英
	GameData.elite_zombie_frames()
	# 玩家。闪避动画第一次按空格才 load 会卡一下 ——
	# 而闪避恰恰是最吃手感、最不能卡的操作。
	GameData.player_frames()
	# 阶段2 自制怪物与首领素材
	for key: String in ["ripper", "spitter", "smasher", "drowned", "boss_abomination"]:
		GameData.monster_frames(key)


func _build_pools() -> void:
	zombie_pool = ObjectPool.new(entities, ZOMBIE_SCENE, ZOMBIE_PREWARM)
	projectile_pool = ObjectPool.new(entities, PROJECTILE_SCENE, PROJECTILE_PREWARM)
	gem_pool = ObjectPool.new(entities, XP_GEM_SCENE, GEM_PREWARM)


## ---------------------------------------------------------------- 开局 / 重开

func start_run() -> void:
	_clear_entities()
	get_tree().paused = false

	# 视口尺寸决定两件事：刷怪环半径、LOD 分界线。只取一次，两处共用。
	var vp := get_viewport().get_visible_rect().size
	_refresh_lod_range(vp)

	player.reset()
	player.inventory_capacity = _inventory_slot_count
	weapon.reset()
	orbit_blades.reset()
	input_ctl.reset()
	director.start(vp)
	upgrades.reset()

	_game_over = false
	_frame = 0
	_item_key_lock = 0.0
	_human_spawn_timer = 12.0
	_melee_timer = 0.0
	# 必须归零：否则第二局的精英种类会接着上一局的计数走，
	# 同一颗种子两次开局就会得到不同的精英配置。
	_elite_serial = 0
	_spawn_map_loot()
	_spawn_humans(2)

	if _stress_count > 0:
		player.invincible = true
		# 压测要的是"稳定维持 N 只"，不能再让波次系统往上叠，否则场景会漂。
		# 代价是 director.elapsed 不再推进，所以 profile 报告的时间改用帧号折算。
		director.running = false

	Events.run_started.emit()
	_apply_pending_start_rewards()

	if _boss_test:
		# 首领即刷：走正式的刷怪通道（_on_director_spawn），保证与第 10 波
		# 真正出现的首领走完全相同的初始化路径，测出来的就是线上行为。
		# 必须放在 run_started 之后：run_started 会让 HUD 收起首领血条，
		# 先刷首领的话血条刚亮出就被盖掉了。
		_on_director_spawn(1, true, true, player.position)

func _show_start_screen() -> void:
	get_tree().paused = true
	# 商品数据从 GameData.SHOP_ITEMS 统一推导 —— 加新商品只需要改那张表，
	# 这里的字段名约定是 <id>_price / <id>_count，商店界面按同样的约定取。
	var data := {"coins": _coins, "slot_count": _inventory_slot_count}
	for it: Dictionary in GameData.SHOP_ITEMS:
		var kind := String(it["id"])
		data[kind + "_price"] = _shop_price(kind)
		data[kind + "_count"] = _shop_count(kind)
	start_screen.show_screen(data)

func _begin_from_start_screen() -> void:
	start_screen.hide_screen()
	start_run()

## 商品现价 = base * growth^历史购买次数。**每买一个，下一个就更贵**。
## 数值来源全在 GameData.SHOP_ITEMS，这里只做查表与取整。
func _shop_price(kind: String) -> int:
	var it: Dictionary = GameData.shop_item(kind)
	return maxi(int(it["base"]), ceili(float(it["base"]) * pow(float(it["growth"]), _shop_count(kind))))

## 各商品的历史购买次数（slot 特殊：直接由当前栏位数反推）。
func _shop_count(kind: String) -> int:
	match kind:
		"upgrade":
			return _shop_upgrade_count
		"grenade":
			return _shop_grenade_count
		"potion":
			return _shop_potion_count
		"revive":
			return _shop_revive_count
		"slot":
			return _inventory_slot_count - 2
	return 0

func _shop_add(kind: String) -> void:
	match kind:
		"upgrade":
			_shop_upgrade_count += 1
		"grenade":
			_shop_grenade_count += 1
		"potion":
			_shop_potion_count += 1
		"revive":
			_shop_revive_count += 1
		"slot":
			_inventory_slot_count += 1

func _buy_from_shop(kind: String) -> void:
	var it: Dictionary = GameData.shop_item(kind)
	if it.is_empty():
		return
	if kind == "slot" and _inventory_slot_count >= 5:
		start_screen.set_status("物品栏已经全部解锁")
		return
	var price := _shop_price(kind)
	if _coins < price:
		start_screen.set_status("金币不足，还需要 %d 金币" % (price - _coins))
		return
	_coins -= price
	_shop_add(kind)
	match kind:
		"upgrade":
			# 购买次数写入永久商店计数，每一局都会按总次数发放。
			pass
		"grenade":
			pass
		"potion":
			pass
		"revive":
			pass
	_save_meta()
	_show_start_screen()
	start_screen.set_status("购买成功，下局开始时生效")

func _apply_pending_start_rewards() -> void:
	# 商店数量是永久成长：每局开局按累计购买次数发放，而不是只发放购买后的下一局。
	for item_id: String in ["grenade", "potion"]:
		for _i in _shop_count(item_id):
			player.add_item(item_id)
	_pending_start_items = {"grenade": 0, "potion": 0}
	# 复活药剂是被动充能：注入玩家，倒下时自动消耗一次。
	if _shop_revive_count > 0:
		player.add_revive_charge(_shop_revive_count)
		_pending_start_revives = 0
	if _shop_upgrade_count > 0:
		upgrades.queue_start_choices(_shop_upgrade_count)
		_pending_start_upgrades = 0


## 算出 LOD 分界距离。
##
## 取"视口对角线的一半 + 缓冲"，而不是屏宽的一半：
## 相机在场地角落时，屏幕上离玩家最远的点是对角线的端点，
## 用半宽会把那部分本来能看见的丧尸误判成"视野外"。
##
## 再留一圈 LOD_MARGIN 缓冲是必须的：分界线上的丧尸是每 3 帧才挪一次的，
## 缓冲带保证它们跨过界线之前就已经回到每帧更新，
## 否则会在画面边缘看到它们一格一格地飘进来。
func _refresh_lod_range(viewport_size: Vector2) -> void:
	var view_radius := viewport_size.length() * 0.5
	# 下限是防御性的：headless 下视口尺寸可能是 0，
	# 那会把分界线压到 90px，等于全场丧尸都被判成"视野外"，游戏直接不成样子。
	_lod_far_dist = maxf(view_radius + GameData.LOD_MARGIN, 800.0)


func _clear_entities() -> void:
	for z in zombies:
		zombie_pool.release(z)
	zombies.clear()

	for p in projectiles:
		projectile_pool.release(p)
	projectiles.clear()

	for g in gems:
		gem_pool.release(g)
	gems.clear()
	for c in chests:
		if is_instance_valid(c):
			c.queue_free()
	chests.clear()
	for item in item_pickups:
		if is_instance_valid(item):
			item.queue_free()
	item_pickups.clear()
	for h in human_enemies:
		if is_instance_valid(h):
			h.queue_free()
	human_enemies.clear()
	for b in human_bullets:
		if is_instance_valid(b):
			b.queue_free()
	human_bullets.clear()
	for grenade in grenades:
		if is_instance_valid(grenade):
			grenade.queue_free()
	grenades.clear()

	grid.clear()


## ---------------------------------------------------------------- 主循环

func _physics_process(delta: float) -> void:
	update_debug_fps(delta)
	# 开始页（start_screen）显示时按 Esc 不能切换暂停 ——
	# 否则会在菜单背后把游戏解暂停，波次提前跑起来，等玩家"开始"时已经掉血了。
	# start_screen.visible 比 get_tree().paused 更能表达"正停在开始页"这个意图，
	# 因为升级菜单打开时 paused 也是 true，但那时候按 Esc 不该被拦。
	var on_start_screen: bool = start_screen != null and start_screen.visible
	if Input.is_action_just_pressed("pause") and not _game_over and not menu.visible and not on_start_screen:
		get_tree().paused = not get_tree().paused
		hud.set_paused(get_tree().paused)

	if get_tree().paused:
		return

	# 帧序号只在这里递增（暂停时不涨）。LOD 的错开调度靠它取模。
	_frame += 1
	_item_key_lock = maxf(0.0, _item_key_lock - delta)
	if Input.is_action_just_pressed("dodge"):
		player.dodge()
	if _item_key_lock <= 0.0:
		for slot_index in 5:
			if Input.is_key_pressed(KEY_1 + slot_index) and player.use_slot(slot_index):
				_item_key_lock = 0.25
				break

	# 压测补怪必须赶在建哈希之前，理由见 _maintain_stress 的注释。
	_maintain_stress()

	# 计时用 Time.get_ticks_usec 而不是 Time.get_ticks_msec：
	# 单段耗时经常不到 1ms，毫秒精度会全是 0，看不出问题。
	var t := _now()

	_rebuild_grid()
	_mark(t, "grid")

	t = _now()
	# 死亡后不必再驱动机器人走位：玩家已经不响应移动了，纯属白算
	if autoplay and not _game_over:
		_update_autoplay(delta)
	_mark(t, "autoplay")

	t = _now()
	# 输入控制器必须在玩家和武器之前 tick：
	# 玩家要用它给的瞄准方向画枪口，武器要用它给的方向开火。
	input_ctl.tick(delta, player.position)
	_mark(t, "input")

	t = _now()
	player.tick(delta)
	_mark(t, "player")

	t = _now()
	weapon.tick(delta)
	_mark(t, "weapon")

	t = _now()
	orbit_blades.tick(delta)
	_mark(t, "orbit")

	t = _now()
	_tick_zombies(delta)
	_mark(t, "zombie")

	t = _now()
	_tick_projectiles(delta)
	_mark(t, "proj")

	t = _now()
	_tick_grenades(delta)
	_mark(t, "grenade")

	t = _now()
	_tick_gems(delta)
	_mark(t, "gem")

	t = _now()
	_tick_loot(delta)
	_mark(t, "loot")

	t = _now()
	_tick_humans(delta)
	_resolve_enemy_faction_combat(delta)
	_mark(t, "humans")

	t = _now()
	# 玩家死了就别再刷怪了，让场上残余自己走完
	if not _game_over:
		# 传 grid 的登记数而不是 zombies.size()：
		# 后者含正在播死亡动画的尸体，用它算"同屏数量"会让刷怪提前降速。
		director.tick(delta, player.position, grid.object_count())
	else:
		_handle_restart_input()
	_mark(t, "wave")

	t = _now()
	_reap()
	_mark(t, "reap")

	_profile_tick()
	_perf_tick()


func _resume_from_pause() -> void:
	get_tree().paused = false
	hud.set_paused(false)


func _perf_tick() -> void:
	if not _perf:
		return
	_perf_frames += 1
	if _perf_frames % 60 != 0:
		return
	print("[perf 帧%-6d 尸%-4d] 物理段=%6.2fms 整帧process=%6.2fms 绘制调用=%-5d" % [
		_perf_frames,
		zombies.size(),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])


## ---------------------------------------------------------------- 性能采样

## 不采样时恒返回 0，让 _mark 变成空操作 —— 这样测量代码可以一直留在主循环里，
## 不用为了上线而删掉，也就不会出现"删的时候手抖改坏顺序"这种事。
func _now() -> int:
	return Time.get_ticks_usec() if _profile else 0


func _mark(t0: int, key: String) -> void:
	if _profile:
		_prof_acc[key] = int(_prof_acc.get(key, 0)) + (Time.get_ticks_usec() - t0)


func _profile_tick() -> void:
	if not _profile:
		return
	_prof_frames += 1
	if _prof_frames % _PROF_WINDOW != 0:
		return

	var parts: PackedStringArray = []
	for key in ["grid", "autoplay", "player", "weapon", "zombie", "proj", "gem", "wave", "reap"]:
		parts.append("%s=%.2f" % [key, float(_prof_acc.get(key, 0)) / float(_PROF_WINDOW) / 1000.0])
	# 时间用帧号折算（--fixed-fps 60 下帧号/60 就是游戏内秒数）。
	# 不用 director.elapsed：压测模式会把波次导演停掉，那个计时不往前走。
	print("[%6.1fs 波%-2d 尸%-3d(近%3d/远%3d) 球%-3d 弹%-3d] %s" % [
		float(_prof_frames) / 60.0, director.wave, zombies.size(), _lod_near, _lod_far,
		gems.size(), projectiles.size(),
		" ".join(parts),
	])
	_prof_acc.clear()


func _rebuild_grid() -> void:
	grid.clear()
	for z in zombies:
		# 尸体（solid=false）不进表，这样子弹不会打在尸体上，
		# 武器索敌也不会去锁定一具尸体。
		if z.solid:
			grid.insert(z, z.position)
	# 人类反派**不进这个哈希**。
	# 原因：这个 grid 被丧尸分离（zombie._separation）当邻居查询用，
	# 而 _sep_buf 是 Array[Zombie] —— 人类一旦插进来，query 时就会
	# "Attempted to push_back into TypedArray" 报错，每帧每只丧尸一次，
	# 是纯噪声污染（实测 611 次/长跑）。
	# 而且人类数量只有个位数（2~4 只），塞进哈希换来的索敌优化微乎其微，
	# 却污染了全工程最热的分离路径。武器索敌改成单独线性遍历人类
	# （见 auto_weapon 与 _update_autoplay 的 find 分支）。


## 丧尸调度。这里做了分帧（LOD）：视野外的丧尸每 LOD_PERIOD 帧才更新一次。
##
## 为什么安全：丧尸全部生成在视野外（刷怪环半径 ≈ 视口对角线一半 + 余量），
## 走到能被看见要好几秒。这几秒里"它离玩家多远"只是个数字，没有任何人看得见。
## 而同屏 400 只时，视野外的数量往往是视野内的两三倍 —— 这部分开销纯属白烧。
##
## 位移不是"少走"而是"攒着一起走"：tick 时传 delta × LOD_PERIOD，
## 累积位移与每帧更新完全相等，只是晚应用几十毫秒。
##
## 错开用 (index + frame) % period，而不是让所有远处丧尸在同一帧偷懒：
## 后者会让那几帧开销降到近乎零、另外几帧依然满载 —— 而掉帧是由**峰值帧**
## 决定的，优化必须盯着峰值，平均值降了也没用。
func _tick_zombies(delta: float) -> void:
	var ppos := player.position
	var far2 := _lod_far_dist * _lod_far_dist
	var frame := _frame
	var period := _lod_period
	var stride := _sep_stride
	var far_delta := delta * float(period)
	var near := 0
	var far := 0

	for i in zombies.size():
		var z := zombies[i]

		# 尸体（alive=false）必须每帧 tick：它在倒数回收计时器。
		# 少 tick 一次就晚回收一帧，池子被占着，累积数量会一路涨。
		if not z.alive:
			z.tick(delta, ppos, player, grid)
			continue

		if z.position.distance_squared_to(ppos) > far2:
			far += 1
			# 没轮到就整只跳过 —— 连 set_lod_hidden 都不调：
			# 它上一轮已经是隐藏状态，这里再喊一次纯属浪费。
			# 新出池的丧尸最多在视野外多显示 2 帧，反正看不见。
			if (i + frame) % period != 0:
				continue
			z.set_lod_hidden(true)
			# 视野外的丧尸照样算分离：它们每次 tick 之间本来就隔了好几帧，
			# 再跳过一次就是十几帧不更新，走进视野时会明显是散的。
			z.tick(far_delta, ppos, player, grid, true)
		else:
			near += 1
			z.set_lod_hidden(false)
			# 视野内才做分离的隔帧分摊 —— 这里才是丧尸最密、分离最贵的地方。
			z.tick(delta, ppos, player, grid, stride <= 1 or (i + frame) % stride == 0)

	_lod_near = near
	_lod_far = far


func _tick_projectiles(delta: float) -> void:
	for p in projectiles:
		p.tick(delta, grid)


func _tick_gems(delta: float) -> void:
	# ⚠ 玩家阵亡后这里**不能直接 return**。
	# 经验球被吸到玩家身上才会置 recycle_ready（见 xp_gem.tick），
	# 一旦不再 tick，场上所有球就永远不会被回收 ——
	# 画面上一直堆着绿点，对象池里的节点也一直被占着，直到重开才清。
	# 玩家死后球吸不动是合理的，但**仍然要让它们 tick**：
	# tick 里"已进入吸附状态"的球会继续飞行直至被回收，
	# 而剩余的球保持原位（不会凭空消失，玩家不会觉得经验被系统吃了）。
	var stats: Dictionary = player.stats
	if not player.alive:
		# 只推进已经在飞的球，其余原地不动。
		for g in gems:
			if g.is_attracted():
				g.tick(delta, player.position, 0.0, float(stats["pickup_radius"]))
		return
	for g in gems:
		g.tick(delta, player.position, float(stats["attract_radius"]), float(stats["pickup_radius"]))

func _spawn_map_loot() -> void:
	if not chests.is_empty() or not item_pickups.is_empty():
		return
	var occupied: Array[Vector2] = []
	for _i in 4:
		var p := _random_loot_position(occupied, 190.0)
		occupied.append(p)
		var chest := CHEST_SCRIPT.new()
		entities.add_child(chest)
		chest.setup(p)
		chests.append(chest)
	for _i in 5:
		var p := _random_loot_position(occupied, 105.0)
		occupied.append(p)
		var grenade := randf() < 0.55
		_spawn_item_at(
			p,
			"grenade" if grenade else "potion",
			"手榴弹" if grenade else "生命药剂",
			Color("#e5a34b") if grenade else Color("#63e59b")
		)

func _random_loot_position(occupied: Array[Vector2], min_distance: float) -> Vector2:
	var arena := GameData.ARENA_HALF_SIZE - 90.0
	for _attempt in 40:
		var candidate := Vector2(randf_range(-arena, arena), randf_range(-arena, arena))
		# 出生点附近留出安全区，避免开局站着就被宝箱和道具挡住。
		if candidate.length_squared() < 180.0 * 180.0:
			continue
		var clear := true
		for other in occupied:
			if candidate.distance_squared_to(other) < min_distance * min_distance:
				clear = false
				break
		if clear:
			return candidate
	return Vector2(arena * 0.65, arena * 0.35)

func _tick_loot(delta: float) -> void:
	if not player.alive:
		return
	for chest in chests:
		if chest.tick(delta, player.position):
			_open_chest(chest)
	for i in range(item_pickups.size() - 1, -1, -1):
		var item := item_pickups[i]
		if item.tick(delta, player.position):
			player.add_item(item.item_id)
			Events.chest_opened.emit(item.position, item.item_name)
			item.queue_free()
			item_pickups.remove_at(i)

func _open_chest(chest: Node) -> void:
	chest.open()
	var roll := randi() % 3
	if roll == 0:
		var pool: Array = GameData.UPGRADE_POOL.duplicate()
		var upgrade: Dictionary = pool[randi() % pool.size()]
		player.apply_upgrade(upgrade)
		Events.chest_opened.emit(chest.position, "升级卡：" + String(upgrade.get("name", "属性提升")))
	elif roll == 1:
		player.add_item("grenade")
		Events.chest_opened.emit(chest.position, "手榴弹 ×1")
	else:
		player.add_item("potion")
		Events.chest_opened.emit(chest.position, "生命药剂 ×1")

func _inventory_info() -> Dictionary:
	return player.inventory if player != null else {}

func _on_item_used(item_id: String, pos: Vector2) -> void:
	if item_id == "potion":
		player.heal(35.0)
		Events.chest_opened.emit(pos, "生命药剂生效：恢复 35 点生命")
	elif item_id == "grenade":
		var facing := player.get("_facing") as Vector2
		if facing == null or facing.length_squared() < 0.01:
			facing = Vector2.RIGHT
		var target := pos + facing.normalized() * 280.0
		var grenade := GRENADE_SCRIPT.new()
		entities.add_child(grenade)
		grenade.setup(pos, target, Callable(self, "_detonate_grenade"))
		grenades.append(grenade)
		Events.chest_opened.emit(pos, "手榴弹已投出")

func _detonate_grenade(pos: Vector2) -> void:
	var hit_count := 0
	for z in zombies:
		if z.alive and z.position.distance_squared_to(pos) <= 260.0 * 260.0:
			z.take_damage(95.0)
			hit_count += 1
	for human in human_enemies:
		if is_instance_valid(human) and human.alive and human.position.distance_squared_to(pos) <= 260.0 * 260.0:
			human.take_damage(95.0)
			hit_count += 1
	Events.chest_opened.emit(pos, "手榴弹爆炸：命中 %d 个目标" % hit_count)

func _tick_grenades(delta: float) -> void:
	for i in range(grenades.size() - 1, -1, -1):
		var grenade := grenades[i]
		if grenade.tick(delta):
			grenades.remove_at(i)
			grenade.queue_free()

func _spawn_humans(count: int) -> void:
	for _i in count:
		var h := HUMAN_ENEMY_SCRIPT.new()
		entities.add_child(h)
		var angle := randf() * TAU
		var dist := randf_range(430.0, 650.0)
		var max_kind := mini(2, director.wave / 4)
		h.setup(player.position + Vector2.RIGHT.rotated(angle) * dist, self, randi_range(0, max_kind))
		human_enemies.append(h)

func spawn_human_bullet(pos: Vector2, dir: Vector2, speed: float = 360.0, damage: float = 9.0) -> void:
	var b := HUMAN_BULLET_SCRIPT.new()
	entities.add_child(b)
	b.setup(pos, dir, speed, damage)
	human_bullets.append(b)

func _tick_humans(delta: float) -> void:
	_human_spawn_timer -= delta
	if _human_spawn_timer <= 0.0:
		_human_spawn_timer = 14.0
		if player.alive:
			_spawn_humans(mini(1 + director.wave / 5, 4))

	# 先剔除已释放的引用，再 tick。
	#
	# ⚠ 死亡时 human_enemy.gd 走的是 queue_free()，而这个数组**从不**清理
	# 失效引用 —— 人类每 14 秒生几个，死掉的那些会一直堆在里面。
	# 长局（20 分钟）能堆到几十个失效对象，而下面 _tick_humans、
	# _resolve_enemy_faction_combat、_nearest_human_in_range 每一帧都要
	# 遍历整个数组并 is_instance_valid 白跑一遍。
	#
	#
	# 这里用 remove_at 而不是 _reap 里 zombies 那种"与末尾交换再 pop_back"。
	# 原因：human_enemies 是**类型化数组** Array[Node]，而交换删除会把
	# 末尾元素赋值到中间槽位 —— 如果末尾那个恰好也是已释放对象，
	# 就会把一个已 free 的实例写进类型化数组，引擎直接报
	#   "Attempted to set an invalid (previously freed?) object instance
	#    into a 'TypedArray'"
	# 每帧必报。remove_at 只做"删掉自己"，不把任何对象写进别的槽位，
	# 对失效引用是安全的。
	#
	# 代价是 O(n) 搬移 —— 但这个列表只有个位数元素（人类 2~4 只），
	# 且只在有对象死亡时才进这个分支，搬移成本可忽略。
	for i in range(human_enemies.size() - 1, -1, -1):
		var h: Node = human_enemies[i]
		if not is_instance_valid(h) or not h.alive:
			if is_instance_valid(h):
				h.queue_free()
			human_enemies.remove_at(i)

	# 玩家阵亡后人类不再 tick（打不动的人不该还在走位），
	# 但上面两段清理**必须继续跑** —— 否则玩家死后这一局剩下的
	# 人类和人类子弹会永远冻结在场上下不来，重开时才被整体清掉。
	var can_act: bool = player != null and player.alive
	for h in human_enemies:
		if can_act and is_instance_valid(h):
			h.tick(delta, player)

	for i in range(human_bullets.size() - 1, -1, -1):
		var b := human_bullets[i]
		if not is_instance_valid(b) or b.tick(delta, player):
			if is_instance_valid(b):
				b.queue_free()
			human_bullets.remove_at(i)

## 射程内最近的存活人类反派，没有则 null。
## 人类不进丧尸分离哈希（见 _rebuild_grid），武器索敌要单独问这个。
## 人类只有个位数，直接线性遍历，不需要哈希。
func _nearest_human_in_range(range_val: float) -> Node2D:
	var best: Node2D = null
	var best_d2: float = range_val * range_val
	for human in human_enemies:
		if not is_instance_valid(human) or not human.alive or not human.solid:
			continue
		var d2: float = human.position.distance_squared_to(player.position)
		if d2 < best_d2:
			best_d2 = d2
			best = human
	return best


func _resolve_enemy_faction_combat(delta: float) -> void:
	# 人类反派与丧尸属于两个敌对阵营，靠近时会互相攻击。
	# 这样战场上会出现真实的三方混战，玩家也能利用它们互相消耗。
	#
	# **离散"一口"结算，不是每帧连续掉血**（见 FACTION_MELEE_INTERVAL）。
	# 每帧调用 take_damage(12.0*delta) 会持续刷新丧尸的受击硬直，
	# 让贴到人类的丧尸被永久钉在 hurt 状态 —— 动不了也咬不到人。
	_melee_timer -= delta
	if _melee_timer > 0.0:
		return
	_melee_timer = GameData.FACTION_MELEE_INTERVAL
	for human in human_enemies:
		if not is_instance_valid(human) or not human.alive:
			continue
		for z in zombies:
			if not z.alive:
				continue
			var hit_range: float = float(human.radius) + float(z.radius) + 8.0
			if human.position.distance_squared_to(z.position) <= hit_range * hit_range:
				human.take_damage(GameData.FACTION_MELEE_DAMAGE_TO_HUMAN)
				z.take_damage(GameData.FACTION_MELEE_DAMAGE_TO_ZOMBIE)


## 回收本帧该消失的对象。
##
## 用"与末尾元素交换再 pop_back"而不是 remove_at(i)：
## 后者是 O(n) 内存搬移，400 只丧尸一帧死 10 只就是 4000 次搬移。
## 交换删除是 O(1)，而本列表的**顺序没有任何意义**，可以随便打乱。
func _reap() -> void:
	var i := zombies.size() - 1
	while i >= 0:
		if zombies[i].recycle_ready:
			var z := zombies[i]
			zombies[i] = zombies[zombies.size() - 1]
			zombies.pop_back()
			zombie_pool.release(z)
		i -= 1

	i = projectiles.size() - 1
	while i >= 0:
		if projectiles[i].recycle_ready:
			var p := projectiles[i]
			projectiles[i] = projectiles[projectiles.size() - 1]
			projectiles.pop_back()
			projectile_pool.release(p)
		i -= 1

	i = gems.size() - 1
	while i >= 0:
		var g := gems[i]
		if g.recycle_ready:
			# 经验球是"被吸到玩家身上"才回收的，那一刻才结算经验 ——
			# 而不是掉落时就结算，否则玩家会觉得凭空涨了经验。
			#
			# 玩家阵亡后 add_xp 自己会早退（player.gd 里有 alive 检查），
			# 但这里**不能**跳过 xp_collected 信号的守卫：那会连着
			# 播一串"捡到经验"的音效，而结算界面正显示在屏幕上 ——
			# 一局结束的时间点响几十声金币声，非常突兀。
			# 经验球该回收还是要回收（别让池子被占着），只是别再广播。
			if player.alive:
				player.add_xp(g.value)
				Events.xp_collected.emit(g.value)
			gems[i] = gems[gems.size() - 1]
			gems.pop_back()
			gem_pool.release(g)
		i -= 1


## ---------------------------------------------------------------- 回调

## 武器开火回调，由 AutoWeapon 通过 Callable 调用
func _spawn_projectile(
	pos: Vector2, dir: Vector2, damage: float, speed: float, pierce: int, life: float,
	chain_count: int = 0, chain_range: float = 115.0,
	crit_chance: float = 0.0, crit_multiplier: float = 1.8,
	homing: bool = true, homing_range: float = 430.0
) -> void:
	var p := projectile_pool.acquire()
	p.spawn(
		pos, dir, damage, speed, pierce, life,
		chain_count, chain_range, crit_chance, crit_multiplier,
		homing, homing_range
	)
	# 人类敌人不进入丧尸空间哈希，交给子弹做补充扫掠判定。
	p.human_targets = human_enemies
	projectiles.append(p)


## 波次导演刷怪回调
func _on_director_spawn(count: int, elite: bool, boss: bool, player_pos: Vector2) -> void:
	var hp_mult := GameData.wave_hp_mult(director.wave)
	var spd_mult := GameData.wave_speed_mult(director.wave)
	var dmg_mult := GameData.wave_damage_mult(director.wave)

	for i in count:
		var z: Zombie = zombie_pool.acquire()
		# world 必须在 spawn 之前设好：spawn 之后的任何一帧都可能死亡，
		# 而 _start_death 会回调 world.on_zombie_killed。
		z.world = self
		var chosen_variant: Dictionary = GameData.ZOMBIE_VARIANTS[3] if boss else GameData.pick_zombie_variant(director.wave)
		# 精英种类用**本波内的序号**决定，不用 zombies.size()。
		#
		# ⚠ 原来写的是 `(director.wave + zombies.size()) % 3`，有两个问题：
		#   1. zombies 这个数组在 _reap() 里被"与末尾交换再 pop_back"删除，
		#      长度每帧都在变 —— 同一个种子跑两次，只要两局的击杀时序有
		#      任何一点不同（帧率波动、升级顺序），这里就会分叉。
		#      而"固定种子可复现"是整个性能对比方案的地基（见 _apply_seed_arg）。
		#   2. 本循环里 zombies.append(z) 在下一轮迭代前就执行了，
		#      所以同一波的多只精英会互相影响对方的种类 —— 第一只和
		#      最后一只算的是不同的输入，纯粹是意外而非设计。
		# 用 i（本次刷怪调用内的序号）就没有这两个问题：它只依赖
		# "这一波刷了几只"，与场上状况完全解耦。
		var elite_kind := 0
		if elite and not boss:
			elite_kind = (director.wave + i + _elite_serial) % 3
			_elite_serial += 1
		z.spawn(
			chosen_variant,
			hp_mult, spd_mult, dmg_mult,
			elite,
			director.random_spawn_point(player_pos),
			elite_kind,
			boss
		)
		zombies.append(z)
		if boss:
			Events.boss_spawned.emit(z.position)
		elif elite:
			Events.elite_spawned.emit(z.position)


## 丧尸死亡回调
func on_zombie_killed(z: Zombie) -> void:
	player.register_kill(z.xp_value)

	# 场上经验球到上限：把一颗球改成强制吸附，腾位置。
	#
	# 关键：挑"还没在飞"的球，而不是固定挑第一颗。
	# 一颗球飞回玩家身上要花约一秒，这一秒里可能有几十次击杀 ——
	# 如果每次都去命令同一颗球，那几十次命令就是白下的，而击杀依然在往场上加球，
	# 数量会一路涨到失控（实测能到 800+，每帧遍历它们本身就成了主要开销）。
	#
	# 也不直接删除：直接删等于玩家白杀了一只丧尸，
	# 那种"经验被系统吃掉"的感觉比卡顿更让人恼火。
	if gems.size() >= GameData.MAX_GEMS:
		for g in gems:
			if is_instance_valid(g) and not g.is_attracted():
				g.force_attract()
				break

	var g := gem_pool.acquire()
	g.spawn(z.position, z.xp_value)
	gems.append(g)

func on_human_killed(_human: Node, xp_value: float) -> void:
	# 人类反派是独立敌对阵营，击杀同样计入连杀、经验和升级进度。
	player.register_kill(xp_value)


## 首领召唤回调（zombie.gd 阶段2 起周期调用）。
## 在首领身边一小圈刷普通丧尸，走对象池与 MAX_ALIVE 全局上限 ——
## 召唤只是"换了个出怪点的波次刷怪"，不允许绕过任何既有保护。
func on_boss_summon(count: int, boss_pos: Vector2) -> void:
	if _game_over or player == null or not player.alive:
		return
	var hp_mult := GameData.wave_hp_mult(director.wave)
	var spd_mult := GameData.wave_speed_mult(director.wave)
	var dmg_mult := GameData.wave_damage_mult(director.wave)
	for _i in count:
		if grid.object_count() >= GameData.MAX_ALIVE:
			return
		var z: Zombie = zombie_pool.acquire()
		z.world = self
		z.spawn(
			GameData.pick_zombie_variant(director.wave),
			hp_mult, spd_mult, dmg_mult,
			false,
			boss_pos + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(50.0, 110.0)
		)
		zombies.append(z)


## 首领被击杀：原地撒奖励 —— 一圈高价值经验球 + 手榴弹与药剂各一。
## 经验球走 gem_pool（与击杀掉落同源，上限保护自动生效），
## 物品走 item_pickup（与地图散落同源，靠近自动拾取）。
func _on_boss_defeated(pos: Vector2) -> void:
	if not player.alive:
		return
	var n := GameData.BOSS_REWARD_GEMS
	for i in n:
		var ang := TAU * float(i) / float(n) + randf() * 0.4
		var g := gem_pool.acquire()
		g.spawn(
			pos + Vector2.RIGHT.rotated(ang) * randf_range(26.0, 84.0),
			randf_range(GameData.BOSS_REWARD_XP[0], GameData.BOSS_REWARD_XP[1])
		)
		gems.append(g)
	_spawn_item_at(pos + Vector2(38.0, 8.0), "grenade", "手榴弹", Color("#e5a34b"))
	_spawn_item_at(pos + Vector2(-38.0, 8.0), "potion", "生命药剂", Color("#63e59b"))
	Events.chest_opened.emit(pos, "首领战利品：大量经验 + 手榴弹 + 生命药剂")


## 在指定位置放一个地面道具（地图散落与首领掉落共用）。
func _spawn_item_at(p: Vector2, id: String, label: String, col: Color) -> void:
	var item := ITEM_SCRIPT.new()
	entities.add_child(item)
	item.setup(p, id, label, col)
	item_pickups.append(item)


## 玩家死亡：跑完主循环再统一广播，保证「存活时间」是完整的一整秒
func _on_player_died() -> void:
	if _game_over:
		return
	_game_over = true
	director.running = false
	var survived: float = float(director.elapsed)
	var total_kills: int = int(player.kills)
	if survived > _best_survived:
		_best_survived = survived
	if total_kills > _best_kills:
		_best_kills = total_kills
	var earned: int = 3 + director.wave * 2 + int(total_kills / 5)
	_coins += earned
	_save_best_record()
	Events.game_over.emit({
		"survived": survived,
		"kills": total_kills,
		"level": player.level,
		"best_survived": _best_survived,
		"best_kills": _best_kills,
	})

func _return_to_start() -> void:
	_show_start_screen()


func _load_best_record() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://zombie_horde_record.cfg") == OK:
		_best_survived = float(cfg.get_value("record", "survived", 0.0))
		_best_kills = int(cfg.get_value("record", "kills", 0))
		_coins = int(cfg.get_value("meta", "coins", 0))
		_shop_upgrade_count = int(cfg.get_value("meta", "upgrade_count", 0))
		_shop_grenade_count = int(cfg.get_value("meta", "grenade_count", 0))
		_shop_potion_count = int(cfg.get_value("meta", "potion_count", 0))
		_shop_revive_count = int(cfg.get_value("meta", "revive_count", 0))
		_inventory_slot_count = int(cfg.get_value("meta", "slot_count", 2))


func _save_best_record() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("record", "survived", _best_survived)
	cfg.set_value("record", "kills", _best_kills)
	cfg.set_value("meta", "coins", _coins)
	cfg.set_value("meta", "upgrade_count", _shop_upgrade_count)
	cfg.set_value("meta", "grenade_count", _shop_grenade_count)
	cfg.set_value("meta", "potion_count", _shop_potion_count)
	cfg.set_value("meta", "revive_count", _shop_revive_count)
	cfg.set_value("meta", "slot_count", _inventory_slot_count)
	cfg.save("user://zombie_horde_record.cfg")

func _save_meta() -> void:
	_save_best_record()


## 死亡后按 R 重开。刻意做成"只在死亡后生效"——
## 游戏中途误触 R 直接重开，玩家会想砸键盘。
func _handle_restart_input() -> void:
	if Input.is_action_just_pressed("restart"):
		start_run()


## ---------------------------------------------------------------- 调试

## 自动走位。
## 这不是 AI，只是个"远离最近一堆丧尸"的机器人 —— 它唯一的作用是让游戏
## 能一直跑下去，好把波次推进、升级三选一、精英刷新这些流程完整走一遍。
## 别拿它的存活时间去衡量难度：真人会主动往尸群缝隙里钻，它只会逃跑。
func _update_autoplay(delta: float) -> void:
	_autoplay_timer -= delta
	if _autoplay_timer > 0.0:
		return
	_autoplay_timer = 0.3

	var flee := Vector2.ZERO
	grid.query_radius_exact_into(player.position, 300.0, _autoplay_query_buf)
	for z in _autoplay_query_buf:
		var d := player.position - (z as Node2D).position
		var l := d.length()
		if l > 0.001:
			# 除以距离平方：越近的丧尸推力越大，形成"躲开最近那只"的本能
			flee += d / (l * l)

	# 附近没丧尸就随机游走，避免原地站桩
	if flee.length_squared() < 0.000001:
		flee = Vector2.RIGHT.rotated(randf() * TAU)

	# 快贴到场地边界时加一股回中心的力，防止被逼到墙角慢慢磨死
	var lim := GameData.ARENA_HALF_SIZE - 260.0
	var pos := player.position
	if absf(pos.x) > lim or absf(pos.y) > lim:
		flee += (-pos).normalized() * 3.0

	player.autoplay_dir = flee.normalized()


func update_debug_fps(delta: float) -> void:
	if delta <= 0.0:
		return
	var fps := 1.0 / delta
	# 指数平滑：瞬时帧率抖得根本读不出来，平滑后才能看出真实趋势
	_fps_smooth = _fps_smooth * 0.9 + fps * 0.1


func _debug_info() -> String:
	return "FPS %.0f | 丧尸 %d (近%d/远%d) | 子弹 %d | 经验球 %d | 哈希格 %d\n%s\n%s\n%s" % [
		_fps_smooth,
		zombies.size(),
		_lod_near,
		_lod_far,
		projectiles.size(),
		gems.size(),
		grid.cell_count(),
		zombie_pool.debug_string(),
		projectile_pool.debug_string(),
		gem_pool.debug_string(),
	]


## ---------------------------------------------------------------- 自动截图

func _process(_delta: float) -> void:
	# 菜单停留和游戏开局都逐帧预热，不阻塞开始页，也不修改刷怪/RNG 顺序。
	if not _zombie_pool_warmed and zombie_pool != null:
		_zombie_pool_warmed = zombie_pool.prewarm_to(
			GameData.MAX_ALIVE + ZOMBIE_POOL_RESERVE, ZOMBIE_PREWARM_PER_FRAME
		) == 0
	if _shot_countdown < 0:
		return
	_shot_countdown -= 1
	if _shot_countdown <= 0:
		_capture_and_quit()


## 抓当前画面存盘后退出。
##
## 必须等 frame_post_draw：这一帧还没画完就去取纹理，拿到的会是上一帧甚至空白。
func _capture_and_quit() -> void:
	var path := _shot_path
	_shot_countdown = -1   # 立刻关掉计时，否则异步等待期间又被触发一次
	await RenderingServer.frame_post_draw

	var tex := get_viewport().get_texture()
	if tex == null:
		push_error("截图失败：视口没有可读纹理（headless 没有渲染目标，必须开窗口跑）")
		get_tree().quit(1)
		return

	var img := tex.get_image()
	var err := img.save_png(path)
	if err != OK and path.begins_with("res://"):
		# 某些构建不允许写 res://，退回 user:// 而不是直接失败
		path = "user://debug_shot.png"
		err = img.save_png(path)
	if err != OK:
		push_error("截图保存失败：%s（错误码 %d）" % [path, err])
		get_tree().quit(1)
		return

	print("截图已保存：", ProjectSettings.globalize_path(path))
	get_tree().quit()


## ---------------------------------------------------------------- 退出清理

## 退出时把池里闲置的对象真正释放掉，并清空精灵表缓存。
##
## 不做这一步，Godot 退出时会打出几百行 "ObjectDB instances were leaked /
## CanvasItem RIDs were leaked"。那些**不是运行期内存泄漏** ——
## 只是预热了但没派上用场的对象没被回收，进程马上就结束了，无所谓。
## 但它们会淹没日志，让人以为游戏有内存问题，所以还是清干净。
func _exit_tree() -> void:
	# 调试构建下打一份池子账单。
	# 关键看"累计创建"这个数：它应该停在预热值附近。
	# 如果它一路涨到几千，说明某处漏了 release —— 池子形同虚设，得去查。
	if OS.is_debug_build() and is_instance_valid(player) and is_instance_valid(director):
		var reason := "玩家阵亡" if _game_over else ("卡在暂停(菜单未关)" if get_tree().paused else "帧数跑完")
		print("—— 本局结束 —— %s" % reason)
		print("存活 %.1fs | 等级 %d | 击杀 %d | 场上丧尸 %d" % [
			director.elapsed, player.level, player.kills, zombies.size()
		])
		print(zombie_pool.debug_string())
		print(projectile_pool.debug_string())
		print(gem_pool.debug_string())

	if zombie_pool != null:
		zombie_pool.clear_idle()
	if projectile_pool != null:
		projectile_pool.clear_idle()
	if gem_pool != null:
		gem_pool.clear_idle()
	GameData.clear_cache()
