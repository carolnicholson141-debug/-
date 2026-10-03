extends CanvasLayer
## 战斗 HUD 与结算界面。
##
## 全部用代码构建 Control 节点，而不是在 .tscn 里摆。
## 理由：HUD 的元素和数值强耦合（血条要跟着 max_hp 变、经验条要跟着升级变），
## 放在代码里改版式是「改一处」，放在场景里是「改场景 + 改取值路径」两处。
##
## HUD 只订阅 Events 信号，从不主动去问玩家节点要数据 —— 双向解耦。

signal restart_requested()
signal resume_requested()

const HP_BAR_SIZE := Vector2(252.0, 24.0)
## 经验条高度。取 20 是为了容下 12px 的数字加描边 ——
## 原来是 10px，放数字会被上下各裁掉一截。
const XP_BAR_HEIGHT := 20.0
const PIXEL_FONT := preload("res://assets/ui/fonts/fusion-pixel-12px-zh-hans.ttf")
const HP_PANEL_ART := preload("res://assets/ui/hud/hp_panel_clean.png")
const INVENTORY_FRAME_ART := preload("res://assets/ui/hud/inventory_frame.png")
# 原图左侧约 20% 是不透明的纯黑留白，不属于卡槽边框。
# 只取实际五格区域，避免右下角出现一块突兀的黑色矩形。
const INVENTORY_FRAME_REGION := Rect2(207.0, 0.0, 807.0, 205.0)
const WAVE_PANEL_ART := preload("res://assets/ui/hud/wave_panel_clean.png")
const CHEST_ICON := preload("res://assets/ui/chest.png")
const POTION_ICON := preload("res://assets/ui/items/potion.png")

var _root: Control
var _hp_bar: ProgressBar
var _hp_label: Label
var _xp_bar: ProgressBar
var _xp_label: Label
var _level_label: Label
var _time_label: Label
var _wave_label: Label
var _wave_timer_label: Label
var _kills_label: Label
var _chest_label: Label
var _potion_label: Label
var _chest_count: int = 0
var _perf_label: Label
var _fire_label: Label
var _wave_banner: PanelContainer
var _wave_banner_label: Label
var _damage_flash: ColorRect
var _upgrade_notice: Label
var _weapon_label: Label
var _weapon_levels: Dictionary = {}
var _elite_alert: Label
var _streak_label: Label
var _streak_count: int = 0
var _streak_left: float = 0.0
var _pause_overlay: Control
var _inventory_label: Label
var _revive_label: Label
var _inventory_slots: Array[Button] = []
var inventory_provider: Callable = Callable()

## 经验条的数字部分。分开存是为了按值/按上限着色，
## 以及让"还差多少升级"那一段更醒目。
var _xp_current: float = 0.0
var _xp_required: float = 1.0

var _over_center: CenterContainer
var _over_title: Label
var _over_stats: Label
var _restart_button: Button

## 由 Main 注入，用于显示池子/帧率等运行状态
var debug_provider: Callable = Callable()
var _debug_visible: bool = false

## ---- 阶段1：首领血条 ----
## 放在**底部居中**：顶部已被经验条(0~24)、时间/波次(17~110)、横幅(74~122)占满，
## 底部居中是唯一不与血条面板/物品栏(右下)/结算面板重叠的整块空地。
## 复活提示在右下 dock 里、连杀提示在 -104 处，都离这个条有安全距离。
var _boss_bar_wrap: Control
var _boss_bar: ProgressBar
var _boss_name: Label
## 三个阶段各一套填充样式，预建复用（与 _hp_fill_normal 同一理由：避免高频重建）。
var _boss_fill: Array[StyleBoxFlat] = []

## 由 Main 注入：返回当前开火模式字符串。
##
## 为什么需要它：开火模式**跨局保持**（玩家按F 的选择不该在重开时丢失），
## 所以新一局开始时 HUD 不能想当然地填回默认值 —— 必须问控制器要真实值，
## 否则指示器会和实际行为对不上。详见 _on_run_started。
var fire_mode_provider: Callable = Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()

	Events.player_health_changed.connect(_on_hp)
	Events.player_xp_changed.connect(_on_xp)
	Events.player_level_changed.connect(_on_level)
	Events.elapsed_time_changed.connect(_on_time)
	Events.wave_changed.connect(_on_wave)
	Events.wave_timer_changed.connect(_on_wave_timer)
	Events.kills_changed.connect(_on_kills)
	Events.game_over.connect(_on_game_over)
	Events.run_started.connect(_on_run_started)
	Events.player_hurt.connect(_on_player_hurt)
	Events.upgrade_applied.connect(_on_upgrade_applied)
	Events.elite_spawned.connect(_on_elite_spawned)
	Events.elite_charge_warning.connect(_on_elite_charge_warning)
	Events.water_warning.connect(_on_water_warning)
	Events.boss_spawned.connect(_on_boss_spawned)
	Events.boss_health_changed.connect(_on_boss_health)
	Events.boss_phase_changed.connect(_on_boss_phase)
	Events.boss_defeated.connect(_on_boss_defeated)
	Events.inventory_changed.connect(_on_inventory_changed)
	Events.chest_opened.connect(_on_chest_opened)
	Events.player_dodged.connect(_on_player_dodged)


## ---------------------------------------------------------------- 构建

