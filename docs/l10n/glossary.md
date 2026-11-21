# Localization glossary

Basket ships in English (source), Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`,
Taiwan usage), Japanese (`ja`), French (`fr`) and German (`de`). Every string lives in
`Resources/Localization/Localizable.xcstrings`; how to add or translate strings is in
[CONTRIBUTING.md](../../CONTRIBUTING.md#localization).

Use the words macOS itself uses in each language (System Settings, Finder, Activity Monitor,
Disk Utility), and the same word for the same thing everywhere. When a term is missing here,
add it in the same pull request.

## Untranslated

Product and command names stay as they are in every language: **Basket**, **OrbStack**,
**Docker**, **Compose** (and the command name **Compose Up**), the **`container`** CLI and
`container` commands, **Homebrew**, **Rosetta**, **macOS**, **Mac**, **Linux**,
**Apple silicon**, **GitHub**, **Developer ID**, image references (`redis:7`), paths, platform
strings (`linux/arm64`), shell commands, environment variable names and anything in code
formatting. Sizes, percentages, durations and dates come from formatters (`Format.memory`,
`.formatted()`): never write units into a translation.

## Typography

| | en | zh-Hans | zh-Hant | ja | fr | de |
|---|---|---|---|---|---|---|
| Quotes around names | “redis” | “redis” | 「redis」 | 「redis」 | « redis » (U+00A0 inside) | „redis“ |
| Ellipsis (menus, buttons that open a sheet, progress) | `Reclaim…` | `回收…` (U+2026) | `回收⋯` (U+22EF, as Apple's zh-Hant menus) | `解放…` | `Libérer…` | `Freigeben …` (U+00A0 before …, as Apple's German menus) |
| Sentence punctuation | , . : ; ! ? | full-width ，。：；！？ | full-width ，。：；！？ | 、。 full-width ：！？ | U+00A0 before : ; ! ? and » | as English |
| Space between CJK and Latin letters or digits | — | one space (“这台 Mac”) | one space (“這台 Mac”) | none (“このMac”) | — | — |
| Form of address | you | 你 (no 您) | 你 | polite (です／ます) in sentences, plain verbs on buttons | vous | du (as macOS) |
| Buttons and menu items | Title Case verb | verb | verb | verb (〜する is dropped: 削除) | infinitive, sentence case | infinitive |

A placeholder can move inside a sentence but keeps its type; with two or more placeholders use
positional ones (`%1$@`, `%2$lld`). `scripts/check-l10n.sh` checks this.

## Terms

| English | zh-Hans | zh-Hant | ja | fr | de | Notes |
|---|---|---|---|---|---|---|
| container | 容器 | 容器 | コンテナ | conteneur | Container (der) | |
| image | 镜像 | 映像檔 | イメージ | image | Image (das) | A container image, never a picture. |
| volume | 卷 | 磁碟區 | ボリューム | volume | Volume (das) | A named volume (a sparse disk image). |
| network | 网络 | 網路 | ネットワーク | réseau | Netzwerk | |
| machine | 机器 | 機器 | マシン | machine | Maschine | A Linux machine (`container machine`). “Linux machine”: Linux 机器, Linux 機器, Linuxマシン, machine Linux, Linux-Maschine. |
| VM, virtual machine | 虚拟机 | 虛擬機器 | 仮想マシン | machine virtuelle (VM) | virtuelle Maschine (VM) | “VM” may stay where space is short. |
| container system | 容器系统 | 容器系統 | コンテナシステム | système de conteneurs | Containersystem | apple/container's services (`container system start`). |
| Overview | 概览 | 概覽 | 概要 | Vue d’ensemble | Übersicht | Sidebar section. |
| Migrate from OrbStack | 从 OrbStack 迁移 | 從 OrbStack 移轉 | OrbStackから移行 | Migrer depuis OrbStack | Von OrbStack migrieren | Migrate: 迁移 / 移轉 / 移行 / migrer / migrieren (as Migration Assistant). |
| import | 导入 | 匯入 | 読み込む（ボタン: 読み込む） | importer | importieren | |
| memory | 内存 | 記憶體 | メモリ | mémoire | Arbeitsspeicher | de: “Speicher” alone means storage; use Arbeitsspeicher. Narrow table columns and tiles use “RAM” (“Host-RAM”, “RAM (Gast)”). |
| guest (Linux in a VM) / host | 客户机 / 本机 | 客體 / 本機 | ゲスト / このMac | invité / hôte | Gast / Host | “Memory (guest)”: 内存（客户机）, 記憶體（客體）, メモリ（ゲスト）, Mémoire (invité), RAM (Gast). |
| host memory, memory on this Mac | 本机内存 | 本機記憶體 | このMacのメモリ | mémoire de ce Mac | Arbeitsspeicher dieses Mac | What macOS pays for a VM (its footprint). |
| stranded memory | 滞留内存 | 滯留記憶體 | 滞留メモリ | mémoire bloquée | blockierter Arbeitsspeicher | Memory a VM holds after its guest freed it. |
| reclaim | 回收 | 回收 | 解放 | libérer | freigeben | “Reclaim Disk Space”: 回收磁盘空间, 回收磁碟空間, ディスク領域を解放, Libérer de l’espace disque, Speicherplatz freigeben. |
| Memory Saver | 内存节省 | 記憶體節省 | メモリセーバー | Économiseur de mémoire | Speichersparmodus | Feature name: capitalised in fr/de. |
| idle | 空闲 | 閒置 | アイドル | inactif | im Leerlauf | |
| disk, disk space | 磁盘、磁盘空间 | 磁碟、磁碟空間 | ディスク、ディスク領域 | disque, espace disque | Festplatte, Speicherplatz | |
| reclaimable | 可回收 | 可回收 | 解放可能 | récupérable | freigebbar | |
| Compose project | Compose 项目 | Compose 專案 | Composeプロジェクト | projet Compose | Compose-Projekt | |
| service (Compose) | 服务 | 服務 | サービス | service | Dienst | |
| pull (an image) | 拉取 | 拉取 | プル | récupérer | laden | “Pull Image…”: 拉取镜像…, 拉取映像檔⋯, イメージをプル…, Récupérer une image…, Image laden … |
| platform, variant | 平台、变体 | 平台、變體 | プラットフォーム、バリアント | plateforme, variante | Plattform, Variante | `linux/arm64` itself is never translated. |
| slim (keep one platform) | 精简 | 精簡 | スリム化 | alléger | verschlanken | |
| port | 端口 | 連接埠 | ポート | port | Port | |
| environment variable | 环境变量 | 環境變數 | 環境変数 | variable d’environnement | Umgebungsvariable | |
| mount | 挂载 | 裝載 | マウント | montage | Mount | |
| label (container metadata) | 标签 | 標籤 | ラベル | étiquette | Label | |
| logs | 日志 | 記錄 | ログ | journaux | Protokolle | |
| stats | 统计 | 統計資料 | 統計 | statistiques | Statistiken | |
| running / stopped | 运行中 / 已停止 | 執行中 / 已停止 | 実行中 / 停止 | en cours / arrêté | läuft / gestoppt | State labels. |
| start / stop / restart | 启动 / 停止 / 重新启动 | 啟動 / 停止 / 重新啟動 | 起動 / 停止 / 再起動 | démarrer / arrêter / redémarrer | starten / stoppen / neu starten | |
| delete / remove | 删除 / 移除 | 刪除 / 移除 | 削除 | supprimer | löschen / entfernen | |
| recreate | 重新创建 | 重新建立 | 再作成 | recréer | neu erstellen | |
| name conflict | 名称冲突 | 名稱衝突 | 名前の競合 | conflit de nom | Namenskonflikt | |
| refresh | 刷新 | 重新整理 | 再読み込み | actualiser | aktualisieren | |
| search | 搜索 | 搜尋 | 検索 | rechercher | suchen | |
| copy | 拷贝 | 拷貝 | コピー | copier | kopieren | |
| Settings | 设置 | 設定 | 設定 | Réglages | Einstellungen | |
| General (settings tab) | 通用 | 一般 | 一般 | Général | Allgemein | |
| Language | 语言 | 語言 | 言語 | Langue | Sprache | |
| System (follow macOS) | 系统 | 系統 | システム | Système | System | Language picker: follow the macOS language. |
| relaunch | 重新打开 | 重新開啟 | 再起動 | relancer | neu starten | Quit and open Basket again. |
| update | 更新 | 更新項目 | アップデート | mise à jour | Update | “Check for Updates…”: 检查更新…, 檢查更新項目⋯, アップデートを確認…, Rechercher des mises à jour…, Nach Updates suchen … |
| set up | 设置 | 設定 | 設定 | configurer | einrichten | “Set Up Basket”: 设置 Basket, 設定 Basket, Basketを設定, Configurer Basket, Basket einrichten. |
| default | 默认 | 預設 | デフォルト | par défaut | Standard | |
| built-in | 内建 | 內建 | 内蔵 | intégré | integriert | Built-in network. |
| kernel | 内核 | 核心 | カーネル | noyau | Kernel | |
| shell | shell | shell | シェル | shell | Shell | |
| command | 命令 | 指令 | コマンド | commande | Befehl | “the docker command”. |
| folder / file | 文件夹 / 文件 | 資料夾 / 檔案 | フォルダ / ファイル | dossier / fichier | Ordner / Datei | |
| Finder | 访达 | Finder | Finder | Finder | Finder | As macOS names it. |
| Terminal | 终端 | 終端機 | ターミナル | Terminal | Terminal | |
| menu bar | 菜单栏 | 選單列 | メニューバー | barre des menus | Menüleiste | |
| window | 窗口 | 視窗 | ウインドウ | fenêtre | Fenster | |
| Cancel / OK / Done | 取消 / 好 / 完成 | 取消 / 好 / 完成 | キャンセル / OK / 完了 | Annuler / OK / Terminé | Abbrechen / OK / Fertig | |
| Continue / Back / Skip | 继续 / 返回 / 跳过 | 繼續 / 返回 / 略過 | 続ける / 戻る / スキップ | Continuer / Retour / Ignorer | Fortfahren / Zurück / Überspringen | |
| Not Now / Later | 以后 / 稍后 | 現在不要 / 稍後 | 今はしない / あとで | Plus tard / Plus tard | Nicht jetzt / Später | |
| this Mac | 这台 Mac | 這台 Mac | このMac | ce Mac | dieser Mac | |
| Up / Down (Compose) | Up / Down | Up / Down | 「Up」／「Down」 | Up / Down | Up / Down | `compose up` / `compose down`: command names, untranslated on buttons too (“Down…”); “take down” in a sentence names the action. |
| kill (SIGKILL) | 强制停止 | 強制結束 | 強制終了 | forcer l’arrêt | sofort beenden | As Force Quit. |
| exempt (from Memory Saver) | 豁免 | 排除 | 除外 | exclu | ausgenommen | |
| image tag | 标签 | 標記 | タグ | tag | Tag | zh-Hant keeps 標籤 for labels. |
| Created (state and date column) | 已创建 | 已建立 | 作成済み | Créé | Erstellt | One key for both uses. |
| dangling / untagged image | 悬空 / 无标签 | 懸空 / 無標記 | ダングリング / タグなし | orpheline / sans tag | verwaist / ohne Tag | |
| disk image (sparse) | 磁盘映像（稀疏） | 磁碟映像檔（稀疏） | ディスクイメージ（スパース） | image disque (fragmentée) | Festplattenimage (mitwachsend) | de: never bare “Image”, which is a container image. |
| file-system volume | 宗卷 | 宗卷 | ボリューム | volume | Volume | The disk, as in Disk Utility — not a container volume. |
| setup, Setup assistant | 设置、设置助理 | 初始設定、設定輔助程式 | セットアップ、設定アシスタント | configuration, Assistant de configuration | Einrichtung, Einrichtungsassistent | |

Per-language decisions beyond this table (Compose and YAML vocabulary, update and signing terms,
progress-line style, column abbreviations) are in [terms-zh-Hans.md](terms-zh-Hans.md),
[terms-zh-Hant.md](terms-zh-Hant.md), [terms-ja.md](terms-ja.md), [terms-fr.md](terms-fr.md) and
[terms-de.md](terms-de.md). Read the one for your language before translating new strings.
