extends Node
## 全局配置与数据表。
##
## 设计原则：**所有可调数值只在这一个文件里出现**。
## 调平衡、改手感、加新丧尸/新升级，都只改这里，不碰任何玩法逻辑。
## （等数值多到一定程度，可以把这个文件换成一个 .tres Resource，就能在
##   编辑器 Inspector 里拖着调了。现在用 const 是为了零运行时开销 + 能全局搜索。）

# ---------------------------------------------------------------- 尺寸 / 视口

## 精灵表单帧边长（px）。CraftPix 这套是横条精灵表，帧高 = 帧宽 = 128。
const FRAME_SIZE := 128

## 丧尸精灵缩放。128px 原图 × 0.5 ≈ 屏幕上 33px 高，1280 视口约能放下 38 个。
## Kenney Top-down Shooter 角色原图约 43px 高，统一按 1:1 显示。
const ZOMBIE_SCALE := 1.0

# ---------------------------------------------------------------- 外观变体

## 同一套精灵表再随机出一批「长相不同」的个体。
##
## 为什么需要它：美术只给了 4 套精灵表，第 12 波 420 只同屏时，画面上是
## 同四张脸重复一百遍 —— 一眼假。真去画 20 套精灵表的成本太高，
## 而「随机缩放 + 色调偏移」能在零美术成本下把视觉种类放大一个数量级。
##
## 为什么**不能**用全局 randf()：这个项目要求固定种子可复现（见 main.gd 的
## _apply_seed_arg），而变体抽取的次数会随 LOD 设置变化（视野外丧尸 tick 次数不同
## → 出池时机不同 → 抽取次数不同）。一旦它消耗全局 RNG，两次对比跑就会错位。
## 所以这里用**独立的 RandomNumberGenerator**，由 Main 在 --seed 时同步设种。
const VARIANT_SCALE_JITTER := 0.14    # 体型抖动 ±14%
const VARIANT_TINT_JITTER := 0.10     # 明度抖动 ±10%
const VARIANT_HUE_JITTER := 0.055     # 色相抖动 ±0.055（HSV 里 1.0 是一整圈）

## 瘦小个体出现时同步缩一点碰撞半径，避免「看着小、判定大」的错位感
const VARIANT_RADIUS_TRACK := 0.55    # 半径跟随体型变化的比例（0 = 完全不跟）

# ---------------------------------------------------------------- 走动起伏

## 丧尸行走时的身体起伏幅度(px，世界坐标，作用于精灵 offset.y)。
##
## 为什么静态贴图也能「活」起来：贴图本身是死的，但人眼对**周期性位移**
## 极其敏感 —— 给它一个正弦起伏，立刻就有"在走"的感觉，成本却只是一次 sin()。
## 幅度别调大：±3px 以上会像喝醉了在蹦，尤其一群丧尸同频时非常出戏。
const ZOMBIE_WOBBLE_AMP := 1.5

## 起伏周期(s)。配合 Walk 动画 11fps 使用 —— 太慢会像飘，太快像抽搐。
const ZOMBIE_WOBBLE_PERIOD := 0.4

## 受击时叠加的额外抖动幅度(px)，让打击感有肉眼可见的反馈
const ZOMBIE_HURT_SHAKE_AMP := 2.6

## 精灵表目录
const ZOMBIE_SHEET_DIR := "res://assets/characters/zombies/"

## 整幅序列帧目录前缀。下面按角色名分子目录：<前缀><角色名>/sequence/<动画>/
const ZOMBIE_SEQ_DIR := "res://assets/characters/"
const ELITE_ZOMBIE_SHEET_PATH := "res://assets/characters/elite_zombie_walk.png"

## 动画名 → {精灵表文件名后缀, 播放速度(fps), 是否循环}
##
## ⚠ 键名（= SpriteFrames 里的动画名）**必须全小写**，与 Zombie 里的
## STATE_WALK / STATE_ATTACK 等常量一致 —— zombie.gd 是拿 "walk"、"attack"
## 这种小写名去切动画的，而 SpriteFrames.has_animation() 是**精确匹配大小写**的。
##
## 这里曾经写成 "Walk"/"Attack"（首字母大写），后果是 zombie.gd 里
## `_play(STATE_WALK)` 的守卫 `has_animation("walk")` 恒为 false，
## 直接 return —— 动画永远切不过去，**所有丧尸（除首领）永久卡在 Idle**，
## 看起来就是一坨不会动的贴图。首领之所以没事，是因为它自己的序列帧
## 用的就是小写动画名。
##
## 文件名后缀单独放 "file" 一格：CraftPix 的贴图叫 Zombie_1_Walk.png，
## 首字母是大写的，不能跟着动画名一起改小写。
const ANIM_SETTINGS := {
	"idle":   {"file": "Idle",   "fps": 7.0,  "loop": true},
	"walk":   {"file": "Walk",   "fps": 11.0, "loop": true},
	"attack": {"file": "Attack", "fps": 14.0, "loop": false},
	"hurt":   {"file": "Hurt",   "fps": 14.0, "loop": false},
	"dead":   {"file": "Dead",   "fps": 8.0,  "loop": false},
}

## 丧尸序列帧的动画集：动画名 -> {播放速度(fps), 是否循环}
## 键名必须全小写，理由同 ANIM_SETTINGS。
const ZOMBIE_SEQ_PLANS := {
	"idle":   {"fps": 7.0,  "loop": true},
	"walk":   {"fps": 10.0, "loop": true},
	"attack": {"fps": 12.0, "loop": false},
	"hurt":   {"fps": 12.0, "loop": false},
	"dead":   {"fps": 8.0,  "loop": false},
}

## 玩家序列帧的动画集。素材包是「女主2-1 ~ 2-12」共 12 套，一一对应。
##
## 三处和丧尸动画集不同的地方：
##   1. 多出 dodge / attack_move / reload / pickup / throw 等状态；
##   2. 一次性动作（dodge / hurt / dead / pickup / throw）必须 non-loop，
##      循环了会在动作结束后原地重复，看起来像卡住；
##   3. 缺目录时退回 idle 而不是 attack —— 玩家没有 attack 兜底的意义，
##      退回 idle 至少是个站姿。
##
## **fps 怎么定的**：帧数由素材决定（改不了），fps 决定"这段动作播多久"。
## 所以每个值都是按"这段动作应该持续多久"反推的，依据写在行尾。
## 另外：anim 是"游戏里的状态名"，dir 是"素材目录名"，两者可以不同 ——
## 见 dead 那行。
const PLAYER_SEQ_PLANS := {
	# 待机：24/21 帧。12fps → 2.0s / 1.75s 一轮。待机要慢，
	# 快了会像在抽搐；慢了又像静止贴图。
	"idle":        {"fps": 12.0, "loop": true},
	"idle2":       {"fps": 12.0, "loop": true},
	# 走 / 跑：**两套都用**，由 Shift 切换（见 PLAYER_SPRINT_MULT）。
	#
	# fps 是按"一步别跨太多身高"定的 —— 一步跨的身高 = 速度 × 半周期 ÷ 角色屏高(70px)。
	# 参考值：走 0.6~0.8、跑 0.9~1.2，超了就明显滑步。
	#   走 @30fps：25 帧一轮 0.83s，235px/s 下一步 ≈ 1.4 身高（偏大，但 235 是原速，
	#              没动它 —— 想完全不滑把 move_speed 降到 ~140，或把这里 fps 调更高）
	#   跑 @28fps：16 帧一轮 0.57s，冲刺 317px/s 下一步 ≈ 1.3 身高 ✓
	"walk":        {"fps": 30.0, "loop": true},
	"run":         {"fps": 28.0, "loop": true},
	# 射击：13 帧 @24fps = 0.54s，正好对上开火间隔 cooldown 0.55s ——
	# 一枪走完一个循环，节奏和火力对齐，不会出现"动作还在抬手、子弹已经飞了"。
	"attack":      {"fps": 24.0, "loop": true},
	"attack_move": {"fps": 24.0, "loop": true},
	# 闪避：22 帧 @34fps ≈ 0.65s。比无敌 0.45s 略长一点，留出落地收势。
	"dodge":       {"fps": PLAYER_DODGE_FPS, "loop": false},
	# 受伤：16 帧 @24fps ≈ 0.67s，比无敌 0.45s 稍长，挨打后能看清反应。
	"hurt":        {"fps": 24.0, "loop": false},
	# ⚠ 素材包里**没有专门的死亡动作**（12 套里最接近的是受伤2）。
	# 拿 hurt2 顶替，并用 dir 指过去 —— 这样目录名保持"受伤"的语义，
	# 以后真拿到死亡素材，建一个 sequence/dead/ 目录再删掉 dir 就行。
	"dead":        {"fps": 20.0, "loop": false, "dir": "hurt2"},
	"hurt2":       {"fps": 24.0, "loop": false},
	# 拾取 / 投掷：一次性小动作，0.6~0.8s。
	# 投掷配"手雷"这类道具用，目前游戏还没接线，先备着。
	"pickup":      {"fps": 18.0, "loop": false},
	"throw":       {"fps": 20.0, "loop": false},
	# 换弹：49 帧 @24fps ≈ 2.0s。游戏目前没有弹药系统，先备着。
	"reload":      {"fps": 24.0, "loop": true},
}