func _build() -> void:
	_root = Control.new()
	_root.name = "HudRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_theme_font_override("font", PIXEL_FONT)
	add_child(_root)

	_build_hud_frames()
	_build_xp_bar()
	_build_health_bar()
	_build_weapon_status()
	_build_inventory()
	_build_top_center()
	_build_top_right()
	_build_fire_indicator()
	_build_wave_banner()
	_build_damage_flash()
	_build_upgrade_notice()
	_build_elite_alert()
	_build_streak_label()
	_build_perf_label()
	_build_game_over()
	_build_pause_overlay()
	_build_boss_bar()

func _build_hud_frames() -> void:
	# 这些图片是新 HUD 的金属外框；文字和数值仍由下面的实时控件绘制。
	_add_hud_art(HP_PANEL_ART, Vector2(16.0, 20.0), Vector2(270.0, 126.0), "HpPanelArt")
	_add_hud_art(WAVE_PANEL_ART, Vector2(500.0, 0.0), Vector2(280.0, 120.0), "WavePanelArt")


func _add_hud_art(texture: Texture2D, pos: Vector2, art_size: Vector2, node_name: String) -> TextureRect:
	var art := TextureRect.new()
	art.name = node_name
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.custom_minimum_size = Vector2.ZERO
	art.position = pos
	art.size = art_size
	art.set_size(art_size)
	art.texture = texture
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.z_index = -1
	_root.add_child(art)
	return art

func _hud_frame_style(accent: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.075, 0.068, 0.055, 0.90)
	var brass := accent.lerp(Color("#c09a5b"), 0.52)
	sb.border_color = Color(brass.r, brass.g, brass.b, 0.82)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(7)
	sb.shadow_color = Color(0.01, 0.008, 0.005, 0.62)
	sb.shadow_size = 7
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


## 经验条。数字化改造：进度条 + 居中的 "42 / 75" 数字 + 右侧"还差 N"。
##
## 为什么光有条不够：割草游戏的爽点节奏完全由升级驱动，
## 玩家最想知道的是"我离下一次变强还有多远"。一根不标刻度的绿条
## 只能给出"快了/还早"这种模糊感觉，看不出 3 点还是 30 点。
func _build_xp_bar() -> void:
	var wrap := Control.new()
	wrap.name = "XpWrap"
	wrap.set_anchors_preset(Control.PRESET_CENTER_TOP)
	# 条高 20 而不是贴着屏幕最上沿放：
	# 一是 12px 的数字压在 14px 的条里、再顶到屏幕边缘会有一部分被裁掉，
	# 二是顶部留 4px 让经验条与画面边缘之间有呼吸感。
	wrap.offset_left = -140.0
	wrap.offset_right = 140.0
	wrap.offset_top = 3.0
	wrap.offset_bottom = 3.0 + XP_BAR_HEIGHT
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(wrap)

	_xp_bar = ProgressBar.new()
	_xp_bar.name = "XpBar"
	_xp_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_xp_bar.min_value = 0.0
	_xp_bar.max_value = 1.0
	_xp_bar.value = 0.0
	_xp_bar.show_percentage = false
	_xp_bar.visible = false
	_xp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ProgressBar 的底槽和填充条都靠 StyleBox 换色
	_xp_bar.add_theme_stylebox_override("background", _flat(Color("#171613"), 3, Color("#80683e"), 1))
	_xp_bar.add_theme_stylebox_override("fill", _flat(Color("#c79a4e"), 3))
	wrap.add_child(_xp_bar)

	_xp_label = Label.new()
	_xp_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_xp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 字号必须小于条高，否则数字会被裁掉半截。
	# 条高 20 → 字号 13 留出上下各 3px 的余量。
	_xp_label.add_theme_font_size_override("font_size", 13)
	_xp_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.96))
	_xp_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_xp_label.add_theme_constant_override("outline_size", 3)
	_xp_label.text = "经验  0 / 15      还差 15"
	_xp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(_xp_label)


## 右上角的开火模式指示器。
##
## 必须做得显眼：手动模式下"按了没反应"和"自动模式在帮我打"两种状态的
## 游戏体验完全不同，玩家必须一眼看出现在是哪个模式，否则会以为是 bug。
func _build_fire_indicator() -> void:
	_fire_label = _make_label("", 14, Color("#e4bd72"))
	_fire_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_fire_label.offset_left = -450.0
	_fire_label.offset_right = -16.0
	_fire_label.offset_top = 102.0
	_fire_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_fire_label)


func _build_health_bar() -> void:
	var wrap := Control.new()
	wrap.name = "HpWrap"
	# 让开顶部那条经验条：它现在占到 y = 4 + 20 = 24，
	# 血条从 32 开始才不会跟它叠在一起。
	wrap.position = Vector2(30.0, 54.0)
	wrap.size = Vector2(208.0, 22.0)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(wrap)

	_hp_bar = ProgressBar.new()
	_hp_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hp_bar.min_value = 0.0
	_hp_bar.max_value = 100.0
	_hp_bar.value = 100.0
	_hp_bar.show_percentage = false
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_bar.add_theme_stylebox_override("background", _flat(Color("#171513"), 5, Color("#80683e"), 1))
	# 两套填充样式在这里建一次，供 _on_hp 复用（见那处的注释）
	_hp_fill_normal = _flat(Color("#18d989"), 5, Color("#40f6b0"), 1)
	_hp_fill_danger = _flat(Color("#ff7b5f"), 5, Color("#ffb27d"), 1)
	_hp_bar.add_theme_stylebox_override("fill", _hp_fill_normal)
	wrap.add_child(_hp_bar)

	_hp_label = Label.new()
	_hp_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_label.add_theme_font_size_override("font_size", 13)
	_hp_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	# 描边，保证压在血条上任何颜色都读得清
	_hp_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_hp_label.add_theme_constant_override("outline_size", 3)
	_hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(_hp_label)


