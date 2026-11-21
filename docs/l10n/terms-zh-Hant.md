# Traditional Chinese (zh-Hant): terms beyond the glossary

Decisions made while translating, so later strings stay consistent. The main table is
[glossary.md](glossary.md).

## Messages

Up / Down (Compose commands and buttons) → Up / Down (left untranslated like “Compose Up”; “Down with volumes” → 「Down 並刪除磁碟區」, “Up creates it” → 「Up 會建立」)
tag (image tag, YAML tag) → 標記 (標籤 stays reserved for “label”)
copy (noun: “Basket's copy”, “a copy of the image”) → 拷貝 (Basket 中的拷貝 / OrbStack 中的拷貝)
archive, image archive → 封存檔, 映像檔封存檔
directory (paths in Compose / CLI) → 目錄 (Finder “folder” stays 資料夾)
volume (file-system volume, not a container volume) → 宗卷 (as Disk Utility); container volume stays 磁碟區
build (an image) → 建置
registry → 登錄庫
reference (image reference) → 參照
layer (image layer) → 層
configuration (image config) / configs (Compose) → 組態
secrets (Compose) → 機密
profile (Compose profile) → 設定檔
replicas → 副本
reservations → 預留
restart policy → 重新啟動原則
depends on, dependency → 相依 (循環相依, 相依於)
healthcheck → 健康狀態檢查
hostname → 主機名稱
privileged mode → 特權模式; capabilities → 特定權限
namespace → 命名空間
sysctls, kernel parameters → 核心參數
driver (network/volume/logging driver) → 驅動程式
bind mount → 綁定裝載; binding (port binding) → 綁定
named volume / anonymous volume → 具名磁碟區 / 匿名磁碟區
publish (a port) → 發佈; exposed ports → 公開的連接埠; host port → 主機連接埠; listen → 監聽
socket → 通訊端 (Docker 通訊端)
Docker engine → Docker 引擎
shim (docker shim, basket-docker) → 轉接程式
environment (env-var topic and section) → 環境變數
swap → 置換空間
native (vs Rosetta) → 原生
left out, skipped → 略過
rounded up → 無條件進位
timed out → 逾時; exit status → 結束代碼; output → 輸出
update key → 更新金鑰; update information (manifest) → 更新資訊; update server → 更新伺服器
checksum → 總和檢查碼; signature → 簽名; sign / signed → 簽署; notarized → 經過公證
bundle identifier → 套件識別碼; team identifier → 團隊識別碼; app bundle → 應用程式套件
maintainer → 維護者; developer → 開發者; installer → 安裝程式; unzip → 解壓縮
Applications folder → 「應用程式」資料夾; Logs tab → 「記錄」標籤頁
YAML mapping / list / scalar / block scalar → 對映 / 列表 / 純量 / 區塊純量
YAML flow sequence / flow mapping / flow collection → 流式序列 / 流式對映 / 流式集合
YAML anchor / alias / node / key / merge key → 錨點 / 別名 / 節點 / 鍵 / 合併鍵
escape sequence → 跳脫序列; indentation → 縮排; unterminated → 未結束; top level → 頂層
line N, column N → 第 N 行，第 N 欄
value kinds: boolean / integer / number / string / null value → 布林值 / 整數 / 數字 / 字串 / 空值
“expected X, found Y” → 「應為 X，實際為 Y」
Style: progress lines (“Creating network %@”) → 「正在⋯」 prefix with no trailing ellipsis (正在建立網路 %@); operation names inside “%@ is not supported by this backend.” are bare verb phrases (啟動機器, 儲存映像檔)

## Interface

guest (the Linux guest of a VM) → 客體 (Memory (guest) → 記憶體（客體）; used in guests → 客體使用)
host (Memory (host), Host (real), Host Memory) → 本機 (記憶體（本機）, 本機（實際）, 本機記憶體); “Host” row in Overview → 主機
VM overhead / VM footprint → 虛擬機器額外負擔 / 虛擬機器佔用
home folder → 個人專屬資料夾 (as macOS); Applications folder → 「應用程式」資料夾
keep only one platform, Keep Only %@ → 只保留 %@; Slimming… → 正在精簡⋯ (glossary “slim” → 精簡)
Exempt (from Memory Saver) → 排除; Exempt from Memory Saver → 從記憶體節省排除
Kill / Killing… → 強制結束 / 正在強制結束⋯ (as Force Quit)
New Container… / New Volume… → 新增容器⋯ / 新增磁碟區⋯ (Apple “New …” → 新增)
Add Port / Add Variable → 加入連接埠 / 加入變數
Take “%@” down? / Couldn't take the project down → 要關閉「%@」嗎？ / 無法關閉專案 (buttons Up / Down stay untranslated)
Show in Finder / Reveal → 在 Finder 中顯示 / 顯示
Inspect (detail tab) → 檢閱; Info → 資訊; Logs → 記錄; Stats → 統計資料
Follow (logs) → 追蹤; following → 追蹤中
Dangling (image) → 懸空; untagged → 無標記; Digest → 摘要
Used By (column) → 使用對象; Used by %@. → 由 %@ 使用。
On Disk (column) → 磁碟佔用; %@ on disk → 佔用磁碟 %@
Capacity → 容量; Subnet → 子網路; Gateway → 閘道; Mode → 模式; Distribution → 發行版
Processes → 程序 (as Activity Monitor); Activity Monitor → 活動監視器
Setup (section / step-list subtitle) → 初始設定; Setup assistant → 設定輔助程式; Set Up Basket → 設定 Basket
login item → 登入項目; Launch Basket at login → 登入時開啟 Basket
Quit → 結束 (Quit Basket → 結束 Basket; Quit Anyway → 仍要結束)
release notes → 版本說明; What’s New → 新功能; You’re up to date → 已是最新版本
repository → 儲存庫; script → 腳本; session (cache, sessions) → 工作階段
Read-only / Read-write → 唯讀 / 讀寫; R %@ / W %@ (disk I/O) → 讀 %@ / 寫 %@
Step %lld of %lld → 第 %1$lld 步，共 %2$lld 步
Docker states: Created / Exited / Paused / Dead / Removing / Restarting → 已建立 / 已結束 / 已暫停 / 已失效 / 移除中 / 重新啟動中
Note / Warning (VoiceOver) → 附註 / 警告
Spacing: names that arrive already quoted (Format.quoted → 「web」) get no spaces around %@ (要重新啟動%@嗎？); a placeholder that is a preceding Chinese sentence is joined without a space (%1$@已保留映像檔：%2$@), as Format.sentences does for zh
