# Simplified Chinese (zh-Hans): terms beyond the glossary

Decisions made while translating, so later strings stay consistent. The main table is
[glossary.md](glossary.md).

## Messages

bind mount → 绑定挂载
named volume / anonymous volume → 命名卷 / 匿名卷
volume (file-system volume, not a container volume) → 宗卷 (as macOS / Disk Utility)
healthcheck → 健康检查
restart policy → 重新启动策略
privileged mode / unprivileged → 特权模式 / 非特权
capabilities (Linux, cap_add) → 能力
device passthrough → 设备直通
namespace → 命名空间
hostname → 主机名
socket (Docker socket) → 套接字
swap → 交换空间
driver (network / volume driver) → 驱动
publish / expose (ports) → 发布 / 暴露
host port → 主机端口
registry → 镜像仓库
layers (image) → 层 / 镜像层
archive (image archive) → 归档 / 镜像归档
load (an image) → 载入
save (an image to an archive) → 存储
export (from OrbStack) → 导出
build (images) → 构建
copy (noun: Basket's copy, this copy of Basket) → 副本 (the Copy action stays 拷贝)
Compose file → Compose 文件
top level / top-level (Compose file) → 顶层
profile (Compose) → profile (untranslated; topic heading “profiles”)
secrets / configs (Compose keys, also as topic headings) → secrets / configs (untranslated, as in the file)
sysctls (topic heading) → sysctl
replicas (topic heading) → 副本数
reservations (topic heading) → 资源预留
docker shim → docker shim (untranslated)
bundle identifier / team identifier → 套装 ID / 团队 ID (as App Store Connect)
notarized → 经过公证的
code signed / signed ad hoc → 代码签名 / ad hoc 签名
fork (of the repository) → 复刻版本 (as GitHub)
checksum → 校验和
update key → 更新密钥
Installer → 安装器
Applications folder → “应用程序”文件夹
unzip → 解压缩
YAML terms: mapping 映射, list 列表, key 键, scalar 标量, block scalar 块标量, anchor 锚点, alias 别名, tag 标签, merge key 合并键, flow sequence / flow mapping / flow collection 流式序列 / 流式映射 / 流式集合, escape sequence 转义序列, indentation 缩进
YAML value kinds: a boolean 布尔值, an integer 整数, a number 数字, a string 字符串, a null value 空值
“expected X, found Y” → 应为 X，实际为 Y
“X isn't supported” → 不支持 X
“… is left out” / “ignored” → 将被省略 / 已忽略
“Nothing was changed.” → 未做任何更改。
Progress lines (“Creating …”, “Starting …”) → 正在创建… / 正在启动… (正在 + verb, no ellipsis unless the English has one)

## Interface

guest (the Linux guest in a VM) → 客户机 (“Guest in use” 客户机已用, “Memory (guest)” 内存（客户机）)
host memory column / label → 本机内存; “Memory (host)” 内存（本机）; “On this Mac” 本机占用; “Host (real)” 本机（实际）; “Host” (Overview row) 主机
stranded (label) → 滞留; “%@ stranded” 滞留 %@
VM overhead / VM footprint → 虚拟机开销 / 虚拟机占用
Kill (SIGKILL) → 强制停止
exempt (Memory Saver) → 豁免
keep only one platform (slim action) → 仅保留 %@ / “仅保留一个平台”
dangling (image) → 悬空
untagged → 无标签
digest → 摘要 (so “Summary” is 总结)
writable layer → 可写层
disk image (volume, OrbStack data image) → 磁盘映像
sparse → 稀疏
home folder → 个人文件夹 (machine column “Home” too)
context menu → 快捷菜单
custom (image, platform) → 自定
check (tick checkboxes: “Check for Import”) → 勾选
Enable / Disable → 启用 / 停用; Dismiss → 关闭
login item → 登录项
Setup assistant / Setup (section, step-list subtitle) → 设置助理 / 设置
setup step list: Welcome 欢迎, Install container 安装 container, Start container 启动 container, From OrbStack OrbStack 迁移, docker Command docker 命令, Ready 就绪; “Coming from OrbStack?” 从 OrbStack 迁移？
detail tabs: Info 信息, Logs 日志, Inspect 检查, Stats 统计, Overview 概览
Follow / following (logs) → 跟随 / 跟随中
Read-only / Read-write → 只读 / 读写
Disk I/O → 磁盘 I/O; “R %@” / “W %@” → 读 %@ / 写 %@
container states: Running 运行中, Stopped 已停止, Stopping 正在停止, Created 已创建, Exited 已退出, Dead 已失效, Paused 已暂停, Removing 正在移除, Restarting 正在重新启动, Unknown 未知
alert questions → 要…吗？ (“Delete “%@”?” 要删除“%@”吗？); “… Anyway” buttons → 仍然…
help-tag shortcuts → kept in full-width parentheses: 新建容器（⌘N）, 删除（⌫）
counts → measure words: 个 (containers, images, volumes, networks, services, CPUs), 台 (machines), 行 (log lines), 项 (items)
“%lld of %lld” (compact) → %1$lld/%2$lld; “Step %lld of %lld” → 第 %1$lld 步，共 %2$lld 步
release notes / What’s New → 发布说明 / 新功能; “You’re up to date” 已是最新版本

# Review round (lead decisions)

Up (control) → 创建并启动; Down / Down… → 停止并移除 / 停止并移除…; Down and Delete Volumes… → 停止并移除（含卷）…; Take “%@” down? → 要停止并移除“%@”吗？ (“Compose Up” stays the feature name)
… Anyway (buttons) → 仍要… (仍要删除, 仍要退出, 仍要重新启动, 仍要停止)
项目 → only for Compose projects; other “items” → 项 / 各项 / 内容
Used By / user (of an image or volume) → 使用方
shell → shell, lower case also on buttons (打开 shell)
pays for (memory macOS pays for a VM) → 实际占用的
contacting (a server) → 连接
read (parse a value: “can't read the port”) → 解析
keep only one platform (progress) → 正在精简“%2$@”，仅保留 %1$@
spacing: number + time unit without space (1秒, 15分钟); quoted names (Format.quoted / quotedList) and leading sentences (Format.sentences) without spaces around the placeholder
