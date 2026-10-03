class_name SpatialHash
extends RefCounted
## 空间哈希：把「所有敌人两两比对」的 O(n²) 降成 O(n·k)。
##
## 为什么需要它：
## 同屏 400 只丧尸时，暴力遍历 = 400×400 = 16 万次距离计算/帧，光这一项就吃满 CPU。
## 空间哈希把世界切成固定大小的格子，每个对象只登记在自己所在格；
## 查询时只扫目标点周围那几格，实际比较次数通常掉到 1/20 以下。
##
## 用法：每帧 clear() 一次，然后把所有对象 insert() 一遍，再 query。
## 建表 400 次插入 ≈ 微不足道，查询才是省下来的大头。

## 格子边长。取敌人平均直径的 2~3 倍最合适（见 GameData.CELL_SIZE）
var cell_size: float

## 格子表：key 是 (cx, cy) 编码成的整数，value 是该格内的对象数组。
## 用 int 当 key 而不是 Vector2 —— Vector2 做字典键要算哈希，且会产生大量临时对象。
var _cells: Dictionary = {}

## 本帧登记了多少个对象（调试用）
var _count: int = 0

## 二维格坐标 → 单个整数键时用的偏移与跨度。
##
## 抽成常量是因为这两个数被内联到了 insert / query 的热路径里（见那里的注释）：
## 这两个函数合起来每秒被调用几十万次，任何一次多余的函数调用都值得省。
## 偏移 32768 是为了让负坐标也映射到正数区间（世界范围 ±2400，够用）。
const _KEY_BIAS := 32768
const _KEY_SPAN := 65536


func _init(p_cell_size: float = 96.0) -> void:
	cell_size = p_cell_size


## 每帧开头调用
func clear() -> void:
	# 只保留当前帧的格子。保留所有历史格子会让 clear 本身逐渐变成
	# O(历史访问过的格子数)，在长时间移动后反而比重建字典更慢。
	_cells.clear()
	_count = 0


## 把一个对象登记到它所在的格子
func insert(item: Object, pos: Vector2) -> void:
	var cs := cell_size
	var k := (floori(pos.x / cs) + _KEY_BIAS) * _KEY_SPAN + floori(pos.y / cs) + _KEY_BIAS

	# 刻意不用 `_cells.get(k, [])`：那个默认值 `[]` 是**每次调用都新构造**的数组，
	# 即使 key 命中也要白造一个然后丢掉。400 只丧尸每帧一次插入，
	# 就是每秒 2.4 万次无谓的堆分配。用 null 判断可以做到零分配。
	var bucket = _cells.get(k)
	if bucket == null:
		bucket = []
		_cells[k] = bucket
	bucket.append(item)
	_count += 1


