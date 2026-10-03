extends CanvasLayer
## 开始页面与商店。
##
## 商店面板是覆盖在主菜单上的一层商品卡：图标 + 名称 + 说明 + 现价 + 购买键。
## 价格与已购次数全部由 Main 推导（价格曲线 base * growth^已购次数，见
## GameData.SHOP_ITEMS），这里只负责展示与发出 buy_requested(kind)；
## Main 买完会重新调 show_screen 刷新 —— 数据只有一份，界面不做本地记账。

signal start_requested()
signal buy_requested(kind: String)

const ATMOSPHERE_SCRIPT := preload("res://ui/start_atmosphere.gd")
const PIXEL_FONT := preload("res://assets/ui/fonts/fusion-pixel-12px-zh-hans.ttf")
const START_SURVIVOR_SHEET_PATH := "res://assets/ui/start_survivor_walk.png"
const START_BACKGROUND_SHEET_PATH := "res://assets/ui/start_background_walk8.png"
const VIDEO_BACKGROUND_DIR := "res://assets/ui/video_background/"
const VIDEO_FRAME_COUNT := 60
## 视频帧的原始尺寸。所有"画在视频帧里"的 UI 元素都靠它做坐标换算。
const VIDEO_FRAME_SIZE := Vector2(1280.0, 720.0)
## 视频帧里"开始游戏"按钮的矩形（帧坐标，含 2px 出血）。悬停贴图按它裁剪，
## 点击区也按它换算 —— 贴图、热区、视频画面三者共用这一个矩形，才不会错位。
const START_BTN_RECT := Rect2(501, 225, 285, 91)
## 视频帧里雷达圆心相对 START_BTN_RECT 左上角的偏移，以及圆的半径。
const RADAR_LOCAL_CENTER := Vector2(240.5, 46.0)
const RADAR_RADIUS := 35.0
## 其余三个视频按钮的矩形（帧坐标，含 2px 出血）。旧实现把它们挂在固定
## 视口比例的 VBox 上，与视频里画好的按钮差了约 20px —— 按钮下三分之一
## 点不到。背景换成纯背景版后，这三个按钮也是中值抠出的精灵，同样参与
## 悬停缩放。
const VIDEO_BUTTON_RECTS := {
	"shop": Rect2(504, 336, 278, 84),
	"settings": Rect2(488, 424, 298, 92),
	"exit": Rect2(505, 528, 278, 88),
}
const VIDEO_BUTTON_PATHS := {
	"shop": "res://assets/ui/generated/start_button_shop.png",
	"settings": "res://assets/ui/generated/start_button_settings.png",
	"exit": "res://assets/ui/generated/start_button_exit.png",
}
## 普通按钮的悬停/按压幅度（粒子四个按钮同款）。开始按钮另有两点不同：
## 更大的倍率（START_HOVER_SCALE）、开局延迟演出与雷达扫描。
const MENU_HOVER_SCALE := 1.06
## "开始游戏"按钮贴图：60 帧取中值合成（滤掉 AI 视频的边框闪烁和
## 飘过按钮前的雪花），圆角透明遮罩由 tools 流程生成。
const START_OVERLAY_PATH := "res://assets/ui/generated/start_button_main.png"
## 雷达扫描光效。中值合成会把旋转的扫描线抹成均匀微光，运行时叠一层
## 旋转的光楔把动感补回来。
const RADAR_SWEEP_PATH := "res://assets/ui/generated/start_radar_sweep.png"
const START_HOVER_SCALE := 1.08
## 背景视频换成"纯背景"版后，角色卡和金币栏不再烘在视频里，改用
## 从旧版 UI 视频中值抠出的精灵叠在背景上，位置按帧坐标换算。
const ROLE_CARD_PATH := "res://assets/ui/generated/start_role_card.png"
const COIN_PANEL_PATH := "res://assets/ui/generated/start_coin_panel.png"
## 视频帧里角色卡（含 XP 条）与金币栏（含硬币和 + 键）的矩形（帧坐标）。
const ROLE_CARD_RECT := Rect2(35, 37, 208, 274)
const COIN_PANEL_RECT := Rect2(938, 10, 309, 104)
## 金币数字的摆放区（帧坐标）。抠图时已把"金币 309"从栏内修掉，
## 这里只放真数据 Label，不再需要色块补丁。
const COIN_LABEL_RECT := Rect2(1042, 42, 156, 48)
## 金币栏右侧 "+" 按钮的矩形（帧坐标）。贴图从金币栏抠图里原样抠出，
## 静止时与栏内烘焙像素逐像素重合；点击弹出金币说明弹窗。
const COIN_PLUS_RECT := Rect2(1205, 47, 38, 37)
const COIN_PLUS_PATH := "res://assets/ui/generated/start_coin_plus.png"
const BUTTON_SHEET_PATH := "res://assets/ui/generated/menu_button_sheet_v1.png"
const SURVIVOR_FRAME_SIZE := Vector2(190.0, 230.0)
const SURVIVOR_FRAME_POSITION := Vector2(44.0, 34.0)
const SURVIVOR_PORTRAIT_POSITION := Vector2(95.0, 128.0)
const SURVIVOR_PORTRAIT_SCALE := 0.24

var coins := 0
var _coin_label: Label
var _status: Label
var _shop_panel: Panel
var _shop_backdrop: ColorRect
var _shop_coins_label: Label
var _menu_box: VBoxContainer
var _coin_panel: PanelContainer
var _video_coin_label: Label
var _role_card_sprite: TextureRect
var _coin_panel_sprite: TextureRect
var _coin_plus_visual: TextureRect
var _coin_plus_hotzone: Button
var _coin_popup: PanelContainer
var _role_frame: Panel
var _background: AnimatedSprite2D
var _video_background := false
var _button_atlas: Texture2D
var _viewport_size := Vector2.ZERO
## kind -> {"price": Label, "count": Label, "buy": Button}，_refresh 时统一更新
var _shop_refs: Dictionary = {}