func _build_weapon_status() -> void:
	_weapon_label = _make_label("武器：手枪", 13, Color(0.78, 0.84, 0.91, 0.95))
	_weapon_label.position = Vector2(25.0, 90.0)
	_weapon_label.custom_minimum_size = Vector2(245.0, 22.0)
	_weapon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_weapon_label)

func _build_inventory() -> void:
	# 右下角原来是三个彼此独立的控件，各自写死 position。
	# 在窗口比例变化或文字变长时，它们会互相覆盖。现在把提示和物品栏
	# 收进同一个锚定的 VBox，间距由容器管理，整个区域只跟右下角保持边距。
	var dock := Control.new()
	dock.name = "InventoryDock"
	dock.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	dock.offset_left = -330.0
	dock.offset_right = -18.0
	dock.offset_top = -184.0
	dock.offset_bottom = -18.0
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dock)

	var stack := VBoxContainer.new()
	stack.name = "InventoryStack"
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.alignment = BoxContainer.ALIGNMENT_END
	stack.add_theme_constant_override("separation", 5)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dock.add_child(stack)

	# 卡槽背景和按钮必须在同一个 slot_wrap 里，否则 VBox 会把背景和
	# 按钮当成两行，导致图标看起来从外框里漂出来。
	var slot_wrap := Control.new()
	slot_wrap.name = "SlotWrap"
	slot_wrap.custom_minimum_size = Vector2(300.0, 76.0)
	slot_wrap.size_flags_horizontal = Control.SIZE_SHRINK_END
	slot_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(slot_wrap)

	var frame := TextureRect.new()
	frame.name = "InventoryFrameArt"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var cropped_frame := AtlasTexture.new()
	cropped_frame.atlas = INVENTORY_FRAME_ART
	cropped_frame.region = INVENTORY_FRAME_REGION
	frame.texture = cropped_frame
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.z_index = -1
	slot_wrap.add_child(frame)

	var box := HBoxContainer.new()
	box.name = "Inventory"
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 这里已经使用裁剪后的五格区域，按钮只留少量内边距即可。
	box.offset_left = 7.0
	box.offset_right = -5.0
	box.offset_top = 6.0
	box.offset_bottom = -6.0
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot_wrap.add_child(box)
	var slot_empty := StyleBoxEmpty.new()
	for i in 5:
		var slot := Button.new()
		slot.custom_minimum_size = Vector2(54.0, 60.0)
		slot.add_theme_font_size_override("font_size", 15)
		slot.add_theme_stylebox_override("normal", slot_empty)
		slot.add_theme_stylebox_override("hover", slot_empty)
		slot.add_theme_stylebox_override("pressed", slot_empty)
		slot.add_theme_color_override("font_color", Color("#d5d7dc"))
		slot.add_theme_color_override("font_disabled_color", Color(0.75, 0.77, 0.82, 0.8))
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 自绘三层信息：左上快捷键、中央图标、底部数量，避免 Button
		# 默认的 icon + text 横排导致图标和“1 ×2”互相挤压。
		slot.text = ""
		var icon_view := TextureRect.new()
		icon_view.name = "Icon"
		icon_view.position = Vector2(12.0, 7.0)
		icon_view.size = Vector2(26.0, 32.0)
		icon_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon_view)
		var key_label := _make_label(str(i + 1), 10, Color("#edf3cb"))
		key_label.name = "Key"
		key_label.position = Vector2(2.0, 1.0)
		key_label.size = Vector2(18.0, 15.0)
		key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.visible = i < 2
		slot.add_child(key_label)
		var count_label := _make_label("", 10, Color("#f1f3f5"))
		count_label.name = "Count"
		count_label.position = Vector2(0.0, 42.0)
		count_label.size = Vector2(50.0, 14.0)
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(count_label)
		box.add_child(slot)
		_inventory_slots.append(slot)
	_inventory_label = _make_label("数字键 1-5 使用物品", 13, Color("#f0e8d1"))
	_inventory_label.custom_minimum_size = Vector2(300.0, 22.0)
	_inventory_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_inventory_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_inventory_label.add_theme_color_override("font_outline_color", Color(0.01, 0.02, 0.03, 0.92))
	_inventory_label.add_theme_constant_override("outline_size", 4)
	stack.add_child(_inventory_label)
	# 复活药剂是被动充能，不进行囊 —— 单独一个小指示，有充能才出现
	_revive_label = _make_label("", 14, Color("#f5f0df"))
	_revive_label.custom_minimum_size = Vector2(300.0, 22.0)
	_revive_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_revive_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_revive_label.add_theme_color_override("font_outline_color", Color(0.01, 0.02, 0.03, 0.92))
	_revive_label.add_theme_constant_override("outline_size", 4)
	# 先插到提示文字前面，VBox 的视觉顺序就是：复活提示 → 操作提示 → 卡槽。
	stack.add_child(_revive_label)
	stack.move_child(_revive_label, 0)
	stack.move_child(slot_wrap, stack.get_child_count() - 1)
	Events.revive_changed.connect(_on_revive_changed)


