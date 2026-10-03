# Spine 角色资源说明

`player_567` 已经放入项目，包含原始 `.skel`、`.atlas` 和贴图文件。

当前项目使用的 Spine Godot 扩展运行时是 **4.3**，而这份 `567.skel` 是 **Spine 3.8.99** 导出文件。运行时已确认可以加载插件和 atlas，但会拒绝加载该 skeleton，因此游戏暂时继续使用 `assets/characters/player/player_567.png` 作为玩家显示资源。

要启用真正的 Spine 动画，需要用与运行时一致的 Spine 4.3（同一大版本和小版本）重新导出 skeleton 与 atlas，然后替换本目录中的文件。官方版本匹配说明：<https://en.esotericsoftware.com/spine-versioning>