## 视频背景当前的 cover 缩放比（_layout 里随视口更新）。
## 帧坐标 → 屏幕坐标的换算全靠它，见 _frame_to_screen。
var _video_scale := 1.0
## 视频模式下"开始游戏"的活体按钮（中值贴图）及其附属特效。
var _start_btn: TextureButton
var _sweep: Sprite2D
var _hover_embers: CPUParticles2D
var _click_burst: CPUParticles2D
var _starting := false
## 其余视频按钮的透明热区，_layout 里按帧矩形重新对位。
var _hotzones: Array[Button] = []
## 商店/设置/退出的抠图按钮（开始按钮单独用 _start_btn）。
var _menu_btns: Array[TextureButton] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_viewport_size = get_viewport().get_visible_rect().size
	get_viewport().size_changed.connect(_layout)
	_layout()

func show_screen(data: Dictionary) -> void:
	# 开始页在游戏期间禁用处理；返回菜单后恢复，即使游戏仍处于暂停状态。
	process_mode = Node.PROCESS_MODE_ALWAYS
	coins = int(data.get("coins", 0))
	# 卡片控件在 _ready 里只建一次；这里只按最新数据刷文字与可用状态。
	# （一开始在这里 clear 了 _shop_refs，结果刷新循环找不到控件，商店永远是旧价 ——
	# 状态字典和控件引用的生命周期必须分开。）
	_build_shop_cards(data)
	# 上一局点开始时按钮可能还停在"放大 + 火花"的演出中，重开一局要归位。
	_starting = false
	if _start_btn != null:
		_start_btn.scale = Vector2.ONE
	for mb in _menu_btns:
		mb.scale = Vector2.ONE
		var embers: CPUParticles2D = mb.get_meta("embers", null)
		if embers != null:
			embers.emitting = false
	if _hover_embers != null:
		_hover_embers.emitting = false
	_close_coin_popup()
	visible = true
	_refresh()

func hide_screen() -> void:
	visible = false
	# 子节点继承该模式：背景帧、角色动画、粒子、氛围重绘一起停止。
	# 单纯 visible=false 只停止显示，并不能停止上述计算。
	process_mode = Node.PROCESS_MODE_DISABLED


## 雷达扫描光效的旋转。中值贴图把视频里旋转的扫描线冻成了均匀微光，
## 这里用一层加色旋转的光楔补回动感。
func _process(delta: float) -> void:
	if _sweep != null and visible:
		_sweep.rotation += delta * 2.4

func _build() -> void:
	_build_animated_background()
	var atmosphere := ATMOSPHERE_SCRIPT.new()
	atmosphere.name = "AnimatedAtmosphere"
	atmosphere.set_anchors_preset(Control.PRESET_FULL_RECT)
	atmosphere.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(atmosphere)
	# 视频帧已经包含了参考图中的角色卡与金币栏，避免再叠一套旧控件。
	if not _video_background:
		_build_character_display()
		_build_coin_panel()
		_build_menu_box()
	else:
		_build_video_overlays()
		_build_video_buttons()

	_status = Label.new()
	_status.position = Vector2(430, 515)
	_status.custom_minimum_size = Vector2(420, 30)
	_status.size = Vector2(420, 30)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", Color("#e0bd8e"))
	_status.add_theme_color_override("font_outline_color", Color(0.02, 0.025, 0.028, 0.9))
	_status.add_theme_constant_override("outline_size", 4)
	add_child(_status)

	_build_shop_panel()
	_build_coin_popup()

func _build_animated_background() -> void:
	var first_video := load(VIDEO_BACKGROUND_DIR + "frame_000.jpg") as Texture2D
	if first_video != null:
		_video_background = true
		var video_frames := SpriteFrames.new()
		video_frames.remove_animation("default")
		video_frames.add_animation("ambient")
		video_frames.set_animation_speed("ambient", 6.0)
		video_frames.set_animation_loop("ambient", true)
		for i in VIDEO_FRAME_COUNT:
			var frame := load(VIDEO_BACKGROUND_DIR + "frame_%03d.jpg" % i) as Texture2D
			if frame != null:
				video_frames.add_frame("ambient", frame)
		var video_bg := AnimatedSprite2D.new()
		video_bg.name = "VideoBackground"
		video_bg.sprite_frames = video_frames
		video_bg.animation = "ambient"
		video_bg.autoplay = "ambient"
		video_bg.position = Vector2.ZERO
		video_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		video_bg.z_index = -10
		_background = video_bg
		add_child(video_bg)
		return

	var sheet := load(START_BACKGROUND_SHEET_PATH) as Texture2D
	if sheet == null:
		var fallback := TextureRect.new()
		fallback.texture = load("res://assets/ui/start_background_clean.png")
		fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
		fallback.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fallback.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(fallback)
		return
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("ambient")
	# 这组背景帧是镜头横移素材，不是高速动作帧。正向播放后再反向播放，
	# 可以避免回到第 1 帧时突然跳回起点；降到 2.4fps 后氛围会更平稳。
	frames.set_animation_speed("ambient", 2.4)
	var background_frames: Array[AtlasTexture] = []
	for i in 8:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(i * sheet.get_width() / 8.0, 0.0, sheet.get_width() / 8.0, sheet.get_height())
		background_frames.append(atlas)
	for atlas in background_frames:
		frames.add_frame("ambient", atlas)
	for i in range(background_frames.size() - 2, 0, -1):
		frames.add_frame("ambient", background_frames[i])
	var bg := AnimatedSprite2D.new()
	bg.name = "AnimatedBackground"
	bg.sprite_frames = frames
	bg.animation = "ambient"
	bg.autoplay = "ambient"
	frames.set_animation_loop("ambient", true)
	bg.position = Vector2.ZERO
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.z_index = -10
	_background = bg
	add_child(bg)

	# 暗色蒙版让金属 UI 在动态背景上保持清晰，同时保留灯火的暖色。
	var shade := ColorRect.new()
	shade.name = "BackgroundShade"
	shade.color = Color(0.015, 0.022, 0.026, 0.38)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.z_index = -9
	add_child(shade)

