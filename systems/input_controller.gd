extends Node
## 开火模式控制器。
##
## 为什么单独抽一个节点，而不是把逻辑塞进 AutoWeapon：
## 武器只该关心「什么时候打、朝哪打」这一件事，而"现在是自动还是手动"
## 是个**跨越武器/玩家/HUD 三个地方的状态**。塞进武器里，HUD 就得去
## weapon.fire_mode 里掏字段；抽出来之后，武器拿方向、HUD 拿状态，
## 各自只依赖这一个明确的接口。
##
## 本节点挂在 Main 下，不是玩家下 —— 它是"整局游戏的输入策略"，
## 玩家节点重开一局时会被 reset，而输入策略应当在两局之间保持连续
## （玩家上一局选了手动，这局不该又跳回自动）。

## 模式变化时广播，HUD 用来更新指示器。
## 用信号而不是让 HUD 每帧去读字段：模式是个**离散事件**，
## 每帧轮询一个几乎不变的值是浪费，而且会错过"刚刚切换"这个时机。
signal mode_changed(mode: String)

var mode: String = GameData.FIRE_MODE_DEFAULT

## 缓存的最后一次有效瞄准方向。
##
## 为什么必须缓存：手动模式下鼠标正好压在玩家身上时，
## (mouse - player) 是零向量，normalized() 会返回 (0,0) ——
## 那一帧的子弹会原地不动或者朝右飞（取决于 normalize 的实现），
## 非常突兀。缓存让它保持上一次朝向，手感连续。
var aim_dir: Vector2 = Vector2.RIGHT

## 由 Main 注入：把屏幕坐标换算成世界坐标。
## 注入而不是直接读 get_global_mouse_position() ——
## 输入控制器不该知道场景树的结构，也就顺便能在无头测试里塞一个假实现。
var world_mouse_provider: Callable = Callable()

## 本帧玩家是否按住了开火键。由 tick 每帧刷新一次，
## 避免武器和 HUD 各自去调 Input.is_action_pressed 造成重复查询。
var _firing: bool = false


func toggle() -> void:
	mode = (
		GameData.FIRE_MODE_MANUAL
		if mode == GameData.FIRE_MODE_AUTO
		else GameData.FIRE_MODE_AUTO
	)
	# 切成自动时清掉"按住"状态：否则从手动切回自动的瞬间，
	# 如果玩家还按着空格，模式指示器会短暂显示成两个都在生效。
	_firing = false
	mode_changed.emit(mode)


func set_mode(new_mode: String) -> void:
	if new_mode == mode:
		return
	mode = new_mode
	_firing = false
	mode_changed.emit(mode)


func is_manual() -> bool:
	return mode == GameData.FIRE_MODE_MANUAL


## 本帧是否应该开火。武器每帧问一次。
func is_firing() -> bool:
	return _firing


## 每帧由 Main 调用（顺序在建哈希之后、武器之前）。
##
## 注意：手动模式下必须**每帧**更新 aim_dir，而不是只在开火那一帧更新。
## 因为玩家的枪口朝向是持续可见的（player._facing 由它驱动），
## 只在射击时更新的话，鼠标一动枪口却不动，观感会很割裂。
func tick(delta: float, player_pos: Vector2) -> void:
	if Input.is_action_just_pressed("toggle_fire"):
		toggle()

	# 手动模式使用鼠标左键开火；空格专门留给闪避。
	var held := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	# 暂停时（升级菜单打开）不该积累开火状态，
	# 否则关掉菜单的瞬间会"补一枪"出去。Main 在主循环开头已经挡掉了暂停，
	# 这里是第二道保险：菜单是 PROCESS_MODE_ALWAYS 的，它期间 tick 不到这里。
	_firing = held and not get_tree().paused

	_update_aim(player_pos)


func _update_aim(player_pos: Vector2) -> void:
	if not world_mouse_provider.is_valid():
		return
	var target: Vector2 = world_mouse_provider.call()
	var delta := target - player_pos
	# 距离太近时方向不可靠（鼠标贴着玩家转一圈，方向会疯狂跳）。
	# 用平方距离比，和项目里其他地方保持一致的开方策略。
	if delta.length_squared() < 4.0:
		return
	aim_dir = delta.normalized()


## 重开一局时重置。刻意**不**重置 mode —— 见文件头注释。
func reset() -> void:
	_firing = false
	aim_dir = Vector2.RIGHT