func _refresh_weapon_status() -> void:
	if _weapon_label == null:
		return
	var parts: Array[String] = ["手枪"]
	if int(_weapon_levels.get("shotgun", 0)) > 0:
		parts.append("霰弹 Lv%d" % int(_weapon_levels["shotgun"]))
	if int(_weapon_levels.get("chain", 0)) > 0:
		parts.append("电弧 Lv%d" % int(_weapon_levels["chain"]))
	if int(_weapon_levels.get("orbit_blade", 0)) > 0:
		parts.append("飞刃 ×%d" % int(_weapon_levels["orbit_blade"]))
	_weapon_label.text = "武器：" + "  ·  ".join(parts)


func _build_top_center() -> void:
	var box := VBoxContainer.new()
	box.name = "TopCenter"
	box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	box.offset_left = -150.0
	box.offset_right = 150.0
	box.offset_top = 17.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(box)

	_time_label = _make_label("0:00", 34, Color(1, 1, 1, 0.95))
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_time_label)

	_wave_label = _make_label("第 1 波", 17, Color(0.78, 0.82, 0.88, 0.9))
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_wave_label)

	_wave_timer_label = _make_label("下一波 25s", 14, Color(0.60, 0.68, 0.78, 0.88))
	_wave_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_wave_timer_label)


func _build_top_right() -> void:
	var row := HBoxContainer.new()
	row.name = "TopRightStatusStrip"
	row.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	row.offset_left = -334.0
	row.offset_right = -16.0
	row.offset_top = 20.0
	row.offset_bottom = 78.0
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_END
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(row)

	_level_label = _add_status_cell(row, "等级", 92.0, null, "Lv 1", Color("#ffd34d"), 20)
	_kills_label = _add_status_cell(row, "击杀", 70.0, null, "击杀 0", Color("#e7edf5"), 14)
	_chest_label = _add_status_cell(row, "宝箱", 70.0, CHEST_ICON, "0", Color("#ffd77b"), 16)
	_potion_label = _add_status_cell(row, "药剂", 70.0, POTION_ICON, "0", Color("#9fd8ef"), 16)


func _add_status_cell(parent: HBoxContainer, cell_name: String, cell_width: float, icon: Texture2D, value_text: String, value_color: Color, value_size: int) -> Label:
	var cell := PanelContainer.new()
	cell.name = cell_name
	cell.custom_minimum_size = Vector2(cell_width, 56.0)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_theme_stylebox_override("panel", _flat(Color(0.035, 0.075, 0.10, 0.88), 7, Color(0.20, 0.76, 0.70, 0.78), 1))
	parent.add_child(cell)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	cell.add_child(margin)
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	line.add_theme_constant_override("separation", 5)
	margin.add_child(line)
	if icon != null:
		var icon_rect := TextureRect.new()
		icon_rect.texture = icon
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.custom_minimum_size = Vector2(27.0, 32.0)
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(icon_rect)
	var label := _make_label(value_text, value_size, value_color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)
	return label


func _build_perf_label() -> void:
	_perf_label = _make_label("", 12, Color(0.6, 0.66, 0.72, 0.9))
	_perf_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_perf_label.offset_left = 18.0
	_perf_label.offset_top = -26.0
	_perf_label.visible = false
	_root.add_child(_perf_label)


func _build_game_over() -> void:
	_over_center = CenterContainer.new()
	_over_center.name = "GameOver"
	_over_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_over_center.visible = false
	_root.add_child(_over_center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(Color("#241d17"), 10, Color("#b06d48"), 2))
	_over_center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 34)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	_over_title = _make_label("你被吃掉了", 34, Color("#e2685e"))
	_over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_over_title)

	_over_stats = _make_label("", 16, Color(0.88, 0.9, 0.93))
	_over_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_over_stats)

	var hint := _make_label("按 R 或点击按钮重新开始", 14, Color(0.65, 0.7, 0.76))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)

	_restart_button = Button.new()
	_restart_button.text = "再来一局"
	_restart_button.custom_minimum_size = Vector2(210.0, 46.0)
	_restart_button.add_theme_font_size_override("font_size", 18)
	_restart_button.add_theme_color_override("font_color", Color("#fff4d1"))
	_restart_button.add_theme_stylebox_override("normal", _flat(Color("#9d3f38"), 10, Color("#e87568"), 1))
	_restart_button.add_theme_stylebox_override("hover", _flat(Color("#bd4d43"), 10, Color("#ff9b87"), 2))
	_restart_button.add_theme_stylebox_override("pressed", _flat(Color("#7f302c"), 10, Color("#ffbead"), 2))
	_restart_button.pressed.connect(func() -> void: restart_requested.emit())
	box.add_child(_restart_button)