## 查出可能落在半径内的候选对象。
## 注意：返回的是**候选**，不是精确结果 —— 格子里可能混进半径外的对象，
## 调用方需要自己做一次精确距离过滤。这是刻意的设计：哈希负责剪枝，
## 精确判定交给调用方，因为不同场景的判定方式不一样（圆心距 / 矩形 / 线段）。
func query_radius(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	query_radius_into(pos, radius, out)
	return out


## query_radius 的零分配版本：结果写进调用方提供的数组。
func query_radius_into(pos: Vector2, radius: float, out: Array) -> void:
	var cs := cell_size
	var x0 := floori((pos.x - radius) / cs)
	var x1 := floori((pos.x + radius) / cs)
	var y0 := floori((pos.y - radius) / cs)
	var y1 := floori((pos.y + radius) / cs)

	var cx := x0
	while cx <= x1:
		var kx := (cx + _KEY_BIAS) * _KEY_SPAN
		var cy := y0
		while cy <= y1:
			var bucket = _cells.get(kx + cy + _KEY_BIAS)
			if bucket != null:
				out.append_array(bucket)
			cy += 1
		cx += 1


## query_radius 的限量版：凑够 limit 个候选就立刻收手。
##
## 为什么需要它：query_radius 会把命中格子里的对象**全部**拷进新数组。
## 密集堆叠时（几十上百只挤在同一格）这一步的拷贝成本本身就是 O(n²) ——
## 调用方即使只看前几个候选，也已经付了全量拷贝的钱。
##
## 适用场景：需要"随便给我几个近邻，不要求是最近的"。
## 如果需要真正的最近邻（比如武器索敌），只能用 query_radius / find_nearest。
##
## 这里只有 into 版本，没有"返回新数组"的包装 —— 唯一的调用方（丧尸分离）
## 自己持有 buffer，再提供一个包装函数只会诱导后来者去用它，
## 而每次调用都新分配一个数组正是这个函数存在的意义所在。

## query_radius_limited 的零分配版本。
##
## 为什么必须要有这个版本：它是全工程单帧调用次数最多的函数 ——
## 每只丧尸每次 tick 都要做一次分离查询。原来的实现每次新建一个 Array，
## 400 只丧尸 × 60 帧 = 每秒 2.4 万次"分配 + 立刻丢掉"。
## 而分离是**顺序**计算的，调用方完全可以复用同一个 buffer，
## 用它自己的成员变量当容器，一次分配、终身使用。
##
## out 允许是类型化数组（如 Array[Zombie]）：调用方那边因此能拿到静态类型，
## 省掉分离内循环里的类型转换。
func query_radius_limited_into(pos: Vector2, radius: float, limit: int, out: Array) -> void:
	out.clear()
	if limit <= 0:
		return

	var cs := cell_size
	var x0 := floori((pos.x - radius) / cs)
	var x1 := floori((pos.x + radius) / cs)
	var y0 := floori((pos.y - radius) / cs)
	var y1 := floori((pos.y + radius) / cs)

	var cx := x0
	while cx <= x1:
		var kx := (cx + _KEY_BIAS) * _KEY_SPAN
		var cy := y0
		while cy <= y1:
			var bucket = _cells.get(kx + cy + _KEY_BIAS)
			if bucket != null:
				var n := out.size()
				for item in bucket:
					out.append(item)
					n += 1
					if n >= limit:
						return
			cy += 1
		cx += 1


## query_radius 的便利版本：顺便做精确距离过滤。
## 要求 item 是 Node2D。
##
## 用 position 而不是 global_position：所有实体都是 World 容器（固定在原点）
## 的直接子节点，两者恒等。用 global_position 每帧要多走一次父变换链，
## 400 个对象 × 每帧多次查询就白烧 CPU 了。
##
## ⚠ 这个版本每次调用都**新建并返回**一个数组。热路径（子弹命中检测、
## 飞刃判定）请用 query_radius_exact_into() 复用调用方自己的缓冲。
func query_radius_exact(pos: Vector2, radius: float) -> Array:
	var r2 := radius * radius
	var out: Array = []
	for item in query_radius(pos, radius):
		if is_instance_valid(item) and (item as Node2D).position.distance_squared_to(pos) <= r2:
			out.append(item)
	return out


## query_radius_exact 的零分配版本：结果写进调用方提供的数组。
##
## 和 query_radius_exact 逐条等价（同样的哈希剪枝 + 同样的精确距离过滤），
## 只是不新建数组。热路径上这两者的差别很实在：命中检测是
## "每帧 × 每发子弹"，几十发子弹同屏时每秒能调用上千次，
## 每次一个短命 Array 就是每秒上千次堆分配。
##
## out 允许是类型化数组（如 Array[Zombie]），调用方因此能省掉
## 循环里的 `as Zombie` 转换 —— 和 query_radius_limited_into 同一个理由。
func query_radius_exact_into(pos: Vector2, radius: float, out: Array) -> void:
	out.clear()
	query_radius_into(pos, radius, out)
	var r2 := radius * radius
	# 原地压缩而不是逐项 remove_at。后者在一格里有大量候选时会反复搬移
	# 数组尾部，最坏情况下退化成 O(n²)。
	var write := 0
	for read in out.size():
		var item: Object = out[read]
		if is_instance_valid(item) and (item as Node2D).position.distance_squared_to(pos) <= r2:
			out[write] = item
			write += 1
	out.resize(write)


## 在半径内找离 pos 最近的对象，找不到返回 null
func find_nearest(pos: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d2 := radius * radius
	for item in query_radius(pos, radius):
		if not is_instance_valid(item):
			continue
		var cand := item as Node2D
		var d2 := cand.position.distance_squared_to(pos)
		if d2 < best_d2:
			best_d2 = d2
			best = cand
	return best


## 当前占用了多少格子（调试用，监控是否有格子爆炸）
func cell_count() -> int:
	return _cells.size()


func object_count() -> int:
	return _count


## 格坐标 → 整数键的编码规则：
##     key = (cx + _KEY_BIAS) * _KEY_SPAN + (cy + _KEY_BIAS)
##
## 这里原本是一个 `_key(cx, cy)` 函数，现在**没有这个函数了** ——
## 它被内联进了 insert / query_radius_into / query_radius_limited_into 三处。
## 原因是调用频率：那三个函数合起来每秒被调用几十万次，
## 而 GDScript 的函数调用开销（参数装箱 + 栈帧）比函数体本身还贵。
## 内联写法就是上面那一行，照抄即可。