func _build_coin_panel() -> void:
	_coin_panel = PanelContainer.new()
	_coin_panel.name = "CoinPanel"
	_coin_panel.custom_minimum_size = Vector2(245, 58)
	_coin_panel.size = Vector2(245, 58)
	_coin_panel.add_theme_stylebox_override("panel", _metal_panel(Color("#20201b"), Color("#b99a60"), 9, 3))
	add_child(_coin_panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_coin_panel.add_child(row)

	var coin := Label.new()
	coin.text = "◉"
	coin.add_theme_font_size_override("font_size", 30)
	coin.add_theme_color_override("font_color", Color("#e4b95f"))
	coin.add_theme_color_override("font_outline_color", Color("#5a3d22"))
	coin.add_theme_constant_override("outline_size", 5)
	row.add_child(coin)

	_coin_label = Label.new()
	_coin_label.text = "金币  0"
	_coin_label.custom_minimum_size = Vector2(125, 42)
	_coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coin_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_coin_label.add_theme_font_size_override("font_size", 19)
	_coin_label.add_theme_color_override("font_color", Color("#f5d28b"))
	_coin_label.add_theme_color_override("font_outline_color", Color("#3b281a"))
	_coin_label.add_theme_constant_override("outline_size", 4)
	row.add_child(_coin_label)

	var plus := Label.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(34, 34)
	plus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plus.add_theme_font_size_override("font_size", 24)
	plus.add_theme_color_override("font_color", Color("#f1d7a1"))
	plus.add_theme_stylebox_override("normal", _metal_panel(Color("#62472c"), Color("#d2ae6d"), 5, 2))
	row.add_child(plus)

## 视频模式下的前景元素：角色卡与金币栏精灵 + 真数据的金币数字。
##
## 背景视频换成"纯背景"版后，这些 UI 不再烘在视频里，改用从旧版
## UI 视频中值抠出的精灵叠在背景上；金币栏抠图时已把"金币 309"
## 修掉，这里只画 Main 传来的真实数值，不需要色块补丁。
func _build_video_overlays() -> void:
	var card_tex := load(ROLE_CARD_PATH) as Texture2D
	if card_tex != null:
		_role_card_sprite = _make_cutout_sprite(card_tex)
		add_child(_role_card_sprite)
	var panel_tex := load(COIN_PANEL_PATH) as Texture2D
	if panel_tex != null:
		_coin_panel_sprite = _make_cutout_sprite(panel_tex)
		add_child(_coin_panel_sprite)
	_video_coin_label = Label.new()
	_video_coin_label.name = "VideoCoinValue"
	_video_coin_label.add_theme_font_override("font", PIXEL_FONT)
	_video_coin_label.add_theme_font_size_override("font_size", 19)
	_video_coin_label.add_theme_color_override("font_color", Color("#f1cf8a"))
	_video_coin_label.add_theme_color_override("font_outline_color", Color("#3a2a1c"))
	_video_coin_label.add_theme_constant_override("outline_size", 3)
	_video_coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_video_coin_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_video_coin_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_video_coin_label)

	# 金币栏右侧的 "+" 按钮：贴图与栏内烘焙像素 1:1 重合（同出旧视频中值）。
	# 分两层 —— 贴图只管显示（鼠标穿透），底下垫一个放大的透明热区负责
	# 交互：38px 的小图标如果只有自身大小的点击区，点起来会非常难受。
	# 悬停放大 + 余烬提示可点，点击弹出金币说明。
	var plus_tex := load(COIN_PLUS_PATH) as Texture2D
	if plus_tex != null:
		var visual := _make_cutout_sprite(plus_tex)
		visual.name = "CoinPlusVisual"
		add_child(visual)
		_coin_plus_visual = visual

		var embers := _make_embers()
		embers.amount = 10
		visual.add_child(embers)
		visual.set_meta("embers", embers)

		var hotzone := Button.new()
		hotzone.name = "CoinPlusHotzone"
		hotzone.focus_mode = Control.FOCUS_NONE
		hotzone.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var empty := StyleBoxEmpty.new()
		for state: String in ["normal", "hover", "pressed", "focus"]:
			hotzone.add_theme_stylebox_override(state, empty)
		hotzone.mouse_entered.connect(_on_coin_plus_hover.bind(true))
		hotzone.mouse_exited.connect(_on_coin_plus_hover.bind(false))
		hotzone.button_down.connect(func() -> void: _tween_btn_scale(visual, 0.9, 0.06))
		hotzone.button_up.connect(func() -> void: _tween_btn_scale(visual, 1.16, 0.1, Tween.TRANS_BACK))
		hotzone.pressed.connect(_open_coin_popup)
		hotzone.set_meta("frame_rect", COIN_PLUS_RECT.grow(16.0))
		add_child(hotzone)
		_coin_plus_hotzone = hotzone


func _on_coin_plus_hover(hovered: bool) -> void:
	if _coin_plus_visual == null:
		return
	_tween_btn_scale(_coin_plus_visual, 1.16 if hovered else 1.0, 0.12,
		Tween.TRANS_BACK if hovered else Tween.TRANS_QUAD)
	var embers: CPUParticles2D = _coin_plus_visual.get_meta("embers", null)
	if embers != null:
		embers.emitting = hovered