func _build_pause_overlay() -> void:
	_pause_overlay = Control.new()
	_pause_overlay.name = "PauseOverlay"
	_pause_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_overlay.visible = false
	_root.add_child(_pause_overlay)
	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.01, 0.015, 0.025, 0.72)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_overlay.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(Color("#241f19"), 10, Color("#b0925d"), 2))
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)
	var title := _make_label("游戏暂停", 30, Color("#f0c486"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var hint := _make_label("按 Esc 或点击按钮继续", 14, Color(0.68, 0.76, 0.86))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	var resume := Button.new()
	resume.text = "继续战斗"
	resume.custom_minimum_size = Vector2(190.0, 44.0)
	resume.add_theme_font_size_override("font_size", 17)
	resume.pressed.connect(func() -> void: resume_requested.emit())
	box.add_child(resume)


func set_paused(paused: bool) -> void:
	if _pause_overlay == null:
		return
	_pause_overlay.visible = paused
	if paused:
		_pause_overlay.get_child(1).get_child(0).get_child(0).get_child(0).get_child(2).grab_focus()


func _build_wave_banner() -> void:
	_wave_banner = PanelContainer.new()
	_wave_banner.name = "WaveBanner"
	_wave_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_wave_banner.position = Vector2(-150.0, 74.0)
	_wave_banner.custom_minimum_size = Vector2(300.0, 48.0)
	_wave_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_banner.visible = false
	_wave_banner.add_theme_stylebox_override("panel", _flat(Color(0.06, 0.08, 0.11, 0.92), 12, Color(0.98, 0.75, 0.25, 0.75), 1))
	_root.add_child(_wave_banner)
	_wave_banner_label = _make_label("", 22, Color("#ffe18a"))
	_wave_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_wave_banner_label.custom_minimum_size = Vector2(300.0, 48.0)
	_wave_banner.add_child(_wave_banner_label)


func _build_damage_flash() -> void:
	_damage_flash = ColorRect.new()
	_damage_flash.name = "DamageFlash"
	_damage_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_flash.color = Color(0.92, 0.08, 0.06, 0.0)
	_damage_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_damage_flash)


func _build_upgrade_notice() -> void:
	_upgrade_notice = _make_label("", 22, Color("#ffe18a"))
	_upgrade_notice.name = "UpgradeNotice"
	_upgrade_notice.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_upgrade_notice.position = Vector2(-240.0, 128.0)
	_upgrade_notice.custom_minimum_size = Vector2(480.0, 34.0)
	_upgrade_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upgrade_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_upgrade_notice.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_root.add_child(_upgrade_notice)


func _build_elite_alert() -> void:
	_elite_alert = _make_label("", 18, Color("#ff8674"))
	_elite_alert.name = "EliteAlert"
	_elite_alert.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_elite_alert.position = Vector2(-250.0, 178.0)
	_elite_alert.custom_minimum_size = Vector2(500.0, 30.0)
	_elite_alert.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_elite_alert.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_elite_alert.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_root.add_child(_elite_alert)


func _build_streak_label() -> void:
	_streak_label = _make_label("", 20, Color("#ffd34d"))
	_streak_label.name = "KillStreak"
	_streak_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_streak_label.position = Vector2(-150.0, -104.0)
	_streak_label.custom_minimum_size = Vector2(300.0, 30.0)
	_streak_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_streak_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_streak_label.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_root.add_child(_streak_label)


## 首领专用血条：底部居中的名字 + 大血条，阶段升档换填充色。
## 独立于小怪头顶血条 —— 首领要的是"一场战斗的进度感"，不是一只怪的余量。
func _build_boss_bar() -> void:
	_boss_bar_wrap = Control.new()
	_boss_bar_wrap.name = "BossBarWrap"
	_boss_bar_wrap.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_boss_bar_wrap.offset_left = -220.0
	_boss_bar_wrap.offset_right = 220.0
	_boss_bar_wrap.offset_top = -54.0
	_boss_bar_wrap.offset_bottom = -18.0
	_boss_bar_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_bar_wrap.visible = false
	_root.add_child(_boss_bar_wrap)

	_boss_name = _make_label(GameData.BOSS_DISPLAY_NAME, 15, Color("#ff9a8a"))
	_boss_name.position = Vector2(0.0, 0.0)
	_boss_name.size = Vector2(440.0, 16.0)
	_boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_name.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.02, 0.9))
	_boss_name.add_theme_constant_override("outline_size", 4)
	_boss_bar_wrap.add_child(_boss_name)

	_boss_bar = ProgressBar.new()
	_boss_bar.position = Vector2(20.0, 18.0)
	_boss_bar.size = Vector2(400.0, 14.0)
	_boss_bar.min_value = 0.0
	_boss_bar.max_value = 1.0
	_boss_bar.value = 1.0
	_boss_bar.show_percentage = false
	_boss_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_bar.add_theme_stylebox_override("background", _flat(Color("#1a0f0e"), 4, Color("#8a3026"), 1))
	# 阶段 1/2/3 的填充色：暗红 → 橙红 → 亮红。建一次存起来，阶段切换只换引用。
	for col: Color in [Color("#b8433a"), Color("#d8683a"), Color("#ff4d43")]:
		_boss_fill.append(_flat(col, 4))
	_boss_bar.add_theme_stylebox_override("fill", _boss_fill[0])
	_boss_bar_wrap.add_child(_boss_bar)


## ---------------------------------------------------------------- 信号回调

## 血条的低血量阈值。低于这个比例，血条和数字转成告警色。
const HP_DANGER_RATIO := 0.3

