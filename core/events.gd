extends Node
## 全局事件总线。
##
## 目的：把「发生了什么」和「谁来响应」解耦。
## 玩法层只管 emit，HUD / 结算界面只管 connect，两边互相不引用对方节点。
## 这样以后加成就系统、音效系统、录像系统，都不用动玩法代码。
##
## 注意：这里只放「事实通知」，不放「请求」。凡是需要返回值或改变流程的，
## 都走直接的节点引用，不走信号 —— 否则调用链会变得难以追踪。

## 玩家血量变化
signal player_health_changed(current: float, maximum: float)

## 玩家等级变化
signal player_level_changed(level: int)

## 玩家经验变化
signal player_xp_changed(current: float, required: float)

## 玩家死亡。注意这只是"事实"，不含统计数字 ——
## 存活时长/击杀数由 Main 组装成 summary 后再发 game_over，
## 因为只有 Main 知道这一局真正跑了多久。
signal player_died()

## 玩家受到伤害（用于屏幕震动、受击音效）
signal player_hurt(pos: Vector2, amount: float)

## 敌人受到伤害（用于飘伤害数字、命中音效）
signal enemy_hurt(pos: Vector2, amount: float)
signal critical_hit(pos: Vector2, amount: float)

## 敌人死亡（用于击杀闪光、经验提示和音效）
signal enemy_killed(pos: Vector2, xp: float, elite: bool)

## 武器开火（用于枪口火光、音效）
signal weapon_fired()

## 带空间位置的开火反馈（枪口闪光、火花）。
signal weapon_fired_at(pos: Vector2, direction: Vector2)

## 电击链从一只丧尸跳到下一只时的空间反馈。
signal chain_zapped(from_pos: Vector2, to_pos: Vector2)

## 环绕飞刃命中敌人。
signal blade_hit(pos: Vector2)

## 累计击杀数变化
signal kills_changed(total: int)

## 进入新一波
signal wave_changed(wave: int)
signal wave_timer_changed(seconds: int)

## 精英丧尸生成位置，用于 HUD 给出方向提示。
signal elite_spawned(pos: Vector2)
signal elite_charge_warning(pos: Vector2)
signal boss_spawned(pos: Vector2)

## 首领血量变化（HUD 顶部的首领专用血条）。
## current / maximum 都是绝对值，由 Zombie 在 spawn 和每次受击时广播。
signal boss_health_changed(current: float, maximum: float)

## 首领进入新阶段（1/2/3）。HUD 用来弹提示、换血条配色。
signal boss_phase_changed(phase: int, pos: Vector2)

## 首领被击杀。HUD 收起血条，Main 负责在原地撒奖励。
signal boss_defeated(pos: Vector2)

## 水域刷怪预警：某个水域将在短延迟后浮出一只溺亡者（阶段3接入）。
signal water_warning(pos: Vector2)

## 本局已存活秒数（每秒发一次）
signal elapsed_time_changed(seconds: float)

## 玩家升级了，请求弹出三选一。由 UpgradeSystem 接管。
signal level_up_requested(level: int)

## 玩家选择了一个升级
signal upgrade_applied(upgrade: Dictionary)

## 玩家吸收经验球
signal xp_collected(value: float)

## 宝箱、物品栏与消耗品
signal chest_opened(pos: Vector2, reward_name: String)
signal inventory_changed(items: Dictionary)
signal item_used(item_id: String, pos: Vector2)
signal player_dodged(pos: Vector2)
## 复活药剂量变化（开局注入 / 倒下时消耗）。count = 剩余充能。
signal revive_changed(count: int)
## 复活药剂在倒下瞬间自动触发。pos = 复活位置。
signal player_revived(pos: Vector2)

## 本局结束
signal game_over(summary: Dictionary)

## 玩家复活 / 重开一局，所有界面应重置
signal run_started()