## 金币说明弹窗：点金币栏的 "+" 弹出。只讲金币的来源与用途 ——
## 本作没有任何充值入口，文案里也不出现这类字眼。
func _build_coin_popup() -> void:
	_coin_popup = PanelContainer.new()
	_coin_popup.name = "CoinInfoPopup"
	_coin_popup.visible = false
	_coin_popup.add_theme_stylebox_override("panel",
		_metal_panel(Color("#211b16"), Color("#b0925d"), 12, 3))
	_coin_popup.custom_minimum_size = Vector2(580, 0)
	add_child(_coin_popup)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_coin_popup.add_child(col)

	var title := Label.new()
	title.text = "金币  //  COINS"
	title.add_theme_font_override("font", PIXEL_FONT)
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#f0c486"))
	title.add_theme_color_override("font_outline_color", Color("#3c2b1c"))
	title.add_theme_constant_override("outline_size", 4)
	col.add_child(title)

	var lines := [
		["金币只在前线挣得，每局结束结算：", false],
		["结算金币 = 3 + 波次 × 2 + 击杀数 ÷ 5", true],
		["波次撑得越深、击杀越多，带回来的金币就越多。", false],
		["", false],
		["金币在商店采购下一局的补给：", false],
		["升级卡牌 · 手雷 · 生命药水 · 复活药剂 · 行囊栏位", true],
		["买下的东西在下一局开局时自动生效。", false],
	]
	for line: Array in lines:
		var l := Label.new()
		l.text = String(line[0])
		l.add_theme_font_override("font", PIXEL_FONT)
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color",
			Color("#f5cf73") if bool(line[1]) else Color("#c8a877"))
		col.add_child(l)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(row)
	var ok := Button.new()
	ok.text = "知道了"
	ok.custom_minimum_size = Vector2(116, 42)
	ok.add_theme_font_override("font", PIXEL_FONT)
	ok.add_theme_font_size_override("font_size", 16)
	_apply_menu_style(ok, Color("#4a3024"))
	ok.pressed.connect(_close_coin_popup)
	row.add_child(ok)


func _open_coin_popup() -> void:
	set_status("")
	if _coin_popup != null:
		_coin_popup.visible = true


func _close_coin_popup() -> void:
	if _coin_popup != null:
		_coin_popup.visible = false


## 抠图精灵的共同配置：位置尺寸由 _layout 按帧坐标换算，
## NEAREST 与背景视频保持同一套像素过滤。
func _make_cutout_sprite(tex: Texture2D) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _build_character_display() -> void:
	# 完整幸存者展示框移到左上角，替代原来的小角色按钮。
	var frame := Panel.new()
	frame.name = "RoleFrame"
	frame.position = SURVIVOR_FRAME_POSITION
	frame.size = Vector2(236, 342)
	frame.clip_contents = true
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", _metal_panel(Color(0.035, 0.055, 0.057, 0.92), Color("#a88a55"), 12, 3))
	_role_frame = frame
	add_child(frame)

	var header := Label.new()
	header.text = "SURVIVOR  //  01"
	header.position = Vector2(16, 12)
	header.size = Vector2(204, 24)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color("#c9aa6e"))
	frame.add_child(header)

	var caption := Label.new()
	caption.text = "幸存者  ·  READY"
	caption.position = Vector2(10.0, 272.0)
	caption.size = Vector2(216.0, 25.0)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 15)
	caption.add_theme_color_override("font_color", Color("#8fe3a6"))
	caption.add_theme_color_override("font_outline_color", Color("#173120"))
	caption.add_theme_constant_override("outline_size", 4)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(caption)

	var sheet := load(START_SURVIVOR_SHEET_PATH) as Texture2D
	if sheet == null:
		return
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("walk")
	frames.set_animation_speed("walk", 8.0)
	var cell_width := float(sheet.get_width()) / 6.0
	for i in 6:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(cell_width * i, 0.0, cell_width, sheet.get_height())
		frames.add_frame("walk", atlas)

	var survivor := AnimatedSprite2D.new()
	survivor.name = "AnimatedSurvivor"
	survivor.sprite_frames = frames
	survivor.animation = "walk"
	survivor.autoplay = "walk"
	survivor.position = SURVIVOR_PORTRAIT_POSITION
	survivor.scale = Vector2(SURVIVOR_PORTRAIT_SCALE, SURVIVOR_PORTRAIT_SCALE)
	survivor.z_index = 2
	frame.add_child(survivor)

	var xp := ProgressBar.new()
	xp.name = "ProfileXP"
	xp.position = Vector2(24, 312)
	xp.size = Vector2(188, 12)
	xp.max_value = 100.0
	xp.value = 28.0
	xp.show_percentage = false
	xp.add_theme_stylebox_override("background", _metal_panel(Color("#101719"), Color("#6f5a39"), 3, 1))
	xp.add_theme_stylebox_override("fill", _flat(Color("#d0a552"), 3, Color("#e0b96c"), 1))
	frame.add_child(xp)

func _make_survivor_sprite(scale_value: float) -> AnimatedSprite2D:
	var sheet := load(START_SURVIVOR_SHEET_PATH) as Texture2D
	if sheet == null:
		return null
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("walk")
	frames.set_animation_speed("walk", 8.0)
	var cell_width := float(sheet.get_width()) / 6.0
	for i in 6:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(cell_width * i, 0.0, cell_width, sheet.get_height())
		frames.add_frame("walk", atlas)
	var survivor := AnimatedSprite2D.new()
	survivor.sprite_frames = frames
	survivor.animation = "walk"
	survivor.autoplay = "walk"
	survivor.scale = Vector2(scale_value, scale_value)
	return survivor

## 非视频模式的中间主菜单（代码绘制的金属皮肤）。
func _build_menu_box() -> void:
	_menu_box = VBoxContainer.new()
	_menu_box.name = "MainMenu"
	_menu_box.custom_minimum_size = Vector2(320, 360)
	_menu_box.size = Vector2(320, 360)
	_menu_box.add_theme_constant_override("separation", 8)
	add_child(_menu_box)

	var start := _make_menu_button("开始游戏")
	start.pressed.connect(func() -> void: start_requested.emit())
	_menu_box.add_child(start)
	var shop := _make_menu_button("商店")
	shop.pressed.connect(_open_shop)
	_menu_box.add_child(shop)
	var settings := _make_menu_button("设置")
	settings.pressed.connect(func() -> void: set_status("设置界面即将开放"))
	_menu_box.add_child(settings)
	var exit := _make_menu_button("退出")
	exit.pressed.connect(func() -> void: get_tree().quit())
	_menu_box.add_child(exit)


func _make_menu_button(text_value: String) -> Button:
	var b := Button.new()
	b.text = "      " + text_value
	b.custom_minimum_size = Vector2(350, 62)
	b.add_theme_font_override("font", PIXEL_FONT)
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_outline_color", Color("#3c2b1c"))
	b.add_theme_constant_override("outline_size", 4)
	_apply_menu_style(b, Color("#51483a"))
	return b