## 预建的两套血条填充样式（正常 / 告警）。
##
## ⚠ 不要在 _on_hp 里现调 _flat() + add_theme_stylebox_override。
## 血量变化的频率极高（受伤、喝药水、开宝箱、升级回血都会广播
## player_health_changed），后期一波几十只丧尸时每秒能触发几十次。
## 而 add_theme_stylebox_override 每换一次 StyleBox 就要让引擎重建
## 一份并丢弃旧的 —— 高频调用会持续制造垃圾，触发引擎内部资源堆积。
## 样式总共就两种，建一次存起来复用即可。
var _hp_fill_normal: StyleBoxFlat
var _hp_fill_danger: StyleBoxFlat
var _hp_danger_active: bool = false

func _on_hp(current: float, maximum: float) -> void:
	_hp_bar.max_value = maximum
	_hp_bar.value = current
	_hp_label.text = "%d / %d" % [ceili(maxf(current, 0.0)), ceili(maximum)]
	# 只在**跨越阈值**时才换样式，不是因为数值变了就换。
	# 同一个血量可能被广播多次（比如同一帧受伤 + 回血），
	# 无脑 set 会白白重建样式。
	var danger := current / maxf(maximum, 0.001) <= HP_DANGER_RATIO
	if danger != _hp_danger_active:
		_hp_danger_active = danger
		_hp_bar.add_theme_stylebox_override("fill", _hp_fill_danger if danger else _hp_fill_normal)
		_hp_label.add_theme_color_override("font_color", Color("#ff9b87") if danger else Color.WHITE)


func _on_player_hurt(_pos: Vector2, _amount: float) -> void:
	if _damage_flash == null:
		return
	_damage_flash.color.a = 0.24
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_damage_flash, "color:a", 0.0, 0.22)


func _on_upgrade_applied(upgrade: Dictionary) -> void:
	if _upgrade_notice == null:
		return
	_upgrade_notice.text = "强化成功  ·  %s" % String(upgrade.get("name", "属性提升"))
	var id := String(upgrade.get("id", ""))
	if id in ["shotgun", "chain", "orbit_blade"]:
		_weapon_levels[id] = int(_weapon_levels.get(id, 0)) + 1
		_refresh_weapon_status()
	_upgrade_notice.modulate = Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.7)
	tw.tween_property(_upgrade_notice, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.35)


func _on_elite_spawned(pos: Vector2) -> void:
	if _elite_alert == null:
		return
	var camera := get_viewport().get_camera_2d()
	var direction := ""
	if camera != null:
		var delta := pos - camera.global_position
		if absf(delta.x) >= absf(delta.y):
			direction = "← 左侧" if delta.x < 0.0 else "右侧 →"
		else:
			direction = "↑ 上方" if delta.y < 0.0 else "下方 ↓"
	_elite_alert.text = "⚠ 精英丧尸接近  %s" % direction
	_elite_alert.modulate = Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_property(_elite_alert, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.4)


func _on_elite_charge_warning(_pos: Vector2) -> void:
	if _elite_alert == null:
		return
	_elite_alert.text = "⚠ 冲锋预警！立即走位"
	_elite_alert.add_theme_color_override("font_color", Color("#ff4d43"))
	_elite_alert.modulate = Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.62)
	tw.tween_property(_elite_alert, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.25)


func _on_water_warning(_pos: Vector2) -> void:
	if _elite_alert == null:
		return
	_elite_alert.text = "⚠ 水面有东西浮上来了！"
	_elite_alert.add_theme_color_override("font_color", Color("#7fd8e8"))
	_elite_alert.modulate = Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.7)
	tw.tween_property(_elite_alert, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.3)


func _on_boss_spawned(_pos: Vector2) -> void:
	if _elite_alert == null:
		return
	_elite_alert.text = "☠ 首领级丧尸来袭！"
	_elite_alert.add_theme_color_override("font_color", Color("#ff5148"))
	_elite_alert.modulate = Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.25)
	tw.tween_property(_elite_alert, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.45)
	# 底部首领血条同步亮出。血量由 boss_health_changed 驱动
	# （spawn 时 Zombie 会先广播一次满血，这里只负责置位与样式）。
	if _boss_bar_wrap != null:
		_boss_name.text = GameData.BOSS_DISPLAY_NAME
		_boss_bar.value = _boss_bar.max_value
		_boss_bar.add_theme_stylebox_override("fill", _boss_fill[0])
		_boss_bar_wrap.visible = true


func _on_boss_health(current: float, maximum: float) -> void:
	if _boss_bar == null:
		return
	_boss_bar.max_value = maxf(maximum, 1.0)
	_boss_bar.value = clampf(current, 0.0, maximum)


func _on_boss_phase(phase: int, _pos: Vector2) -> void:
	if _boss_bar != null:
		var idx := clampi(phase - 1, 0, _boss_fill.size() - 1)
		_boss_bar.add_theme_stylebox_override("fill", _boss_fill[idx])
	if _elite_alert == null:
		return
	var phase_colors := [Color("#ffcf6b"), Color("#ff9a5e"), Color("#ff4d43")]
	var phase_names := ["", "警觉", "狂暴", "嗜血"]
	_elite_alert.text = "☠ 首领进入%s阶段 %d！" % [String(phase_names[clampi(phase, 0, 3)]), phase]
	_elite_alert.add_theme_color_override("font_color", phase_colors[clampi(phase - 1, 0, 2)])
	_elite_alert.modulate = Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.1)
	tw.tween_property(_elite_alert, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.4)