# ---------------------------------------------------------------- 玩家素材

## 玩家序列帧的画布边长(px)。与丧尸同为 192 —— 所以脚底贴底线、
## AnimatedSprite2D 的 offset 恒为 (0, -96)，两边口径一致。
##
## ⚠ 一个角色的多套动画**必须共用同一个缩放**，否则游戏里切换动画时体型会跳变。
## 实测这套素材各动画的"中位帧内容高"从 210px(跑动) 到 304px(移动) 差 1.45 倍 ——
## 如果每套各自归一化，跑动会比移动大 1.4 倍。所以全部用 tools/build_sequence.py
## 的 --scale 0.46667 统一换算（= 站姿内容高 300px 归一到画布内 140px）。
const PLAYER_FRAME_SIZE := 192

## 玩家精灵缩放：画布 192 × 0.5 = 屏幕 96px 高。
const PLAYER_SPRITE_SCALE := 1.0

## 脚底落在节点原点上所需的 offset。
## 与丧尸的 (0, -画布高/2) 是同一套语义，只是这里写成常量好对账。
##
## ⚠ **-21.5 不是 -96。** 素材换成了 Kenney 角色（player_frames() 走
## _build_kenney_frames("survivor1")），实测画布 35~51 x 43、内容 bbox
## y=[0,42] —— **脚底贴画布底、内容填满 43px 高**，不是 192px 序列帧。
## 半高 = 43/2 = 21.5，所以 offset.y = -21.5 让脚底落在节点原点。
##
## 沿用 -96（= -192/2，序列帧时代的值）会让角色浮在 -74.5px：
## 判定圈在地上、贴图在天上，两者差了将近两个身位。
## 这个值必须和 player.tscn 里 HeroSprite.offset 保持一致 ——
## 两处各写一份字面量，是之前口径分叉的根源。
const PLAYER_SPRITE_OFFSET := Vector2(0.0, -28.0)

## 闪避动画帧率。素材是 22 帧的后跳，34fps 播完约 0.65s。
## 参照：闪避无敌 0.42s、冷却 2.2s。太快看不清动作，太慢会拖住手感。
const PLAYER_DODGE_FPS := 34.0

## 开火后维持"射击姿态"的时长(s)。必须**大于**开火间隔 cooldown(0.55s)，
## 否则连续开火时中间会闪回 idle，看起来一顿一顿。
## 也不能太长 —— 打完之后要能及时回到 idle / run。
##
## ⚠ 这个常量现在只是**基准**，不再被直接使用。升级射速后 cooldown 会变，
## 固定值会让动作脱节 —— 实际维持时长由 player.gd 的 _on_weapon_fired 按
## "当前 cooldown × PLAYER_FIRE_HOLD_MULT" 动态算（见下）。
const PLAYER_FIRE_HOLD := 0.62

## 射击姿态维持时长 = 当前射速 × 这个倍率。
## 取 1.2：略大于一轮开火间隔，保证连射时不闪回 idle，又不会残留太久。
## 基准值 0.55×1.2 = 0.66，与原来的固定 0.62 手感接近（开局几乎无感），
## 但射速升到 0.07s 后维持时长会缩到 0.084s，动作跟子弹同频。
const PLAYER_FIRE_HOLD_MULT := 1.2

## 攻击动画播放倍速的上限。射速升到 0.07s 时，若攻击动画也无限加速，
## 抬手动作会糊成一团、看不出在射击。封顶 2.2x，动作保持可辨识。
const PLAYER_ATTACK_FPS_MAX_SCALE := 2.2

## 按住 Shift 冲刺时的移速倍率。
##
## 为什么需要它：这套素材有「移动」和「跑动」两套动作，但游戏只有一个 move_speed。
## 直接按速度快慢选动作会乱，所以显式绑到按键上 —— 不按 Shift 走（walk），
## 按住跑（run）。
##
## 取值依据：run 是 16 帧 @24fps（一轮 0.67s），一步约 1.1 个身高；
## 基础移速 235px/s、角色屏幕高 70px 时，一轮走 157px = 1.1 身高 —— 正好对得上，
## 所以 run 配 235~320 这段速度都不打滑。1.35 落在区间内。
const PLAYER_SPRINT_MULT := 1.35

## 枪口位置：**相对节点原点**的偏移，按当前动画查表。
##
## ⚠ **这张表是按 43px Kenney 素材重量出来的，角色只有 43px 高。**
## 旧值（idle y=-63.4、attack y=-64.1）是 192px 序列帧时代的测量结果，
## 那时角色屏幕高约 96px。素材换小之后沿用它，子弹会从**玩家头顶上方
## 二十多像素**飞出 —— 角色矮了 43px，枪口却还停在 -64。
##
## 量法（对 assets/characters/kenney/survivor1_*.png 做 alpha 包围盒分析）：
## 枪口 = 该帧"举枪/持枪"姿态下，武器最靠前那一端的像素，换算到节点坐标系
## （画布中心 + offset.y=-21.5 之后再减去内容 y 坐标）。
## 只有 machine / gun 两帧真正前伸了枪管，实测尖端 y≈30/31；
## 其余姿态枪收在身侧，退回躯干高度（约 y=22）。
##
## 朝向翻转由 player.gd 处理，这里存的是"面朝右"时的偏移。
const PLAYER_MUZZLE_OFFSETS := {
	"idle":        Vector2(14.0, -22.0),
	"idle2":       Vector2(14.0, -22.0),
	"walk":        Vector2(15.0, -23.0),
	"run":         Vector2(16.0, -26.0),
	"attack":      Vector2(25.0, -30.0),
	"attack_move": Vector2(24.0, -29.0),
	"dodge":       Vector2(14.0, -20.0),
	"hurt":        Vector2(15.0, -22.0),
	"hurt2":       Vector2(15.0, -22.0),
	"dead":        Vector2(15.0, -22.0),
	"reload":      Vector2(15.0, -21.0),
	"pickup":      Vector2(14.0, -21.0),
	"throw":       Vector2(16.0, -24.0),
}

## 查不到当前动画时用的兜底枪口偏移（取站姿射击的值）。
const PLAYER_MUZZLE_OFFSET_DEFAULT := Vector2(14.0, -22.0)

## 决定精灵左右朝向时，方向向量的水平分量要多大才作数。
##
## 素材是侧视图，只有左右两种朝向，而朝向来源（鼠标 / 移动方向）带竖直分量：
## 往正上方走时 x == 0，若直接按 `x < 0` 判断会突然变成面朝右；鼠标移到头顶同理。
## 低于这个阈值就**保持上一次的左右朝向**，这也是侧视图素材配四方向移动的标准做法。
const PLAYER_FACE_DEADZONE := 0.35

# ---------------------------------------------------------------- 商店物品

## 商店在售物品表。价格曲线统一为 base * growth^已购个数 ——
## **每买一个，下一个就更贵**（用户点名的机制）。growth 越大涨得越猛：
## 手雷/药水是消耗品，起步 1 金币、每次翻倍；
## 升级卡牌成长平缓（1.35）因为它是长线成长；
## 复活药剂是最强保命道具，起步就贵、涨得也快。
const SHOP_ITEMS := [
	{"id": "upgrade", "name": "升级卡牌", "base": 10, "growth": 1.35,
		"icon": "res://assets/ui/items/upgrade_card.png",
		"desc": "下局开局多抽一次三选一"},
	{"id": "grenade", "name": "手雷", "base": 1, "growth": 2.0,
		"icon": "res://assets/ui/items/grenade.png",
		"desc": "开局塞进行囊 · 数字键掷出，重创周围"},
	{"id": "potion", "name": "生命药水", "base": 1, "growth": 2.0,
		"icon": "res://assets/ui/items/potion.png",
		"desc": "开局塞进行囊 · 数字键饮用，回复 35 HP"},
	{"id": "revive", "name": "复活药剂", "base": 15, "growth": 2.2,
		"icon": "res://assets/ui/items/revive.png",
		"desc": "倒下时自动饮下 · 原地复活并回复 50% HP"},
	{"id": "slot", "name": "行囊栏位", "base": 12, "growth": 1.8,
		"icon": "",
		"desc": "行囊永久扩 1 格（上限 5 格）"},
]