func _apply_menu_style(b: Button, color: Color) -> void:
	b.add_theme_color_override("font_color", Color("#f0d29b"))
	b.add_theme_color_override("font_hover_color", Color("#fff3cf"))
	b.add_theme_color_override("font_pressed_color", Color("#ffc96e"))
	b.add_theme_stylebox_override("normal", _metal_panel(color, Color("#9c8455"), 9, 2))
	b.add_theme_stylebox_override("hover", _metal_panel(Color("#6a5a41"), Color("#e0bb6d"), 9, 3))
	b.add_theme_stylebox_override("pressed", _metal_panel(Color("#332a20"), Color("#f0c486"), 9, 3))

## ---------------------------------------------------------------- 视频模式按钮

## 视频模式下四个按钮都从旧版 UI 视频中值抠出（背景已是纯背景视频，
## 按钮不再是画面的一部分），位置按帧坐标 --(cover 缩放 + 居中)--> 屏幕
## 换算，见 _frame_to_screen。
##
## "开始游戏"额外挂三样：悬停余烬、点击爆发、雷达扫描光效。
## 中值贴图把 AI 视频的边框闪烁和飘过按钮前的雪花全部滤掉了，
## 所以悬停放大时变大的是干净的按钮本身。
func _build_video_buttons() -> void:
	_build_start_button()
	for kind: String in VIDEO_BUTTON_RECTS:
		_build_menu_button_sprite(kind)


func _build_start_button() -> void:
	var tex := load(START_OVERLAY_PATH) as Texture2D
	if tex == null:
		# 贴图缺失（还没跑导入等）时退回透明热区，按钮至少还能点。
		_add_fallback_hotzone(START_BTN_RECT, _on_start_pressed)
		return
	var btn := _make_video_button(tex, START_BTN_RECT)
	btn.name = "StartButton"
	btn.mouse_entered.connect(_on_start_hover.bind(true))
	btn.mouse_exited.connect(_on_start_hover.bind(false))
	btn.button_down.connect(_on_start_down)
	btn.button_up.connect(_on_start_up)
	btn.pressed.connect(_on_start_pressed)
	add_child(btn)
	_start_btn = btn

	_hover_embers = _make_embers()
	btn.add_child(_hover_embers)
	_click_burst = _make_burst()
	btn.add_child(_click_burst)

	var sweep_tex := load(RADAR_SWEEP_PATH) as Texture2D
	if sweep_tex != null:
		_sweep = Sprite2D.new()
		_sweep.texture = sweep_tex
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_sweep.material = mat
		# 中值把旋转的扫描线抹成了均匀微光，这里叠一层旋转光效补回来。
		btn.add_child(_sweep)


func _build_menu_button_sprite(kind: String) -> void:
	var rect: Rect2 = VIDEO_BUTTON_RECTS[kind]
	var tex := load(VIDEO_BUTTON_PATHS[kind]) as Texture2D
	if tex == null:
		_add_fallback_hotzone(rect, _menu_action_for(kind))
		return
	var btn := _make_video_button(tex, rect)
	btn.name = "VideoButton_" + kind
	btn.mouse_entered.connect(_on_menu_hover.bind(btn, true))
	btn.mouse_exited.connect(_on_menu_hover.bind(btn, false))
	btn.button_down.connect(_on_menu_down.bind(btn))
	btn.button_up.connect(_on_menu_up.bind(btn))
	btn.pressed.connect(_on_menu_pressed.bind(btn, kind))
	add_child(btn)
	_menu_btns.append(btn)

	# 悬停余烬 + 点击爆发：与开始按钮同一套粒子，四个按钮手感一致。
	# 发射器挂在各自按钮的 meta 上，悬停/布局时按需取用。
	var embers := _make_embers()
	btn.add_child(embers)
	btn.set_meta("embers", embers)
	var burst := _make_burst()
	btn.add_child(burst)
	btn.set_meta("burst", burst)


func _menu_action_for(kind: String) -> Callable:
	match kind:
		"shop":
			return _open_shop
		"settings":
			return func() -> void: set_status("设置界面即将开放")
		"exit":
			return func() -> void: get_tree().quit()
	return Callable()


## 四个视频按钮共用的配置：贴图即外观，矩形存在元数据上供 _layout 对位。
func _make_video_button(tex: Texture2D, rect: Rect2) -> TextureButton:
	var btn := TextureButton.new()
	btn.texture_normal = tex
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	# 与视频背景同为 NEAREST：放大时像素块干净，不糊边。
	btn.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.set_meta("frame_rect", rect)
	return btn


## 贴图缺失时的透明热区，保证按钮仍可点。
func _add_fallback_hotzone(rect: Rect2, action: Callable) -> void:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var empty := StyleBoxEmpty.new()
	for state: String in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, empty)
	b.pressed.connect(action)
	add_child(b)
	b.set_meta("frame_rect", rect)
	_hotzones.append(b)


## 帧坐标矩形 -> 屏幕坐标矩形。与 _layout 里背景的 cover 缩放完全同一套公式，
## 这是所有"画在视频里"的元素能对齐的前提。
func _frame_to_screen(rect: Rect2, frame_center: Vector2) -> Rect2:
	var top_left := _viewport_size * 0.5 + (rect.position - frame_center) * _video_scale
	return Rect2(top_left, rect.size * _video_scale)


## 柔光圆点贴图（运行时生成），给粒子当纹理，不用额外素材文件。
func _make_soft_dot_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 32
	tex.height = 32
	return tex