func _on_boss_defeated(_pos: Vector2) -> void:
	if _boss_bar_wrap != null:
		_boss_bar_wrap.visible = false
	if _upgrade_notice == null:
		return
	_upgrade_notice.text = "☠ 首领被击杀！战利品已掉落"
	_upgrade_notice.modulate = Color("#ffd34d")
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_interval(1.4)
	tw.tween_property(_upgrade_notice, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.4)


func _on_xp(current: float, required: float) -> void:
	_xp_current = current
	_xp_required = maxf(required, 0.0001)
	_xp_bar.max_value = _xp_required
	_xp_bar.value = current

	# 数字部分。经验值是浮点（击杀给 1 / 3 / 7 点），但显示成小数毫无意义，
	# 反而让"42 / 75"变成"41.8 / 74.6"这种读不出信息的字符串。
	# 统一取整；还差多少用 ceil 保证"差 0"只在真的够了时才出现。
	var cur := int(round(current))
	var need := int(round(_xp_required))
	var remain := maxi(0, need - cur)

	# 快满的时候把"还差"高亮成绿色，给玩家一个"再来几只就升级"的明确信号。
	# 20% 这个阈值是手感值：再高会频繁闪烁，再低来不及反应。
	var ratio := current / _xp_required
	if ratio >= 0.8:
		_xp_label.add_theme_color_override("font_color", Color("#8effb0"))
	else:
		_xp_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.96))

	_xp_label.text = "经验  %d / %d      还差 %d" % [cur, need, remain]


func _on_fire_mode(mode: String) -> void:
	if mode == GameData.FIRE_MODE_MANUAL:
		# ⚠ 原来写的是"按住左键/**空格**射击"，但空格在 game_data.gd 的
		# 输入注册里是 dodge（闪避），input_controller 只读鼠标左键。
		# 照着提示按空格只会触发闪避、开不了枪 —— 玩家会以为手动模式坏了。
		_fire_label.text = "[ 手动开火 ]  按住鼠标左键射击 · F 切回自动"
		_fire_label.add_theme_color_override("font_color", Color("#ffcf6b"))
	else:
		_fire_label.text = "[ 自动开火 ]  自动索敌 · F 切换到手动"
		_fire_label.add_theme_color_override("font_color", Color(0.68, 0.86, 1.0, 0.95))


func _on_level(level: int) -> void:
	_level_label.text = "Lv %d" % level


func _on_time(seconds: float) -> void:
	var total := int(seconds)
	_time_label.text = "%d:%02d" % [total / 60, total % 60]


func _on_wave(wave: int) -> void:
	_wave_label.text = "第 %d 波" % wave
	if _wave_banner == null:
		return
	var elite := wave > 1 and wave % GameData.ELITE_EVERY_WAVES == 0
	var boss_wave := wave > 1 and wave % 10 == 0
	_wave_banner_label.text = ("首领波次 %d" % wave) if boss_wave else (("精英波次 %d" % wave) if elite else ("第 %d 波开始" % wave))
	_wave_banner_label.add_theme_color_override("font_color", Color("#ff7c67") if boss_wave else (Color("#ffbd66") if elite else Color("#ffe18a")))
	_wave_banner.visible = true
	_wave_banner.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_wave_banner.scale = Vector2(0.92, 0.92)
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_wave_banner, "modulate", Color.WHITE, 0.16)
	tw.tween_property(_wave_banner, "scale", Vector2.ONE, 0.18)
	tw.set_parallel(false)
	tw.tween_interval(1.15)
	tw.tween_property(_wave_banner, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.32)
	tw.tween_callback(func() -> void: _wave_banner.visible = false)


func _on_wave_timer(seconds: int) -> void:
	if _wave_timer_label == null:
		return
	_wave_timer_label.text = "下一波 %ds" % maxi(0, seconds)
	_wave_timer_label.add_theme_color_override("font_color", Color("#ffcf72") if seconds <= 5 else Color(0.60, 0.68, 0.78, 0.88))


func _on_kills(total: int) -> void:
	_kills_label.text = "击杀 %d" % total
	if total <= 0:
		return
	_streak_count += 1
	_streak_left = 2.4
	if _streak_count >= 2 and _streak_label != null:
		_streak_label.text = "连杀 ×%d" % _streak_count
		_streak_label.modulate = Color.WHITE


func _on_game_over(summary: Dictionary) -> void:
	var total := int(summary.get("survived", 0.0))
	_over_stats.text = "存活 %d:%02d　击杀 %d　等级 %d" % [
		total / 60, total % 60,
		int(summary.get("kills", 0)),
		int(summary.get("level", 1)),
	]
	_over_stats.text += "\n历史最佳：%d:%02d　击杀 %d" % [
		int(float(summary.get("best_survived", 0.0))) / 60,
		int(float(summary.get("best_survived", 0.0))) % 60,
		int(summary.get("best_kills", 0)),
	]
	_over_center.visible = true
	_over_center.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if _boss_bar_wrap != null:
		_boss_bar_wrap.visible = false
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_over_center, "modulate", Color.WHITE, 0.22)
	_restart_button.grab_focus()