## 复活药剂触发时回复的 HP 比例（相对最大生命）。
const REVIVE_HP_RATIO := 0.5
## 复活后的无敌时长(s)。刚爬起来周围还有怪，不给无敌会立刻再倒。
const REVIVE_INVULN := 2.0

## 图标缓存。load 有引擎级缓存，这层缓存的意义是避免重复查表。
var _icon_cache: Dictionary = {}

## 按物品 id 取图标；没有图的物品（如行囊栏位）返回 null，调用方自行兜底。
func item_icon(id: String) -> Texture2D:
	if _icon_cache.has(id):
		return _icon_cache[id]
	var tex: Texture2D = null
	for it: Dictionary in SHOP_ITEMS:
		if String(it["id"]) == id:
			var p := String(it["icon"])
			if p != "" and ResourceLoader.exists(p):
				tex = load(p)
			break
	_icon_cache[id] = tex
	return tex

func shop_item(id: String) -> Dictionary:
	for it: Dictionary in SHOP_ITEMS:
		if String(it["id"]) == id:
			return it
	return {}

# ---------------------------------------------------------------- 场地

## 可活动范围（世界坐标，以原点为中心的正方形半边长）
const ARENA_HALF_SIZE := 2400.0

## 背景网格线间距（仅用于让玩家感知移动）
const GRID_STEP := 160.0

# ---------------------------------------------------------------- 空间哈希

## 哈希格子边长。经验值：取敌人平均直径的 2~3 倍。
## 太小 → 每格敌人少但查询要扫更多格；太大 → 每格敌人多。
const CELL_SIZE := 96.0

# ---------------------------------------------------------------- 开火模式

## 自动开火：冷却好了就朝索敌结果开火，玩家只管走位。
const FIRE_MODE_AUTO := "auto"
## 手动开火：按住开火键才射击，弹道朝鼠标方向。
const FIRE_MODE_MANUAL := "manual"

## 默认模式。割草游戏的默认体验是自动 —— 新手进来先爽到，
## 想要操作感的玩家再自己按 F 切到手动。
const FIRE_MODE_DEFAULT := FIRE_MODE_AUTO

# ---------------------------------------------------------------- 玩家

const PLAYER_RADIUS := 14.0

## 玩家初始属性。每次开局都从这份模板 duplicate 一份，保证可重复。
const PLAYER_BASE_STATS := {
	"move_speed": 235.0,          # px/s
	"max_hp": 100.0,
	"damage": 12.0,               # 单发伤害
	"crit_chance": 0.0,
	"crit_multiplier": 1.8,
	"cooldown": 0.55,             # 开火间隔(s)
	"range": 430.0,               # 索敌半径
	"projectiles": 1,             # 每次开火发射弹数
	"spread_deg": 9.0,            # 多弹时的扇形张角
	"pierce": 0,                  # 可额外穿透的敌人数
	"proj_speed": 640.0,
	"proj_life": 1.1,             # 投射物存活(s)
	"dodge_distance": 150.0,      # 空格闪避瞬移距离
	"dodge_cooldown": 2.2,        # 闪避冷却
	"chain_count": 0,             # 电击链额外跳跃次数
	"chain_range": 115.0,         # 电击链跳跃范围
	"orbit_count": 0,
	"orbit_radius": 54.0,
	"orbit_damage": 18.0,
	"orbit_speed": 2.8,
	"pickup_radius": 30.0,        # 直接拾取半径
	"attract_radius": 110.0,      # 经验球被吸附的半径
	"invuln_time": 0.45,          # 受击后无敌时间
}

# ---------------------------------------------------------------- 丧尸