## 悬停时按钮上方飘起金色余烬，和开始页氛围层的灰烬同一气质。
##
## ⚠ 发射区必须覆盖按钮全高、速度要够大：粒子若只在亮色金属板上
## 漂几像素就消亡，加色混合在亮底上等于隐形 —— 火花要能升出按钮
## 上沿、进入暗色背景才看得见。
func _make_embers() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "HoverEmbers"
	p.texture = _make_soft_dot_texture()
	p.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	p.emitting = false
	p.amount = 26
	p.lifetime = 1.6
	p.lifetime_randomness = 0.3
	# 预热一轮：鼠标一进来就是满效果的粒子流，而不是等 1 秒攒出来。
	p.preprocess = 1.0
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0, -1)
	p.spread = 20.0
	p.gravity = Vector2(0, -55)
	p.initial_velocity_min = 30.0
	p.initial_velocity_max = 70.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.1
	# 中段最亮、首尾透明：粒子出现和消失都不突兀。
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.84, 0.5, 0.0))
	ramp.add_point(0.2, Color(1.0, 0.86, 0.55, 0.9))
	ramp.add_point(0.65, Color(1.0, 0.76, 0.38, 0.5))
	ramp.set_color(ramp.get_point_count() - 1, Color(1.0, 0.8, 0.4, 0.0))
	p.color_ramp = ramp
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	p.material = mat
	return p


## 点击时从按钮中心炸开的一圈金色火花。
func _make_burst() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "ClickBurst"
	p.texture = _make_soft_dot_texture()
	p.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 28
	p.lifetime = 0.65
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 10.0
	p.direction = Vector2(0, -1)
	p.spread = 180.0
	p.gravity = Vector2(0, 140)
	p.initial_velocity_min = 130.0
	p.initial_velocity_max = 240.0
	p.damping_min = 40.0
	p.damping_max = 90.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.1
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.95, 0.75, 0.95))
	ramp.set_color(1, Color(1.0, 0.7, 0.3, 0.0))
	p.color_ramp = ramp
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	p.material = mat
	return p


func _on_start_hover(hovered: bool) -> void:
	if _starting or _start_btn == null:
		return
	_tween_btn_scale(_start_btn, START_HOVER_SCALE if hovered else 1.0, 0.14,
		Tween.TRANS_BACK if hovered else Tween.TRANS_QUAD)
	if _hover_embers != null:
		_hover_embers.emitting = hovered


func _on_start_down() -> void:
	if _starting:
		return
	_tween_btn_scale(_start_btn, 0.94, 0.06)


func _on_start_up() -> void:
	if _starting:
		return
	_tween_btn_scale(_start_btn, START_HOVER_SCALE + 0.02, 0.12, Tween.TRANS_BACK)


## 点击：下压回弹 → 放大 + 火花爆发 → 短暂停顿 → 才真正开局。
## 直接 emit 的话开始页立刻隐藏，玩家一点效果都看不见。
func _on_start_pressed() -> void:
	if _starting:
		return
	_starting = true
	if _hover_embers != null:
		_hover_embers.emitting = false
	if _click_burst != null:
		_click_burst.restart()
	_tween_btn_scale(_start_btn, 1.16, 0.2, Tween.TRANS_BACK)
	await get_tree().create_timer(0.3).timeout
	start_requested.emit()


func _tween_btn_scale(btn: Control, target: float, dur: float,
		trans: int = Tween.TRANS_QUAD) -> void:
	if btn == null:
		return
	if btn.has_meta("scale_tween") and (btn.get_meta("scale_tween") as Tween).is_valid():
		(btn.get_meta("scale_tween") as Tween).kill()
	var tw := create_tween()
	tw.tween_property(btn, "scale", Vector2.ONE * target, dur)\
		.set_trans(trans).set_ease(Tween.EASE_OUT)
	btn.set_meta("scale_tween", tw)


## ---------------------------------------------------------------- 普通视频按钮

## 三个菜单按钮的悬停：缩放幅度比开始按钮小一档（1.06），但余烬粒子
## 与开始按钮同款 —— 整列按钮的反馈语言保持一致。
func _on_menu_hover(btn: TextureButton, hovered: bool) -> void:
	_tween_btn_scale(btn, MENU_HOVER_SCALE if hovered else 1.0, 0.12,
		Tween.TRANS_BACK if hovered else Tween.TRANS_QUAD)
	var embers: CPUParticles2D = btn.get_meta("embers", null)
	if embers != null:
		embers.emitting = hovered


func _on_menu_down(btn: TextureButton) -> void:
	_tween_btn_scale(btn, 0.96, 0.06)


func _on_menu_up(btn: TextureButton) -> void:
	_tween_btn_scale(btn, MENU_HOVER_SCALE + 0.02, 0.1, Tween.TRANS_BACK)


## 菜单按钮点击：先炸一轮火花再执行动作，和开始按钮同一节奏。
func _on_menu_pressed(btn: TextureButton, kind: String) -> void:
	var burst: CPUParticles2D = btn.get_meta("burst", null)
	if burst != null:
		burst.restart()
	_menu_action_for(kind).call()

## ---------------------------------------------------------------- 商店面板

func _open_shop() -> void:
	set_status("")
	if _shop_backdrop != null:
		_shop_backdrop.visible = true
	_shop_panel.visible = true

func _close_shop() -> void:
	if _shop_backdrop != null:
		_shop_backdrop.visible = false
	_shop_panel.visible = false