func _on_run_started() -> void:
	_over_center.visible = false
	_hp_bar.value = _hp_bar.max_value
	# 新一局开始时收起首领血条：上一局的首领无论死没死都不在了。
	if _boss_bar_wrap != null:
		_boss_bar_wrap.visible = false
	_xp_bar.value = 0.0
	_xp_label.text = "经验  0 / 15      还差 15"
	_time_label.text = "0:00"
	_wave_label.text = "第 1 波"
	_kills_label.text = "击杀 0"
	_level_label.text = "Lv 1"
	_chest_count = 0
	if _chest_label != null:
		_chest_label.text = "0"
	if _potion_label != null:
		_potion_label.text = "0"
	_weapon_levels.clear()
	_refresh_weapon_status()
	_streak_count = 0
	_streak_left = 0.0
	if _streak_label != null:
		_streak_label.modulate = Color(1.0, 1.0, 1.0, 0.0)
	# 开火模式要向 InputController 要**当前真实值**，不能写死默认值。
	#
	# ⚠ 模式是跨局保持的（见 input_controller.gd 的 reset()：刻意不重置
	# mode，因为"上一局选手动，这局不该又跳回自动"是设计意图）。
	# 原来这里填GameData.FIRE_MODE_DEFAULT，于是玩家上一局按 F 切到手动、
	# 这局 HUD 显示"[ 自动开火 ]"、实际却是手动 —— 指示器在说谎，
	# 而玩家只能靠"按了没反应"来反推自己是不是还在手动模式。
	if fire_mode_provider.is_valid():
		_on_fire_mode(String(fire_mode_provider.call()))
	_refresh_inventory({"grenade": 0, "potion": 0})

func _on_inventory_changed(items: Dictionary) -> void:
	_refresh_inventory(items)

func _refresh_inventory(items: Dictionary) -> void:
	if _inventory_slots.is_empty():
		return
	var slots: Array = items.get("_slots", [])
	var capacity := int(items.get("_capacity", 2))
	for i in _inventory_slots.size():
		var slot := _inventory_slots[i]
		var icon_view: TextureRect = slot.get_node("Icon")
		var key_label: Label = slot.get_node("Key")
		var count_label: Label = slot.get_node("Count")
		if i >= capacity:
			slot.text = ""
			slot.disabled = true
			slot.modulate = Color(0.55, 0.6, 0.67, 0.8)
			icon_view.texture = null
			icon_view.visible = false
			key_label.visible = false
			count_label.text = ""
		elif i < slots.size():
			# 叠加制：一格一种物品，图标 + 数量。名称查 SHOP_ITEMS，没查到退回 id。
			var item_id := String(slots[i])
			slot.disabled = false
			slot.modulate = Color.WHITE
			icon_view.texture = GameData.item_icon(item_id)
			icon_view.visible = icon_view.texture != null
			key_label.visible = i < 2
			var def: Dictionary = GameData.shop_item(item_id)
			var display: String = String(def.get("name", item_id)) if not def.is_empty() else item_id
			slot.text = ""
			count_label.text = "×%d" % int(items.get(item_id, 1))
			slot.tooltip_text = display
		else:
			icon_view.texture = null
			icon_view.visible = false
			key_label.visible = false
			slot.disabled = false
			slot.modulate = Color(0.75, 0.85, 0.95, 0.9)
			slot.text = ""
			count_label.text = ""

func _on_revive_changed(count: int) -> void:
	if _revive_label == null:
		return
	if _potion_label != null:
		_potion_label.text = str(count)
	# 三元表达式加括号 —— 不加的话 `%` 和 else 的结合顺序读起来有歧义
	_revive_label.text = ("♦ 复活药剂 ×%d（倒下时自动生效）" % count) if count > 0 else ""

func _on_chest_opened(_pos: Vector2, reward_name: String) -> void:
	_chest_count += 1
	if _chest_label != null:
		_chest_label.text = str(_chest_count)
	if _upgrade_notice == null:
		return
	_upgrade_notice.text = "获得奖励  ·  %s" % reward_name
	_upgrade_notice.modulate = Color("#ffe18a")
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_interval(1.0)
	tw.tween_property(_upgrade_notice, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.35)

func _on_player_dodged(_pos: Vector2) -> void:
	if _upgrade_notice == null:
		return
	_upgrade_notice.text = "闪避"
	_upgrade_notice.modulate = Color("#9ee7ff")
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(_upgrade_notice, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.25)


## ---------------------------------------------------------------- 调试显示

func _process(_delta: float) -> void:
	if _streak_left > 0.0:
		_streak_left -= _delta
		if _streak_left <= 0.0:
			_streak_count = 0
			if _streak_label != null:
				_streak_label.modulate = Color(1.0, 1.0, 1.0, 0.0)

	if Input.is_action_just_pressed("toggle_debug"):
		_debug_visible = not _debug_visible
		_perf_label.visible = _debug_visible

	if _debug_visible and debug_provider.is_valid():
		_perf_label.text = String(debug_provider.call())


## ---------------------------------------------------------------- 小工具

func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _flat(color: Color, radius: int = 0, border_color: Color = Color(0, 0, 0, 0), border_width: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	if radius > 0:
		sb.corner_radius_top_left = radius
		sb.corner_radius_top_right = radius
		sb.corner_radius_bottom_left = radius
		sb.corner_radius_bottom_right = radius
	if border_width > 0:
		sb.border_color = border_color
		sb.set_border_width_all(border_width)
	return sb