## 丧尸变体表。美术层面目前共用同一套 Kenney 帧（见 zombie.gd 的 _frames_for），
## 数值层面是五种定位。
##
## ⚠ **anchor 是实测值，不是从公式推的。** 素材换过两轮：
##   CraftPix 128px 横条表（内容只占帧高约 50%）-> Kenney 43px 角色（内容填满整幅）。
## 旧值 y=-64 是 -128/2，给横条表算的；沿用到 43px 的帧上，
## 脚底会停在 -64+21.5 = -42.5px —— 悬在判定圈上方四十多像素，
## 一眼就能看出"贴图和碰撞圈对不上"。
##
## 现值口径（tools 里对 assets/characters/kenney 逐帧做过 alpha 包围盒分析）：
##   画布 33~51 x 43，内容 bbox y=[0,42]、**脚底贴画布底**、内容填满 43px
##   => offset.y = -43/2 = -21.5，让脚底落在节点原点
##   水平：内容水平中心与画布中心相差 0.5~1.0px，取实测值做微调
## 这个值与首领的 Vector2(0.0, -21.5)、人类反派的 GROUND_Y-21.5 是同一套口径。
const ZOMBIE_VARIANTS := [
	# ⚠ 五个变体**共用同一套 Kenney 帧**（见 zombie.gd 的 _frames_for），
	# 所以 tint 是唯一的兵种视觉标识，必须拉得开。
	# 旧值（0.82/1.0/0.86、1.0/0.93/0.78…）差异只有几个百分点，
	# 叠在 43px 的小图上完全看不出区别 —— 等于五种丧尸长一个样。
	# 现在按兵种性格给出高辨识度的色相：
	#   普通=灰绿(基准) 疾行=冷青 壮尸=暖黄 坦克=暗红 机枪尸=紫
	{
		"sheet": 1, "label": "普通", "radius": 12.0,
		"hp_mult": 1.0, "speed_mult": 1.0, "damage_mult": 1.0, "xp": 1.0,
		"scale_mult": 1.0, "tint": Color(0.88, 0.95, 0.88),
		"anchor": Vector2(0.0, -28.0), "weight": 62.0,
	},
	{
		"sheet": 2, "label": "疾行者", "radius": 11.0,
		"hp_mult": 0.75, "speed_mult": 1.35, "damage_mult": 0.8, "xp": 1.0,
		"scale_mult": 0.95, "tint": Color(0.62, 0.92, 1.00),
		"anchor": Vector2(0.0, -28.0), "weight": 22.0,
	},
	{
		"sheet": 3, "label": "壮尸", "radius": 14.0,
		"hp_mult": 1.9, "speed_mult": 0.82, "damage_mult": 1.5, "xp": 3.0,
		"scale_mult": 1.1, "tint": Color(1.00, 0.84, 0.48),
		"anchor": Vector2(0.0, -28.0), "weight": 12.0,
	},
	{
		"sheet": 4, "label": "坦克", "radius": 17.0,
		"hp_mult": 4.2, "speed_mult": 0.62, "damage_mult": 2.0, "xp": 7.0,
		"scale_mult": 1.28, "tint": Color(1.00, 0.58, 0.52),
		"anchor": Vector2(0.0, -28.0), "weight": 4.0,
	},
	{
		# 第 5 种：机枪尸（远程）。与前四只共用同一套 Kenney 帧 —— 见
		# zombie.gd 的 _frames_for，它目前对所有非首领变体返回
		# kenney_zombie_frames()，"sequence" 键还没有被读取。
		#
		# ⚠ scale_mult 从 0.7132 改成 1.0：旧值是"129px 序列帧缩到 46px"
		# 的算法，而素材早已换成 43px 的 Kenney 帧。再乘 0.7132 会让这只
		# 变成全场最矮的丧尸（约 31px），比它该有的"重型单位"定位小了一圈。
		# 想给它更大的体型，应该调 radius / ELITE_SIZE_MULT 那一层，
		# 而不是留一个属于另一套素材的缩放系数。
		"sheet": 0, "label": "机枪尸", "radius": 16.0,
		"hp_mult": 2.4, "speed_mult": 0.72, "damage_mult": 1.1, "xp": 4.0,
		"scale_mult": 1.0, "tint": Color(0.86, 0.72, 1.00),
		"weight": 9.0,
		"sequence": "gunner",
		# anchor 口径与其余四只一致（43px Kenney 帧，实测 -21.5）。
		"anchor": Vector2(0.0, -28.0),
		# 远程参数。伤害 = 该丧尸的近战伤害 × damage_scale。
		# range 取 380：明显小于 LOD 分界（约 824px），
		# 所以"能打到你的机枪尸"必定在画面里，不会出现视野外冷枪。
		"ranged": {"range": 380.0, "interval": 1.6, "speed": 340.0, "damage_scale": 0.6},
	},
	# ---- 阶段1 新增的四种行为怪 ----
	# 行为差异集中在 variant["behavior"]，由 zombie.gd 的对应 _tick_* 实现。
	# 普通池怪（weight > 0）按 min_wave 逐步解锁；weight = 0 的只能被特殊入口刷出
	# （溺亡者只从水域浮出，见 main 的水域刷怪，阶段3接入）。
	{
		# 快速近战怪：撕裂者。血薄、贴身速度快，中距离会先停半拍蓄力再扑咬——
		# 与疾行者的差别在于"冲刺扑咬"这个动作本身，而不是单纯跑得快。
		"sheet": 0, "label": "撕裂者", "radius": 11.0,
		"hp_mult": 0.6, "speed_mult": 1.05, "damage_mult": 0.9, "xp": 2.0,
		"scale_mult": 0.92, "tint": Color(1.0, 0.45, 0.62),
		"sprite": "ripper",
		# 阶段2 自制素材：64px 画布、内容 43px 高、脚底贴画布底、水平居中
		# → anchor 与 Kenney 同口径（脚底落在节点原点），水平无需修正。
		"anchor": Vector2(0.0, -32.0), "weight": 7.0, "min_wave": 3,
		"behavior": "ripper",
		"lunge": {"range_min": 130.0, "range_max": 310.0, "windup": 0.32,
			"dash": 0.20, "dash_mult": 3.4, "damage_mult": 1.3, "cooldown": 2.6},
	},
	{
		# 远程怪：喷吐者。射程比机枪尸更远、弹速更慢（躲得开），
		# 玩家贴近时会后撤拉距离（kiting）—— 是唯一会"倒着走"的丧尸。
		"sheet": 0, "label": "喷吐者", "radius": 13.0,
		"hp_mult": 1.4, "speed_mult": 0.78, "damage_mult": 1.0, "xp": 3.0,
		"scale_mult": 1.05, "tint": Color(0.55, 1.0, 0.55),
		"sprite": "spitter", "anchor": Vector2(0.0, -32.0),
		"weight": 6.0, "min_wave": 4,
		"behavior": "spitter",
		"kite_dist": 190.0,
		"ranged": {"range": 430.0, "interval": 2.2, "speed": 250.0, "damage_scale": 0.9},
	},
	{
		# 重型怪：重锤。最肉、最慢、受击不硬直（叠甲的意义），
		# 贴身时蓄力砸地，蓄力期间脚下出现扩散红圈预警，砸中范围圆形 AoE。
		"sheet": 0, "label": "重锤", "radius": 18.0,
		"hp_mult": 5.0, "speed_mult": 0.55, "damage_mult": 1.6, "xp": 8.0,
		"scale_mult": 1.35, "tint": Color(0.72, 0.62, 0.55),
		"sprite": "smasher", "anchor": Vector2(0.0, -32.0),
		"weight": 3.5, "min_wave": 6,
		"behavior": "smasher",
		"slam": {"trigger": 125.0, "radius": 120.0, "windup": 0.55,
			"damage_mult": 1.8, "cooldown": 4.5},
	},
	{
		# 水域怪：溺亡者。不进常规刷怪池（weight = 0），只从水域浮出（阶段3）。
		# 在水里速度上浮、离水下沉——从水域里爬出来追人时明显变慢，
		# 给玩家"下水道的东西没那么灵活"的观感，也让水域成为它们的巢。
		"sheet": 0, "label": "溺亡者", "radius": 12.0,
		"hp_mult": 1.1, "speed_mult": 0.95, "damage_mult": 1.0, "xp": 2.0,
		"scale_mult": 1.0, "tint": Color(0.45, 0.85, 0.95),
		"sprite": "drowned", "anchor": Vector2(0.0, -32.0),
		"weight": 0.0,
		"behavior": "drowned",
		"water_speed_mult": 1.3, "land_speed_mult": 0.85,
	},
]

# ---------------------------------------------------------------- 首领序列帧

## 首领序列帧（assets/characters/boss/sequence/<anim>/*.png）的当前尺寸。
##
## 这套素材和 CraftPix 那套是两种东西：
##   CraftPix  128px 横条精灵表，用 AtlasTexture 按 128 切帧，**帧内角色只占约 50% 高**；
##   首领      每帧一张整图，**角色填满整幅**（实测包围盒就是整帧）。
##
## 所以上面 ZOMBIE_VARIANTS 里那些为 128px 帧算好的 anchor、
## 以及 zombie.gd spawn() 里那套 scale 公式，对它**一律不适用** ——
## 必须按帧的真实尺寸另算，否则会同时错在尺寸和锚点上（见下面两个常量）。
##
## 尺寸历史：素材原本是 540x655（23MB），但只渲染 110px 高 ——
## 纹理内存浪费 6 倍以上。已用 tools/downsample_boss.py 按 0.35 降到 189x229：
##   磁盘 21.8MB -> 4.5MB，未压缩纹理 1381KB/帧 -> 169KB/帧（降到 12%）。
## 189x229 在渲染 110px 时采样比仍有 1:2.08 余量，肉眼与原始无差别。
## 原始高分辨率帧**已无副本**（降采样是原地覆盖），所以这里别再想改回去。
const BOSS_FRAME_SIZE := Vector2(189.0, 229.0)

## 首领的目标屏幕高度(px)。
##
## 这个数是从**代码里已有的首领血条几何**反推出来的，不是估的。
## zombie.gd 的 _draw() 给首领写死了 width=72 / y=-142，而精英是 width=42 / y=-102。
## 精英那组值经实测校准过（精英坦克角色高 64.5px、脚底贴地、血条 -102），
## 于是首领的尺寸有两个**互相独立**的推算：
##
##   按血条宽度：64.5 × 72/42 = 110.6px
##   按血条位置：精英血条下沿距头顶 30px；首领血条 y=-142 下沿是 -137，
##               留同样的空隙 -> 头顶 ≈ -107 -> 高 = 107px
##
## 两个数字都指向 110，取 110。这也让 -142 那个血条位置**原样保留即可**
## （头顶 -110、血条下沿 -137，空隙 27px，与精英的 30px 一致）。
## 反过来说：改这个常量就必须跟着改那个 y，两者是一对。
##
## ⚠ 别用"帧高 × 缩放"去推首领尺寸 —— 这是最初的错法。
## CraftPix 那套 128px 帧里**角色只占约 50% 高**（实测普通丧尸角色屏幕高 32.3px，
## 与 ZOMBIE_SCALE 注释里的"约 33px"吻合），而首领的序列帧里角色是**填满整幅**的。
## 两种素材的"帧高"根本不可比：沿用 1.248 的缩放会得到 655×1.248 = 817px，
## 比 720px 的视口还高，而且锚点也是照 128px 帧算的（见 BOSS_ANCHOR）。
const BOSS_TARGET_HEIGHT := 110.0

## 首领精灵的缩放。目标高度 ÷ 序列帧原始高度。
const BOSS_SCALE := BOSS_TARGET_HEIGHT / BOSS_FRAME_SIZE.y

## 首领精灵的锚点偏移，与 128px 精灵表同一套口径（见 tools/analyze_sprites.py）：
##
##     offset = (帧宽/2 - 角色水平中心, 帧高/2 - 脚底行)
##
## 效果是**脚底落在节点原点** —— 和 ZOMBIE_VARIANTS 里 -64（= -128/2）
## 对 128px 帧做的事完全一样。
##
## 实测（tools 里量出来的）：原始 540x655 帧上脚底行恒为 655（= 帧底，0px 漂移）、
## 水平中心 276.8（帧中心 270）。降采样到 0.35 后**重新实测**，得到：
##     脚底行   228.0（idle/walk 的极差都是 0，说明贴地稳定）
##     水平中心 96.1~96.7（idle/walk 极差 1~10px）
## 取水平中心 96.4、脚底行 228.0，所以：
##     offset = (189/2 - 96.4, 229/2 - 228.0) = (0.1, -113.5)
##
## **y 必须按帧高算，不能用 -64。** -64 是给 128px 帧算的，
## 沿用到这个帧上，纹理居中绘制后脚底会沉进地面 —— 只露出上半身。
##
## 换公式时注意：这两个实测值是**在某一档缩放上量出来的**，
## 以后若再动 BOSS_FRAME_SIZE，必须重跑 tools/downsample_boss.py 并重新量，
## 不能简单地按比例乘（取整误差会在像素级偏离）。
const BOSS_ANCHOR := Vector2(
	BOSS_FRAME_SIZE.x * 0.5 - 96.4,
	BOSS_FRAME_SIZE.y * 0.5 - 228.0
)

