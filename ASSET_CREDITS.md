# 角色素材说明

本项目角色统一使用 Kenney **Top-down Shooter** 素材包中的 CC0 资源：

- 玩家：Survivor 1
- 普通丧尸：Zombie 1
- 守关首领：Robot 1
- 持枪敌人：Soldier 1、Man Blue、Man Old

来源：https://kenney.nl/assets/top-down-shooter
授权：Creative Commons CC0 1.0（附带 License.txt）

角色统一采用相同的俯视角像素画布和尺寸；敌我阵营通过皮肤、颜色、尺寸和血条区分。

# 怪物与 Boss 素材（2026-10-03 升级任务新增）

- `assets/characters/monsters/`（撕裂者 / 喷吐者 / 重锤 / 溺亡者 / boss_abomination）：
  本项目自制 —— Blender 程序化建模 + 正交俯拍渲染（EEVEE，透明背景），
  PIL 归一化并统一烘焙渐变椭圆阴影与深蓝灰轮廓光。
  生成管线脚本存档：`~/.zcode/workspace/default/monster_render/`
  （build_monsters.py / normalize_sprites.py，模型存档 monsters.blend）。
  素材为近中性灰基色，游戏内由变体 tint 染色；无外部素材来源，随本项目授权。
- `assets/characters/kenney/*.png`：在 Kenney 原始 CC0 帧基础上
  烘焙了同规格地面阴影与顶部轮廓光（画布 43→64，脚底对齐 row 60），
  与自制怪物的表现层口径一致。原素材仍为 Kenney CC0。
- 精英丧尸横条表（elite_zombie_walk.png）保持原始素材，未烘焙阴影
  （精英以血条与大体型做视觉识别，属预期差异）。

# 武器素材说明

- 子弹：Project Cordon Sprites 的 `bullet.png`
- 来源：https://github.com/doficia/project-cordon-sprites
- 授权：CC0 1.0

# 开始页 UI 与字体

- 动态开始页背景：由项目提供的视频抽帧生成，保存于 `assets/ui/video_background/`。
- 四按钮备用皮肤：`assets/ui/generated/menu_button_sheet_v1.png`，按参考图生成的透明 PNG。
- 中文像素字体：Fusion Pixel Font，https://github.com/TakWolf/fusion-pixel-font
- 字体授权：SIL Open Font License 1.1（字体文件位于 `assets/ui/fonts/`）。
- 升级卡牌：用户提供的 11 张卡图，已处理为透明资源并保存于 `assets/ui/cards/`。