func _build_shop_panel() -> void:
	# 商店打开时压暗主菜单，避免背景按钮和商品卡争抢视觉焦点。
	_shop_backdrop = ColorRect.new()
	_shop_backdrop.color = Color(0.015, 0.02, 0.024, 0.68)
	_shop_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_shop_backdrop.visible = false
	_shop_backdrop.z_index = 20
	add_child(_shop_backdrop)

	# 外层必须是固定尺寸的 Panel；PanelContainer 会在显示时被长说明文字撑高，
	# 进而把商店底部推出屏幕。内容再放进全尺寸 MarginContainer，职责分开。
	_shop_panel = Panel.new()
	_shop_panel.visible = false
	_shop_panel.z_index = 21
	_shop_panel.add_theme_stylebox_override("panel",
		_metal_panel(Color("#1b1714"), Color("#c49a57"), 14, 3))
	_shop_panel.position = Vector2(130, 92)
	_shop_panel.custom_minimum_size = Vector2(1080, 548)
	_shop_panel.size = Vector2(1080, 548)
	add_child(_shop_panel)

	var body := MarginContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 18.0
	body.offset_top = 15.0
	body.offset_right = -18.0
	body.offset_bottom = -15.0
	_shop_panel.add_child(body)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	body.add_child(col)

	# 标题行：铜色标题、金币胶囊和返回按钮形成清晰的操作区。
	var head := HBoxContainer.new()
	head.custom_minimum_size = Vector2(0, 54)
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)
	var title := Label.new()
	title.text = "商 店  //  SUPPLY DEPOT"
	title.custom_minimum_size = Vector2(420, 48)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 25)
	title.add_theme_color_override("font_color", Color("#f0c486"))
	title.add_theme_color_override("font_outline_color", Color("#3c2b1c"))
	title.add_theme_constant_override("outline_size", 5)
	head.add_child(title)
	# 弹性占位，把金币和返回推到右侧
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	_shop_coins_label = Label.new()
	_shop_coins_label.custom_minimum_size = Vector2(170, 42)
	_shop_coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shop_coins_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_shop_coins_label.add_theme_font_size_override("font_size", 19)
	_shop_coins_label.add_theme_color_override("font_color", Color("#f5cf73"))
	_shop_coins_label.add_theme_stylebox_override("normal", _metal_panel(Color("#2d211a"), Color("#9d704c"), 5, 2))
	head.add_child(_shop_coins_label)
	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(112, 42)
	back.add_theme_font_size_override("font_size", 17)
	_apply_menu_style(back, Color("#4a3024"))
	back.pressed.connect(_close_shop)
	head.add_child(back)

	# 商品说明：所有商品共用这句提示，价格增长曲线是全局机制
	var hint := Label.new()
	hint.text = "每买一个，同款商品都会涨价   ·   买下的东西下局开局时生效"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color("#d0ad70"))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)

	# 商品卡行
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row)
	for it: Dictionary in GameData.SHOP_ITEMS:
		row.add_child(_make_item_card(String(it["id"])))

func _make_item_card(kind: String) -> PanelContainer:
	var it: Dictionary = GameData.shop_item(kind)
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", _metal_panel(Color("#30261e"), Color("#a88752"), 10, 2))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	card.add_child(col)

	# 统一的插画窗格让五张卡片等高；图标本身保持原比例，不再被文字挤扁。
	var icon_frame := PanelContainer.new()
	icon_frame.custom_minimum_size = Vector2(0, 132)
	icon_frame.add_theme_stylebox_override("panel",
		_metal_panel(Color("#182125"), Color("#6d8b82"), 8, 2))
	var icon := TextureRect.new()
	icon.texture = GameData.item_icon(kind)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, 118)
	if icon.texture == null:
		# 行囊栏位没有独立素材，用一个有辨识度的工程图占位，避免出现黑块。
		var slot_label := Label.new()
		slot_label.text = "▧\nSLOT"
		slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot_label.add_theme_font_size_override("font_size", 30)
		slot_label.add_theme_color_override("font_color", Color("#d9bd86"))
		slot_label.add_theme_color_override("font_outline_color", Color("#443424"))
		slot_label.add_theme_constant_override("outline_size", 4)
		icon_frame.add_child(slot_label)
	else:
		icon_frame.add_child(icon)
	col.add_child(icon_frame)

	var name_label := Label.new()
	name_label.text = String(it["name"])
	name_label.custom_minimum_size = Vector2(0, 34)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", Color("#f2d4a1"))
	name_label.add_theme_stylebox_override("normal", _metal_panel(Color("#4c3926"), Color("#aa8550"), 5, 1))
	col.add_child(name_label)

	var desc := Label.new()
	desc.text = String(it["desc"])
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 52)
	desc.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", 12)
	desc.add_theme_color_override("font_color", Color("#c6aa7d"))
	col.add_child(desc)

	var count_label := Label.new()
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 12)
	count_label.custom_minimum_size = Vector2(0, 20)
	count_label.add_theme_color_override("font_color", Color("#a6b4b1"))
	col.add_child(count_label)

	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_label.custom_minimum_size = Vector2(0, 30)
	price_label.add_theme_font_size_override("font_size", 19)
	price_label.add_theme_color_override("font_color", Color("#f5cf73"))
	col.add_child(price_label)

	var buy := Button.new()
	buy.text = "购买"
	buy.custom_minimum_size = Vector2(0, 42)
	buy.add_theme_font_size_override("font_size", 15)
	_apply_menu_style(buy, Color("#765038"))
	buy.pressed.connect(func() -> void: buy_requested.emit(kind))
	col.add_child(buy)
	card.mouse_entered.connect(func() -> void:
		card.add_theme_stylebox_override("panel", _metal_panel(Color("#3b3025"), Color("#e2ba68"), 10, 3)))
	card.mouse_exited.connect(func() -> void:
		card.add_theme_stylebox_override("panel", _metal_panel(Color("#30261e"), Color("#a88752"), 10, 2)))

	_shop_refs[kind] = {"price": price_label, "count": count_label, "buy": buy}
	return card

## show_screen 每次都会重建卡片数据源，这里按约定字段刷新
func _build_shop_cards(data: Dictionary) -> void:
	for kind: String in _shop_refs:
		var refs: Dictionary = _shop_refs[kind]
		var price := int(data.get(kind + "_price", 0))
		var count := int(data.get(kind + "_count", 0))
		refs["price"].text = "%d 金币" % price
		refs["count"].text = "已购 %d" % count
		var sold_out: bool = kind == "slot" and int(data.get("slot_count", 2)) >= 5
		refs["buy"].disabled = sold_out or coins < price
		refs["buy"].text = "已满" if sold_out else "购买"

## ---------------------------------------------------------------- 状态

func _refresh() -> void:
	if _coin_label != null:
		_coin_label.text = "金币  %d" % coins
	if _video_coin_label != null:
		_video_coin_label.text = "金币 %d" % coins
	if _shop_coins_label != null:
		_shop_coins_label.text = "金币 %d" % coins

func set_status(text: String) -> void:
	if _status != null:
		_status.text = text

