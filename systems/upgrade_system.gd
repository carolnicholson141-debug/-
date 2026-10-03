extends Node
## 升级系统。
##
## 职责只有两件：升级时抽三个候选；玩家选完把效果打到玩家身上。
##
## 关键点是 process_mode = ALWAYS —— 升级菜单打开时游戏是暂停的，
## 但这个节点必须继续跑，否则玩家的点击永远得不到响应，游戏就死锁了。

## 由 Main 注入
var player: Node2D = null
var menu: Control = null

## 待处理的升级次数。一次吃到多颗经验球可能连升两级，
## 用队列而不是布尔标记，否则第二级的菜单会被吞掉。
var _pending: int = 0
var _active: bool = false

## upgrade_id -> 已叠加次数，用来实现每个升级的上限
var _stacks: Dictionary = {}

## 自动测试模式：直接选第一个候选，不弹菜单。
## 无头跑平衡测试时必须开 —— 否则第一次升级就会把游戏暂停在那里，永远跑不下去。
var autoplay: bool = false


func _ready() -> void:
	# 暂停时依然需要处理输入和信号
	process_mode = Node.PROCESS_MODE_ALWAYS
	Events.level_up_requested.connect(_on_level_up_requested)
	Events.game_over.connect(_on_game_over)


func reset() -> void:
	_pending = 0
	_active = false
	_stacks.clear()
	get_tree().paused = false

func queue_start_choices(count: int) -> void:
	_pending += maxi(0, count)
	_try_open()


func _on_level_up_requested(_level: int) -> void:
	_pending += 1
	_try_open()


func _try_open() -> void:
	if _active or _pending <= 0:
		return
	if player == null or menu == null or not player.alive:
		_pending = 0
		return

	var choices := roll_choices(3)
	if choices.is_empty():
		# 所有升级都叠满了，直接放行
		_pending -= 1
		return

	if autoplay:
		_pending -= 1
		choose(choices[0])
		return

	_active = true
	var remaining_choices := _pending
	_pending -= 1
	get_tree().paused = true
	menu.open(choices, remaining_choices)


## 抽出 count 个「还没叠满」的升级
func roll_choices(count: int) -> Array:
	var pool: Array = []
	for u: Dictionary in GameData.UPGRADE_POOL:
		# 强化现在可以无限叠加；数值下限仍由 Player.apply_upgrade / GameData.STAT_FLOOR 保护。
		pool.append(u.duplicate(true))

	# 池子不够就直接给现有的，不要硬凑重复项 —— 玩家看到两张一样的卡会很困惑
	if pool.size() <= count:
		return pool

	# 洗牌后取前 count 个。这里用无放回抽样，保证三个选项互不相同。
	pool.shuffle()
	return pool.slice(0, count)


## 菜单里点选后回调（由 UpgradeMenu.choice_picked 连过来）
func choose(upgrade: Dictionary) -> void:
	var id := String(upgrade["id"])
	_stacks[id] = int(_stacks.get(id, 0)) + 1

	if player != null and player.alive:
		player.apply_upgrade(upgrade)

	_active = false
	get_tree().paused = false

	# 处理排队的下一级
	_try_open()


## 玩家死亡时要把暂停解开，否则结算界面点不动
func _on_game_over(_summary: Dictionary) -> void:
	_pending = 0
	_active = false
	get_tree().paused = false


func stack_count(id: String) -> int:
	return int(_stacks.get(id, 0))