## ---- 阶段1：首领强化参数 ----

## 首领在 HUD 血条上的显示名。
const BOSS_DISPLAY_NAME := "腐烂巨兽"

## ---- 阶段2：自制怪物精灵 ----
##
## Blender 程序化建模 + 正交俯拍渲染 + PIL 归一化（描边/阴影统一在 PIL 里做），
## 生成管线存档见 workspace monster_render/（build_monsters.py / normalize_sprites.py）。
## 素材为近中性灰基色，游戏内由 variant["tint"] 染色 —— 与 Kenney 旧怪共用
## 同一套"兵种色"识别系统，保证全队色调统一。
##
## content_h = 素材里角色的实际像素高（脚底贴画布底）。非 Boss 统一 43，
## 与 Kenney 帧同高，zombie.gd 的既有缩放数学原样适用；
## Boss 内容 120，首领缩放 = BOSS_TARGET_HEIGHT / content_h。
const MONSTER_SPRITES := {
	"ripper": {"path": "res://assets/characters/monsters/ripper.png", "canvas": 64.0, "content_h": 43.0},
	"spitter": {"path": "res://assets/characters/monsters/spitter.png", "canvas": 64.0, "content_h": 43.0},
	"smasher": {"path": "res://assets/characters/monsters/smasher.png", "canvas": 64.0, "content_h": 43.0},
	"drowned": {"path": "res://assets/characters/monsters/drowned.png", "canvas": 64.0, "content_h": 43.0},
	"boss_abomination": {"path": "res://assets/characters/monsters/boss_abomination.png", "canvas": 256.0, "content_h": 120.0},
}

## 首领阶段阈值：血量比例降到该值以下进入下一阶段（1 → 2 → 3）。
const BOSS_PHASE_2_AT := 0.66
const BOSS_PHASE_3_AT := 0.33

## 各阶段的移动速度倍率（乘在出怪波次速度上）。阶段 3 是狂暴态。
const BOSS_PHASE_SPEED := [1.0, 1.18, 1.38]

## 各阶段冲锋冷却（秒）。阶段 1 才有冲锋的话压不了场，从 1 就会冲。
const BOSS_PHASE_CHARGE_CD := [4.2, 3.2, 2.2]

## 阶段 2 起首领的召唤间隔（秒），每次在身边召唤 BOSS_SUMMON_COUNT 只普通丧尸。
const BOSS_SUMMON_INTERVAL := 8.0
const BOSS_SUMMON_COUNT := 3

## 阶段 3 解锁的震地 AoE。trigger/radius 是距离与伤害半径(px)。
const BOSS_SLAM := {"trigger": 150.0, "radius": 135.0, "windup": 0.6, "damage_mult": 1.6}

## 首领死亡奖励：经验球数量与单颗经验范围。
const BOSS_REWARD_GEMS := 10
const BOSS_REWARD_XP := [4.0, 9.0]

## 变体外观抽取用的独立随机源。
##
## 刻意与全局 RNG 隔离：全局 RNG 驱动刷怪/升级抽卡（决定游戏进程），
## 而这个只决定"这只丧尸长什么样"（纯表现）。两边混在一起的话，
## 改一个 LOD 参数都会改变外观序列，做性能对比时就没法确认变量了。
##
## 声明成 var 而不是 const 是必须的：RandomNumberGenerator 有内部状态，
## GDScript 的 const 只接受真正的常量表达式。
var variant_rng := RandomNumberGenerator.new()


## 给外观随机源设种。由 Main 在 --seed 时调用，保证同一颗种子跑出同一批外观。
func seed_variants(s: int) -> void:
	variant_rng.seed = s


## 为一只丧尸抽一份外观修正。返回 {scale, tint, radius}，全是相对倍率。
##
## 抽取顺序固定（缩放 → 明度 → 色相），所以给定同一个 rng 状态，
## 结果完全可复现。
func roll_zombie_look() -> Dictionary:
	var scale_mult := 1.0 + variant_rng.randf_range(-VARIANT_SCALE_JITTER, VARIANT_SCALE_JITTER)

	# 明度整体压暗/提亮：尸群里有晒得发白的、也有泡烂发黑的
	var v_mult := 1.0 + variant_rng.randf_range(-VARIANT_TINT_JITTER, VARIANT_TINT_JITTER)

	# 色相偏移：往青绿（腐烂）和紫红（淤血）两头偏，
	# 而不是全色环乱转 —— 后者会出现粉红色丧尸，破坏题材。
	var hue_shift := variant_rng.randf_range(-VARIANT_HUE_JITTER, VARIANT_HUE_JITTER)

	return {
		"scale_mult": scale_mult,
		"tint_shift": Color(v_mult, v_mult * (1.0 + hue_shift * 0.35), v_mult * (1.0 - hue_shift * 0.30)),
		"radius_mult": 1.0 + (scale_mult - 1.0) * VARIANT_RADIUS_TRACK,
	}

## 丧尸基础值（乘以变体倍率与波次倍率后才是实际值）
## 血量刻意设成 12 = 初始武器单发伤害，让第一波"一枪一个"，
## 这个手感是割草游戏开局的爽点来源，后面再靠波次倍率把它压回去。
const ZOMBIE_BASE_HP := 12.0
## 玩家速度的 0.35 倍：能风筝、但甩不掉，这个比例是这类游戏的核心手感
const ZOMBIE_BASE_SPEED := 82.0
const ZOMBIE_BASE_DAMAGE := 6.0

## 攻击距离 = 自身半径 + 玩家半径 + 这个余量
const ZOMBIE_ATTACK_PADDING := 4.0
## 同一只丧尸的攻击间隔
const ZOMBIE_ATTACK_INTERVAL := 0.9
## 受击硬直（播放 Hurt 动画、暂停移动）
const ZOMBIE_HURT_STAGGER := 0.16
## 死亡动画时长，播完后回收
const ZOMBIE_DEATH_LINGER := 0.8

## 丧尸与人类反派"贴身互殴"的结算间隔(s)。
##
## 原来是每帧结算 `take_damage(12.0 * delta)`，这有两个后果：
## 1. 每帧都触发丧尸的受击硬直（_stagger 被刷新），贴到人类的丧尸
##    被永久钉在 hurt 状态，动不了也咬不到人 —— 属于隐蔽的行为 bug。
## 2. 每帧刷一次 "-1" 伤害数字和命中音，纯视觉噪声。
## 改成离散"一口"结算，语义也对：丧尸咬人本就不是每秒 60 口的连续掉血。
const FACTION_MELEE_INTERVAL := 0.5
const FACTION_MELEE_DAMAGE_TO_HUMAN := 12.0
const FACTION_MELEE_DAMAGE_TO_ZOMBIE := 8.0

## 邻近分离权重：丧尸之间互相推开的力度，避免叠成一坨。
## 越大越不容易重叠，但太大会让它们绕开玩家、看起来不像在追人。
## 手感区间大概 0.8 ~ 1.5。
const SEPARATION_WEIGHT := 1.15

## 分离力最多采样多少个邻近同伴。
##
## 为什么必须有这个上限：分离判定本来是 O(n)，但**同一格里挤了上百只**时会退化成 O(n²)。
## 两种情况下必然发生：玩家被尸群围住、玩家阵亡后全场涌向同一具尸体。
## 实测 220 只挤成一坨时，单帧光这一项就要 6.3ms（60fps 全帧预算才 16ms），
## 直接掉到 15fps 以下 —— 而这恰恰是玩家最紧张、最不能卡的时刻。
##
## 分离力本身是"越近推力越大"的线性衰减，取十几只和取全部，画面几乎看不出差别，
## 但复杂度从 O(n²) 掉到 O(n·16)。
const SEPARATION_NEIGHBOR_CAP := 16

# ---------------------------------------------------------------- 分帧调度(LOD)