func _flat(color: Color, radius: int, border: Color, width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(radius)
	return sb

func _metal_panel(color: Color, border: Color, radius: int = 8, width: int = 2) -> StyleBoxFlat:
	var sb := _flat(color, radius, border, width)
	sb.shadow_color = Color(0.01, 0.012, 0.01, 0.65)
	sb.shadow_size = 7
	sb.shadow_offset = Vector2(0, 4)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 7.0
	sb.content_margin_bottom = 7.0
	return sb

func _layout() -> void:
	_viewport_size = get_viewport().get_visible_rect().size
	if _viewport_size.x <= 0.0 or _viewport_size.y <= 0.0:
		return

	if _background != null and _background.sprite_frames != null:
		var frame_size := _background.sprite_frames.get_frame_texture("ambient", 0).get_size()
		var scale := maxf(_viewport_size.x / frame_size.x, _viewport_size.y / frame_size.y)
		_background.position = _viewport_size * 0.5
		_background.scale = Vector2(scale, scale)

	# 视频是 cover 缩放 + 居中。所有画在帧里的 UI（按钮、金币栏）都用同一套
	# 变换换算到屏幕 —— 用视口比例定位会在非 16:9 窗口下与画面错开。
	_video_scale = maxf(_viewport_size.x / VIDEO_FRAME_SIZE.x, _viewport_size.y / VIDEO_FRAME_SIZE.y)
	var frame_center := VIDEO_FRAME_SIZE * 0.5

	if _start_btn != null:
		var r := _frame_to_screen(START_BTN_RECT, frame_center)
		_start_btn.position = r.position
		_start_btn.size = r.size
		# 缩放围绕中心，悬停放大时按钮原地膨胀而不是往右下角长。
		_start_btn.pivot_offset = r.size * 0.5
		if _hover_embers != null:
			_hover_embers.position = r.size * 0.5
			_hover_embers.emission_rect_extents = Vector2(r.size.x * 0.44, r.size.y * 0.5)
		if _click_burst != null:
			_click_burst.position = r.size * 0.5
		if _sweep != null:
			# 扫描光效钉在雷达圆心上，随按钮一起缩放（换算成按钮本地坐标）。
			_sweep.position = r.size * (RADAR_LOCAL_CENTER / START_BTN_RECT.size)
			_sweep.scale = Vector2.ONE * (r.size.x / START_BTN_RECT.size.x) \
				* (RADAR_RADIUS * 2.0 / 128.0)
	for b in _hotzones:
		var zone: Rect2 = b.get_meta("frame_rect")
		var zr := _frame_to_screen(zone, frame_center)
		b.position = zr.position
		b.size = zr.size
	for mb in _menu_btns:
		var mr := _frame_to_screen(mb.get_meta("frame_rect"), frame_center)
		mb.position = mr.position
		mb.size = mr.size
		mb.pivot_offset = mr.size * 0.5
		var embers: CPUParticles2D = mb.get_meta("embers", null)
		if embers != null:
			embers.position = mr.size * 0.5
			embers.emission_rect_extents = Vector2(mr.size.x * 0.44, mr.size.y * 0.5)
		var burst: CPUParticles2D = mb.get_meta("burst", null)
		if burst != null:
			burst.position = mr.size * 0.5

	# 角色卡 / 金币栏抠图与金币数字，全部按帧坐标换算对位。
	if _role_card_sprite != null:
		var cr := _frame_to_screen(ROLE_CARD_RECT, frame_center)
		_role_card_sprite.position = cr.position
		_role_card_sprite.size = cr.size
	if _coin_panel_sprite != null:
		var pr := _frame_to_screen(COIN_PANEL_RECT, frame_center)
		_coin_panel_sprite.position = pr.position
		_coin_panel_sprite.size = pr.size
	if _video_coin_label != null:
		var lr := _frame_to_screen(COIN_LABEL_RECT, frame_center)
		_video_coin_label.position = lr.position
		_video_coin_label.size = lr.size
	if _coin_plus_visual != null:
		var xr := _frame_to_screen(COIN_PLUS_RECT, frame_center)
		_coin_plus_visual.position = xr.position
		_coin_plus_visual.size = xr.size
		_coin_plus_visual.pivot_offset = xr.size * 0.5
		var pe: CPUParticles2D = _coin_plus_visual.get_meta("embers", null)
		if pe != null:
			pe.position = xr.size * 0.5
			pe.emission_rect_extents = xr.size * 0.5
	if _coin_plus_hotzone != null:
		var hr := _frame_to_screen(_coin_plus_hotzone.get_meta("frame_rect"), frame_center)
		_coin_plus_hotzone.position = hr.position
		_coin_plus_hotzone.size = hr.size
	if _coin_popup != null:
		_coin_popup.position = Vector2(
			(_viewport_size.x - _coin_popup.size.x) * 0.5,
			(_viewport_size.y - _coin_popup.size.y) * 0.5)
	if _shop_backdrop != null:
		_shop_backdrop.position = Vector2.ZERO
		_shop_backdrop.size = _viewport_size

	if _role_frame != null:
		_role_frame.position = Vector2(maxf(24.0, _viewport_size.x * 0.035), maxf(24.0, _viewport_size.y * 0.05))
	if _coin_panel != null:
		_coin_panel.position = Vector2(_viewport_size.x - _coin_panel.custom_minimum_size.x - maxf(24.0, _viewport_size.x * 0.035), maxf(24.0, _viewport_size.y * 0.05))
	if _menu_box != null:
		_menu_box.position = Vector2((_viewport_size.x - _menu_box.custom_minimum_size.x) * 0.5, _viewport_size.y * 0.30)
	if _status != null:
		_status.position = Vector2((_viewport_size.x - 420.0) * 0.5, _viewport_size.y * 0.89)
	if _shop_panel != null:
		# 面板跟随窗口缩放，保证 16:9、4:3 和窄窗口都不会把商品卡裁掉。
		var shop_size := Vector2(
			clampf(_viewport_size.x - 56.0, 760.0, 1080.0),
			clampf(_viewport_size.y - 54.0, 480.0, 548.0))
		_shop_panel.custom_minimum_size = shop_size
		_shop_panel.size = shop_size
		_shop_panel.position = (_viewport_size - shop_size) * 0.5
