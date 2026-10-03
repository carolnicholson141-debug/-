class_name ObjectPool
extends RefCounted
## 对象池：复用节点，避免高频 instantiate/free。
##
## 为什么需要它：
## 割草游戏一局会生成几万只丧尸和十几万发子弹。每次 instantiate() 都要
## 分配节点、跑 _ready、连信号；free() 还要走一轮回收。这两个操作在
## 波次爆发时会造成明显的帧尖刺（GC 抖动）。
## 池化之后，节点只在开局创建一次，之后只是出池/入池，成本降到接近零。
##
## 用法：
##   var pool := ObjectPool.new(self, zombie_scene, 200)   # 预热 200 个
##   var z := pool.acquire()
##   ...
##   pool.release(z)
##
## 约定：出池的对象负责把自己「完全重置」（位置、血量、动画、可见性），
## 因为池里捞出来的节点带着上一次死亡时的状态。

var _scene: PackedScene
var _parent: Node
var _idle: Array[Node] = []
var _active: int = 0
var _created: int = 0


## prewarm > 0 时会预先实例化一批，放在池里待命（不挂进场景树）。
## 预热能避免「第一次刷怪时卡一下」——那一下正好是玩家最专注的时候。
func _init(parent: Node, scene: PackedScene, prewarm: int = 0) -> void:
	_parent = parent
	_scene = scene
	prewarm_to(prewarm, prewarm)


## 分批补足总容量（活跃 + 闲置），不会把已有的活跃对象重复计算。
## 返回本次创建数量；运行期间由 Main 限定每帧预算。
func prewarm_to(target_capacity: int, batch_size: int) -> int:
	var count := mini(maxi(0, target_capacity - _active - _idle.size()), maxi(0, batch_size))
	for _i in count:
		var n := _scene.instantiate()
		_idle.append(n)
		_created += 1
	return count


## 取一个可用对象，已经挂进场景树
func acquire() -> Node:
	var n: Node
	if _idle.is_empty():
		n = _scene.instantiate()
		_created += 1
	else:
		n = _idle.pop_back()

	_parent.add_child(n)
	_active += 1
	return n


## 归还对象。重复归还会被忽略（防御性编程：避免一处 release 两次导致
## 同一个节点同时存在于池内和场景树里，那种 bug 很难查）
func release(n: Node) -> void:
	if not is_instance_valid(n):
		return
	if not n.is_inside_tree():
		return
	_parent.remove_child(n)
	n.set_meta("pooled", true)
	_idle.append(n)
	_active = maxi(0, _active - 1)


## 把池里所有闲置对象彻底销毁（切关卡 / 回主菜单时用）
func clear_idle() -> void:
	for n in _idle:
		if is_instance_valid(n):
			n.free()
	_idle.clear()


func active_count() -> int:
	return _active


func idle_count() -> int:
	return _idle.size()


## 历史累计创建数。稳定运行后这个数字应该停住不再涨 ——
## 如果它一直在涨，说明池子没起作用（某处漏了 release）。
func created_count() -> int:
	return _created


func debug_string() -> String:
	return "池: 活跃 %d / 闲置 %d / 累计创建 %d" % [_active, _idle.size(), _created]