## 视野外缓冲带宽度(px)。
##
## 分界线 = 视口对角线的一半 + 这个值。缓冲带的意义是：任何"即将进入视野"的
## 丧尸都已经回到每帧更新，玩家不会在画面边缘看到它一跳一跳地飘进来。
## 别调太小 —— 边界上的丧尸会看起来像在瞬移。
const LOD_MARGIN := 90.0

## 视野外丧尸每几帧更新一次。
##
## 3 帧 = 50ms，这段时间它最多挪 4px，而且本来就在屏幕外。
## 注意位置不是"少走"而是"攒着一起走"：tick 时传入 delta × LOD_PERIOD，
## 累积位移和每帧更新完全相等，纯赚。
const LOD_PERIOD := 3

# ---------------------------------------------------------------- 波次

const WAVE_DURATION := 25.0            # 每波持续秒数
const SPAWN_INTERVAL_START := 1.10     # 第一波刷怪间隔(s)，给开局更多走位时间
const SPAWN_INTERVAL_DECAY := 0.95     # 每波乘数，前期加速更平滑
const SPAWN_INTERVAL_MIN := 0.07       # 间隔下限
const SPAWN_BATCH_START := 2           # 第一波每次刷几只
const SPAWN_BATCH_PER_WAVE := 0.28     # 每波增加的小数部分
const MAX_ALIVE := 520                 # 同屏上限，保护帧率
const WAVE_HP_GROWTH := 0.36           # 每波血量乘数增量
const WAVE_SPEED_GROWTH := 0.035       # 每波速度乘数增量
const WAVE_SPEED_CAP := 1.65
const WAVE_DAMAGE_GROWTH := 0.11       # 每波伤害乘数增量
const ELITE_EVERY_WAVES := 5           # 每几波刷一只精英
const BOSS_EVERY_WAVES := 10           # 每几波出现首领
const ELITE_STAT_MULT := 6.0           # 精英的血量/伤害倍率

## ---- 阶段3：水域 ----

## 每局生成几片水域。
const WATER_ZONE_COUNT := 4
## 水域与其他掉落物/彼此的最小间距（用于 _random_loot_position 的占位表）。
const WATER_ZONE_SPACING := 420.0
## 非水生单位在水中乘在移动上的速度倍率。0.55 = 明显拖慢但能穿行，
## 水域是"可以借道的危险地形"而不是墙。
const WATER_SLOW := 0.55
## 各水域的孵化间隔基准（实际按 0.85~1.25 随机浮动，开局再各错开一截）。
const WATER_SPAWN_INTERVAL := 9.0
## 浮出预警时长：涟漪收缩圈给玩家的反应窗口。
const WATER_TELEGRAPH := 0.9
## 场上同时存活的溺亡者上限（全局，跨水域合计）。
const WATER_MAX_DROWNED := 6

## 刷怪环半径 = 视口对角线/2 + 这个余量，保证在视野外生成。
## 别调太大：这个值直接决定"丧尸从出现到走到你面前"要多久，
## 太大开局会有十几秒无事可做的冷场。
const SPAWN_RING_MARGIN := 110.0

# ---------------------------------------------------------------- 经验

const XP_BASE := 7.0                    # 第一档升级约需要 7 只普通丧尸
const XP_GROWTH := 1.20                 # 等级越高需求增长更明显

## 场上同时存在的经验球上限。
##
## 为什么必须有这个上限：玩家被尸群围住时根本走不到掉落点，经验球会一直堆。
## 堆到几百上千个之后，每帧遍历它们本身就变成主要开销，而且画面上全是绿点。
## 超过上限时，把最早掉落的那颗改成"强制吸附"——它会自己飞向玩家，
## 既清理了场，又不会让玩家真的损失经验。
const MAX_GEMS := 240

# ---------------------------------------------------------------- 升级池

## op: "add" 加算 / "mul" 乘算。max 是最大叠加次数。
##
## desc 里写的是**相对倍率**（"+25%" 这种），但卡片上显示的会是真实数值变化
## （"12.0 → 15.0"）。见 ui/upgrade_menu.gd 的 _format_delta ——
## 玩家看得出"这个技能到底强了多少"，而不是只看到百分比。
const UPGRADE_POOL := [
	{"id": "damage", "name": "腐蚀弹药", "desc": "伤害 +25%",
	 "stat": "damage", "op": "mul", "value": 1.25, "max": 10,
	 "unit": "", "decimals": 1, "color": Color(0.85, 0.30, 0.25)},
	{"id": "move_speed", "name": "轻装逃亡", "desc": "移动速度 +12%",
	 "stat": "move_speed", "op": "mul", "value": 1.12, "max": 8,
	 "unit": "", "decimals": 0, "color": Color(0.35, 0.65, 0.85)},
	{"id": "max_hp", "name": "强健体魄", "desc": "最大生命 +25，并立即回复等量生命",
	 "stat": "max_hp", "op": "add", "value": 25.0, "heal": true, "max": 8,
	 "unit": "", "decimals": 0, "color": Color(0.30, 0.72, 0.42)},
	{"id": "multishot", "name": "多发弹匣", "desc": "每次射击 +1 发",
	 "stat": "projectiles", "op": "add", "value": 1.0, "max": 6,
	 "unit": "发", "decimals": 0, "color": Color(0.60, 0.45, 0.85)},
	{"id": "shotgun", "name": "霰弹枪改装", "desc": "每次射击 +2 发，散布扩大",
	 "stat": "projectiles", "op": "add", "value": 2.0, "max": 99,
	 "unit": "发", "decimals": 0, "color": Color(0.95, 0.42, 0.20), "also": {"spread_deg": 1.8}},
	{"id": "chain_amp", "name": "电容增幅", "desc": "电击额外跳跃 1 次，范围 +18%",
	 "stat": "chain_count", "op": "add", "value": 1.0, "max": 99,
	 "unit": "个", "decimals": 0, "color": Color(0.25, 0.68, 0.95), "also": {"chain_range": 1.18}},
	{"id": "weakpoint", "name": "弱点扫描", "desc": "暴击率 +8%，暴击伤害 +10%",
	 "stat": "crit_chance", "op": "add", "value": 0.08, "max": 99,
	 "unit": "%", "decimals": 0, "color": Color(1.0, 0.50, 0.20), "also": {"crit_multiplier": 1.10}},
	{"id": "pierce", "name": "穿甲弹头", "desc": "子弹可多穿透 1 个敌人",
	 "stat": "pierce", "op": "add", "value": 1.0, "max": 5,
	 "unit": "个", "decimals": 0, "color": Color(0.80, 0.50, 0.70)},
	{"id": "proj_speed", "name": "高压枪管", "desc": "子弹速度 +22%",
	 "stat": "proj_speed", "op": "mul", "value": 1.22, "max": 5,
	 "unit": "", "decimals": 0, "color": Color(0.75, 0.75, 0.35)},
	{"id": "field_magnet", "name": "磁场增幅", "desc": "经验吸附范围 +25%",
	 "stat": "attract_radius", "op": "mul", "value": 1.25, "max": 99,
	 "unit": "", "decimals": 0, "color": Color(0.34, 0.88, 0.76), "also": {"pickup_radius": 1.12}},
	{"id": "hard_shell", "name": "复合护甲", "desc": "受伤无敌时间 +12%",
	 "stat": "invuln_time", "op": "mul", "value": 1.12, "max": 99,
	 "unit": "s", "decimals": 2, "color": Color(0.46, 0.58, 0.72)},
]

## 数值下限，防止乘算把值压到 0 或负数
const STAT_FLOOR := {
	"cooldown": 0.07,
	"damage": 0.5,
	"crit_chance": 0.0,
	"crit_multiplier": 1.0,
	"projectiles": 1.0,
	"pierce": 0.0,
	"proj_speed": 120.0,
	"spread_deg": 1.0,
	"chain_count": 0.0,
	"chain_range": 1.0,
	"orbit_count": 0.0,
	"orbit_radius": 1.0,
	"orbit_damage": 0.5,
	"orbit_speed": 0.1,
	"range": 50.0,
	"invuln_time": 0.05,
	"move_speed": 60.0,
	"max_hp": 10.0,
}

# ---------------------------------------------------------------- 数值显示

## 属性 → 显示名 + 单位 + 小数位。给 HUD 和升级卡片统一格式用。
##
## 集中在一处的原因：同一个属性在三个地方显示（升级卡、HUD、结算），
## 单位和小数位散落在各处的话，"1.50s" 和 "1.5 秒" 会同时出现在屏幕上。
const STAT_FORMAT := {
	"damage":        {"label": "伤害",     "unit": "",   "decimals": 1},
	"crit_chance":   {"label": "暴击率",   "unit": "%",  "decimals": 0},
	"crit_multiplier": {"label": "暴击倍率", "unit": "x", "decimals": 2},
	"cooldown":      {"label": "开火间隔", "unit": "s",  "decimals": 2},
	"move_speed":    {"label": "移速",     "unit": "",   "decimals": 0},
	"max_hp":        {"label": "生命上限", "unit": "",   "decimals": 0},
	"projectiles":   {"label": "弹数",     "unit": "发", "decimals": 0},
	"pierce":        {"label": "穿透",     "unit": "个", "decimals": 0},
	"pickup_radius": {"label": "拾取范围", "unit": "",   "decimals": 0},
	"proj_speed":    {"label": "子弹速度", "unit": "",   "decimals": 0},
	"spread_deg":    {"label": "散布角度", "unit": "°",   "decimals": 1},
	"chain_count":   {"label": "电击跳数", "unit": "个",  "decimals": 0},
	"chain_range":   {"label": "电击范围", "unit": "",   "decimals": 0},
	"orbit_count":   {"label": "飞刃数量", "unit": "把",  "decimals": 0},
	"orbit_damage":  {"label": "飞刃伤害", "unit": "",   "decimals": 1},
	"range":         {"label": "索敌范围", "unit": "",   "decimals": 0},
	"invuln_time":   {"label": "无敌时间", "unit": "s",  "decimals": 2},
}


## 按 STAT_FORMAT 把某个属性值格式化成可读字符串。
## 取不到格式定义时退回"一位小数"，至少不会崩。
func format_stat(stat: String, value: float) -> String:
	if not STAT_FORMAT.has(stat):
		return "%.1f" % value
	var f: Dictionary = STAT_FORMAT[stat]
	return "%.*f%s" % [int(f["decimals"]), value, String(f["unit"])]


## 计算某个升级应用后的新数值（不真的改，只用来显示 "12.0 → 15.0"）。
## 逻辑必须与 player.apply_upgrade 完全一致，否则卡片会骗人。
func preview_stat(stats: Dictionary, upgrade: Dictionary) -> float:
	var stat := String(upgrade["stat"])
	if not stats.has(stat):
		return 0.0
	var current := float(stats[stat])
	var value := float(upgrade["value"])
	var op := String(upgrade["op"])
	if op == "add":
		current += value
	elif op == "mul":
		current *= value
	if STAT_FLOOR.has(stat):
		current = maxf(current, float(STAT_FLOOR[stat]))
	return current

# ---------------------------------------------------------------- 缓存

var _frames_cache: Dictionary = {}

## 序列帧缓存，key 是角色名（如 "gunner"）。
var _sequence_cache: Dictionary = {}


func _ready() -> void:
	_ensure_input_actions()


## 在代码里注册输入动作，而不是写进 project.godot 的 [input] 段。
## 原因：project.godot 里那串 Object(InputEventKey, ...) 序列化格式很脆，
## 手写容易出错；代码注册是版本无关的，而且以后要做按键重映射也方便。
func _ensure_input_actions() -> void:
	var defs := {
		"move_up":       [KEY_W, KEY_UP],
		"move_down":     [KEY_S, KEY_DOWN],
		"move_left":     [KEY_A, KEY_LEFT],
		"move_right":    [KEY_D, KEY_RIGHT],
		"restart":       [KEY_R],
		"toggle_debug":  [KEY_F3],
		"toggle_fire":   [KEY_F],
		"pause":         [KEY_ESCAPE],
		"fire_manual":   [],
		"dodge":         [KEY_SPACE],
		"sprint":        [KEY_SHIFT],
	}
	for action: String in defs:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for keycode: int in defs[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------- 查询函数

## 升到 level 级时，升下一级需要多少经验
func xp_for_level(level: int) -> float:
	return XP_BASE * pow(XP_GROWTH, level - 1)


## 第 wave 波的刷怪间隔
func spawn_interval(wave: int) -> float:
	return maxf(SPAWN_INTERVAL_MIN, SPAWN_INTERVAL_START * pow(SPAWN_INTERVAL_DECAY, wave - 1))


## 第 wave 波每次刷几只
func spawn_batch(wave: int) -> int:
	return SPAWN_BATCH_START + int(floor((wave - 1) * SPAWN_BATCH_PER_WAVE))


## 第 wave 波丧尸血量倍率
func wave_hp_mult(wave: int) -> float:
	return 1.0 + WAVE_HP_GROWTH * (wave - 1)


## 第 wave 波丧尸速度倍率（有上限，否则后期会变成贴脸秒杀）
func wave_speed_mult(wave: int) -> float:
	return minf(WAVE_SPEED_CAP, 1.0 + WAVE_SPEED_GROWTH * (wave - 1))


## 第 wave 波丧尸伤害倍率
func wave_damage_mult(wave: int) -> float:
	return 1.0 + WAVE_DAMAGE_GROWTH * (wave - 1)


## 按权重随机挑一个丧尸变体。
##
## wave 用于行为怪的逐步解锁：变体表里的 min_wave 没到就不进候选池，
## 前几波的威胁梯度才平滑（第 1 波只会遇到普通丧尸和疾行者）。
## weight <= 0 的变体（溺亡者）永远不会被抽中，只能由水域等特殊入口刷出。
func pick_zombie_variant(wave: int = 1) -> Dictionary:
	var pool: Array = []
	var total := 0.0
	for v: Dictionary in ZOMBIE_VARIANTS:
		if float(v["weight"]) <= 0.0:
			continue
		if wave < int(v.get("min_wave", 1)):
			continue
		pool.append(v)
		total += float(v["weight"])
	if pool.is_empty():
		return ZOMBIE_VARIANTS[0]
	var roll := randf() * total
	for v: Dictionary in pool:
		roll -= float(v["weight"])
		if roll <= 0.0:
			return v
	return pool[0]


## 按显示名取变体（水域孵化溺亡者用）。找不到退回普通丧尸，不中断游戏。
func variant_by_label(label: String) -> Dictionary:
	for v: Dictionary in ZOMBIE_VARIANTS:
		if String(v.get("label", "")) == label:
			return v
	return ZOMBIE_VARIANTS[0]


## 取得（并缓存）某个丧尸的 SpriteFrames。
## 四种丧尸各建一次，之后所有同类实例共用同一份 —— 几百只丧尸不会重复切图。
func zombie_frames(sheet_id: int) -> SpriteFrames:
	if _frames_cache.has(sheet_id):
		return _frames_cache[sheet_id]
	var sf := _build_frames(sheet_id)
	_frames_cache[sheet_id] = sf
	return sf


## 取得（并缓存）某个角色的整幅序列帧。
##
## 与 zombie_frames() 的分工：
##   zombie_frames()   CraftPix 那套 —— 128px 横条精灵表，用 AtlasTexture 按 128 切帧；
##   sequence_frames() 自研素材 —— 每帧一张整图（如 192x192），背景已抠成透明，
##                     由 tools/build_sequence.py 产出。
##
## 两者不能混用：横条表的"帧高"是 128、帧内角色只占约 50% 高；
## 序列帧的"帧高"是整张画布、角色填满。缩放和锚点必须各自算。
##
## 缓存放在 GameData（全局）而不是 Zombie 实例上：
## 池化的 Zombie 会有几百个实例，缓存挂在实例上等于每个用过序列帧的实例
## 都重新 load 一遍 SpriteFrames。
func sequence_frames(name: String) -> SpriteFrames:
	if _sequence_cache.has(name):
		return _sequence_cache[name]
	var sf := _build_sequence_frames(name, ZOMBIE_SEQ_PLANS, "attack")
	_sequence_cache[name] = sf
	return sf


## 玩家序列帧。走同一条加载器，只是动画集和退回目标不同（见 PLAYER_SEQ_PLANS）。
##
## 素材是「女主2-1 ~ 2-12」整套 12 个动作（12 套、281 帧），
## 用 tools/build_sequence.py 统一 scale 处理过 —— 所以切换动画时体型和站位
## 都不会跳（实测跨动画水平中心差 1px、脚底差 2px，画布内）。
func player_frames() -> SpriteFrames:
	const KEY := "player"
	if _sequence_cache.has(KEY):
		return _sequence_cache[KEY]
	var sf := _build_kenney_frames("survivor1")
	_sequence_cache[KEY] = sf
	return sf


## 统一的俯视角角色帧。
## Kenney Top-down Shooter 的 Survivor / Zombie / Robot 使用相同画布尺寸、
## 相同像素密度和相同朝向；用不同角色皮肤区分阵营，避免玩家、丧尸和首领
## 看起来像来自三个不同的素材包。
func kenney_zombie_frames() -> SpriteFrames:
	const KEY := "kenney_zombie"
	if _sequence_cache.has(KEY):
		return _sequence_cache[KEY]
	var sf := _build_kenney_frames("zoimbie1")
	_sequence_cache[KEY] = sf
	return sf


func kenney_boss_frames() -> SpriteFrames:
	const KEY := "kenney_boss"
	if _sequence_cache.has(KEY):
		return _sequence_cache[KEY]
	var sf := _build_kenney_frames("robot1")
	_sequence_cache[KEY] = sf
	return sf


## 精英专用外观：四帧横向行走表，保持与普通丧尸相同的 SpriteFrames 接口。
## 其它动作沿用这套行走帧，避免精英只在 walk 状态有图而受击时消失。
func elite_zombie_frames() -> SpriteFrames:
	const KEY := "elite_zombie"
	if _sequence_cache.has(KEY):
		return _sequence_cache[KEY]
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	var tex := load(ELITE_ZOMBIE_SHEET_PATH) as Texture2D
	if tex == null:
		return kenney_zombie_frames()
	var frame_width := float(tex.get_width()) / 4.0
	var groups := {
		"idle": [6.0, true], "walk": [8.0, true], "attack": [10.0, false],
		"hurt": [10.0, false], "dead": [7.0, false]
	}
	for anim_name: String in groups:
		var info: Array = groups[anim_name]
		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, float(info[0]))
		sf.set_animation_loop(anim_name, bool(info[1]))
		for i in 4:
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(frame_width * i, 0.0, frame_width, tex.get_height())
			sf.add_frame(anim_name, atlas)
	_sequence_cache[KEY] = sf
	return sf


## 阶段2 自制怪物精灵（单帧）。五个动画状态共用同一帧 ——
## 动起来的责任交给 zombie.gd 已有的那套表现层：行走起伏(wobble)、
## 受击闪白、朝向翻转、蓄力泛红。单帧素材省掉逐动作绘制，
## 视觉活性与 Kenney 旧怪一致。
func monster_frames(key: String) -> SpriteFrames:
	var cache_key := "monster_" + key
	if _sequence_cache.has(cache_key):
		return _sequence_cache[cache_key]
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	var info: Dictionary = MONSTER_SPRITES.get(key, {})
	var tex: Texture2D = load(String(info.get("path", ""))) as Texture2D
	if tex == null:
		push_warning("怪物素材缺失：%s（退回 Kenney 帧）" % key)
		return kenney_zombie_frames()
	var groups := {
		"idle": [6.0, true], "walk": [8.0, true], "attack": [10.0, false],
		"hurt": [10.0, false], "dead": [7.0, false],
	}
	for anim_name: String in groups:
		var gi: Array = groups[anim_name]
		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, float(gi[0]))
		sf.set_animation_loop(anim_name, bool(gi[1]))
		sf.add_frame(anim_name, tex)
	_sequence_cache[cache_key] = sf
	return sf


func _build_kenney_frames(prefix: String) -> SpriteFrames:
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	var base := "res://assets/characters/kenney/"
	var groups := {
		"idle": [["stand"], 6.0, true],
		"walk": [["stand", "hold", "stand", "hold"], 8.0, true],
		"run": [["hold", "machine", "hold", "machine"], 12.0, true],
		"attack": [["gun", "machine", "gun"], 14.0, false],
		"attack_move": [["machine", "hold", "machine"], 14.0, true],
		"dodge": [["hold", "stand"], 12.0, false],
		"hurt": [["stand", "reload"], 10.0, false],
		"hurt2": [["stand", "reload"], 10.0, false],
		"dead": [["reload", "stand"], 7.0, false],
	}
	for anim_name: String in groups:
		var info: Array = groups[anim_name]
		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, float(info[1]))
		sf.set_animation_loop(anim_name, bool(info[2]))
		for pose: String in info[0]:
			var texture := load(base + prefix + "_" + pose + ".png") as Texture2D
			if texture != null:
				sf.add_frame(anim_name, texture)
	return sf


func _build_sequence_frames(name: String, plans: Dictionary, fallback: String) -> SpriteFrames:
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")

	# 素材是分批补的（机枪尸先前只有 attack 与 walk），缺目录时退回
	# 能让角色先跑起来，而不是因为缺一个 idle 就整只不显示。
	# 退回目标由调用方给：丧尸退 attack，玩家退 idle。
	#
	# ⚠ 键名（= SpriteFrames 里的动画名）必须全小写，理由同 ANIM_SETTINGS。
	# 曾经写成 "Idle"/"Walk" 首字母大写，配上 zombie.gd 的小写
	# STATE_WALK，结果 _play("walk") 的守卫恒为 false 直接 return ——
	# 机枪尸明明有 12 帧行走素材，游戏里却一直停在 Idle 上不动。
	var base := "%s%s/sequence" % [ZOMBIE_SEQ_DIR, name]

	var used_fallback := false
	for anim: String in plans:
		var info: Dictionary = plans[anim]
		# 状态名和素材目录名可以不同：素材包里没有的就是没有，
		# 硬造一个目录名只会让人以为素材存在。见 PLAYER_SEQ_PLANS 里 dead 那行。
		var dir_name := String(info.get("dir", anim))
		var dir := "%s/%s" % [base, dir_name]
		var files := _list_png(dir)
		if files.is_empty():
			dir = "%s/%s" % [base, fallback]
			files = _list_png(dir)
			used_fallback = true
		if files.is_empty():
			push_warning("序列帧缺失：%s（连 %s 目录也没有）" % [base, fallback])
			continue

		sf.add_animation(anim)
		sf.set_animation_speed(anim, float(info["fps"]))
		sf.set_animation_loop(anim, bool(info["loop"]))
		for f in files:
			var tex: Texture2D = load(dir + "/" + f)
			if tex != null:
				sf.add_frame(anim, tex)

	if used_fallback:
		push_warning("序列帧 %s 缺部分动画目录，已用 %s/ 顶替" % [base, fallback])
	return sf


## 列出目录下的 PNG，按文件名排序（序列帧靠序号 001/002/... 定顺序，必须排）。
func _list_png(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".png"):
			out.append(f)
	out.sort()
	return out


## 退出时释放精灵表缓存。
## 不清的话 Godot 退出会报 "N resources still in use at exit" ——
## 这不是内存泄漏（进程马上就没了），但会污染日志、掩盖真正的问题。
func clear_cache() -> void:
	_frames_cache.clear()
	_sequence_cache.clear()
	_icon_cache.clear()


func _build_frames(sheet_id: int) -> SpriteFrames:
	var sf := SpriteFrames.new()
	# SpriteFrames 默认自带一个 "default" 动画，删掉，只留我们自己定义的
	if sf.has_animation("default"):
		sf.remove_animation("default")

	for anim: String in ANIM_SETTINGS:
		var info: Dictionary = ANIM_SETTINGS[anim]
		# 用 info["file"] 取贴图，不要用 anim —— 动画名是小写 "walk"，
		# 而贴图叫 Zombie_1_Walk.png。见 ANIM_SETTINGS 的注释。
		var path := "%sZombie_%d_%s.png" % [ZOMBIE_SHEET_DIR, sheet_id, String(info["file"])]
		if not ResourceLoader.exists(path):
			push_warning("缺少精灵表：%s" % path)
			continue

		var tex: Texture2D = load(path)
		var frame_count := int(tex.get_width() / FRAME_SIZE)
		if frame_count <= 0:
			push_warning("精灵表宽度不足一帧：%s" % path)
			continue

		sf.add_animation(anim)
		sf.set_animation_speed(anim, float(info["fps"]))
		sf.set_animation_loop(anim, bool(info["loop"]))

		# 横条精灵表 → 按固定宽高切成 AtlasTexture。
		# 用 AtlasTexture 而不是把图预切成 20 个文件，好处是原图只加载一次。
		for i in frame_count:
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * FRAME_SIZE, 0, FRAME_SIZE, FRAME_SIZE)
			sf.add_frame(anim, at)

	return sf
