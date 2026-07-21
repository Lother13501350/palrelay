# PalRelay

[![tests](https://github.com/Lother13501350/palrelay/actions/workflows/test.yml/badge.svg)](https://github.com/Lother13501350/palrelay/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/Lother13501350/palrelay)](https://github.com/Lother13501350/palrelay/releases/latest)
[![license](https://img.shields.io/github/license/Lother13501350/palrelay)](LICENSE)
![platform](https://img.shields.io/badge/platform-Windows%2010%2B-informational)

**幻獸帕魯(Palworld)輪流開服工具** —— 讓朋友群共玩同一個世界:誰有空誰當主機,
存檔透過 Google Drive 自動同步,不需要租用 24 小時雲端伺服器。

> Rotating-host save sync for Palworld dedicated servers.
> No rented server: a shared Google Drive folder is the source of truth,
> an advisory lock prevents concurrent hosts, and saves are versioned zips.

```
你開服 → 遊玩 → 收工上傳 ☁ → 朋友接手開服 → 遊玩 → 收工上傳 ☁ → …
```

---

## 目錄

- [特色](#特色)
- [系統需求](#系統需求)
- [安裝](#安裝)
- [日常使用](#日常使用)
- [CLI 參考](#cli-參考)
- [匯入既有-co-op-世界](#匯入既有-co-op-世界)
- [疑難排解](#疑難排解)
- [運作原理](#運作原理)
- [開發](#開發)
- [授權與致謝](#授權與致謝)

## 特色

- **輪流開服**:advisory lock(nonce + 心跳)保證同一世界同時只有一位主機,存檔永不分岔
- **雲端同步**:存檔以版本化 zip 上傳 Google Drive,SHA-256 完整性驗證,自動保留歷史版本可回滾
- **多世界**:一個共用資料夾承載任意數量世界,GUI 一鍵切換與建立
- **零門檻**:安裝精靈自動處理 rclone、Google 授權、伺服器安裝;GUI 以 Windows 內建 WPF 實作,不需任何額外執行環境
- **匯入既有世界**:內建 co-op 存檔搬遷(支援 2026 夏季更新後的 PlM/Oodle 新格式),主機角色完整移轉
- **連線公告**:主機的 Tailscale 位址自動寫入鎖並顯示於所有成員的 GUI,一鍵複製

## 系統需求

| 項目 | 需求 |
|---|---|
| 作業系統 | Windows 10 / 11(內建 Windows PowerShell 5.1 即可) |
| 遊戲 | Steam 版 Palworld;Palworld Dedicated Server(免費,精靈可自動觸發安裝) |
| 雲端 | 每位成員一個 Google 帳號(免費 15 GB 額度綽綽有餘) |
| 同步引擎 | [rclone](https://rclone.org/)(精靈自動安裝) |
| 網路(建議) | [Tailscale](https://tailscale.com/):免連接埠轉發的固定位址;不使用則主機需自行設定路由器轉發 UDP 8211 |

## 安裝

### 成員(加入既有群組)

1. 於 [Releases](https://github.com/Lother13501350/palrelay/releases/latest) 下載最新 zip 並解壓縮
2. 雙擊 `setup.cmd`,選擇「**1 加入朋友的群組**」,貼上群主提供的共用資料夾連結,依精靈指示完成(約 3 分鐘)
3. 完成後以 **`PalRelay.exe`** 開啟主介面

### 群主(建立新群組)

1. 同上下載並執行 `setup.cmd`,改選「**2 建立全新群組**」——雲端資料夾自動建立
2. 精靈開啟瀏覽器後,將成員的 Google 帳號加為資料夾**編輯者**,並把精靈產生的連結(存於 `share-link.txt`)傳給成員
3. 伺服器管理密碼由精靈產生並存於雲端 `group.json`,成員自動沿用

**升級**:下載新版 zip 解壓覆蓋即可,`config.json` 與 `rclone.conf` 不受影響。

## 日常使用

1. 開啟 **`PalRelay.exe`** → 選擇世界 → 按「**開始當主機**」
   (原生應用,免安裝任何執行環境;舊的 `palrelay-gui.cmd` 為備用入口)
2. 介面顯示連線位址(一鍵複製),貼到群組;成員於遊戲「加入多人遊戲」最下方輸入位址連線
3. 收工按「**收工上傳**」:自動存檔、關閉伺服器、上傳雲端、釋放鎖

GUI 同時提供:世界狀態與**設定參數面板**(經驗/工作/孵蛋等倍率一目了然)、
版本與上傳者資訊、「匯入既有世界」精靈、「完成角色搬遷」、「修復地圖探索」、
開啟存檔資料夾等完整流程按鈕;首次執行未設定時會引導啟動安裝精靈。

> **鐵則**:永遠透過 PalRelay 啟動伺服器;直接執行 PalServer.exe 的進度不受版本管理。

## CLI 參考

GUI 底層即為 CLI,兩者行為一致:

```powershell
.\palrelay.ps1 <command> [world] [-Force]
```

| 指令 | 說明 |
|---|---|
| `start [world]` | 完整流程:取鎖 → 同步 → 開服 →(按 Q)關服 → 上傳 → 釋放鎖;新名稱即建立新世界 |
| `worlds` | 列出所有世界及狀態(鎖持有者、最新版本) |
| `status [world]` | 單一世界詳細狀態 |
| `upload [world]` | 手動上傳本機存檔(當機復原/首次播種) |
| `takeover [world]` | 清除過期鎖(對未過期鎖需 `-Force`) |
| `import` | 匯入本機 co-op 世界(見下節) |
| `fixhost [world]` | 匯入後的主機角色搬遷(含科技/圖鑑/外觀,自動驗證+回滾) |
| `fixmap [world]` | 還原被遊戲重置的客戶端地圖探索資料 |
| `init` | 由 `config.sample.json` 建立 `config.json` |

省略 `[world]` 時依序採用:上次使用的世界 → 雲端唯一世界 → `main`。

**Exit codes**:`0` 成功/`1` 一般錯誤/`2` 鎖被他人持有/`3` 設定錯誤/`5` 伺服器異常結束且未上傳。

完整設定欄位(`config.json`)說明見 [docs/DESIGN.md](docs/DESIGN.md#44-configjson本機每人一份不進版控)。

## 匯入既有 co-op 世界

將遊戲內建合作模式的世界搬遷為輪流開服世界(一次性,原存檔不受任何更動):

```powershell
.\palrelay.ps1 import        # 列出本機 co-op 世界(含名稱)→ 選擇 → 自動搬入伺服器並上傳
```

主機角色搬遷(僅原 co-op 主機需要;訪客玩家的角色自動延續,無須任何操作):

1. 開服一次(GUI 或 `start`)
2. 原主機連入伺服器,建立新角色後下線
3. 收工後執行 `.\palrelay.ps1 fixhost <世界名>`(或按 GUI 的「完成角色搬遷」)——
   等級、素質、背包、帕魯、**科技樹、任務、圖鑑、傳送點解鎖、外觀**全數自動移轉;
   完成時**自動驗證身分鏈**(玩家檔 → 角色條目 → 公會 → 容器),驗證不過會
   自動回滾所有變更並印出診斷,絕不留下半成品存檔

同時自動保留:**世界倍率設定**(從 WorldOption.sav 解出、存入雲端,之後**每一位
host 開服時自動套用**)與**地圖探索資料**(自動備份;若遊戲重置了你的地圖,
執行 `fixmap` 或按 GUI 的「修復地圖探索」即可還原)。

**已知一次性代價**:公會需由成員在遊戲內重新邀請一次(公會資料由遊戲自行維護,最為安全)。

技術限制:需要 `tools/palfix.exe`(Release 已附)與 libooz.dll(首次使用時經同意後
自 [zao/ooz](https://github.com/zao/ooz) 官方 release 下載並驗證 SHA-256,
因上游無授權條款故不隨包散佈)。

## 疑難排解

| 狀況 | 處理 |
|---|---|
| 成員連線逾時 | 依序確認:主機是否開服中(GUI 狀態)→ 成員是否已加入主機的 Tailscale 網路(`tailscale status` 需看得到主機)→ 未用 Tailscale 則確認路由器已轉發 UDP 8211 |
| 主機當機/斷電 | 主機重開 GUI 依提示補上傳;等不及者可於 20 分鐘後接管(該場未上傳進度遺失) |
| 收工上傳失敗 | 鎖會刻意保留(保護機制),排除網路問題後重按「收工上傳」或執行 `upload` |
| 顯示 STALE 鎖 | `takeover` 清除 |
| 回滾存檔 | 雲端 `worlds/<世界>/saves/` 保留最近 10 版,將 `latest.json` 改指舊 zip 即可 |

## 運作原理

```
(Google Drive 共用資料夾)
├── group.json                 群組共用設定
└── worlds/<世界名>/
    ├── lock.json              advisory lock(持有者、nonce、心跳、連線位址)
    ├── latest.json            最新版本指標(版本號、檔名、SHA-256)
    └── saves/world-vNNNN-*.zip
```

- 鎖協議、狀態機、失敗模式對策、競態分析:[docs/DESIGN.md](docs/DESIGN.md)
- 存檔搬遷採**保守模式**:僅解碼經驗證可正確重組的區塊,其餘結構位元組級直通,
  杜絕「寫入即損壞」;詳見設計文件 §12.5

## 開發

```powershell
.\test\run-tests.ps1        # 離線測試套件(fake-rclone 模擬雲端),49 項檢查
```

| 路徑 | 內容 |
|---|---|
| `palrelay.ps1` | 核心 CLI(純 PowerShell 5.1,ASCII;`-Json` 供前端呼叫) |
| `gui/` | 原生 GUI(C# WPF,.NET 9 自包含單檔;呼叫 CLI 的 session API,協議單一來源) |
| `palrelay-gui.ps1` | 舊版 PowerShell GUI(備用) |
| `setup.ps1` | 安裝精靈 |
| `tools/palfix.py` | 存檔搬遷引擎(CI 以 PyInstaller 打包為 exe) |
| `test/` | 測試套件與 fake-rclone |
| `.github/workflows/` | CI:測試(windows-latest)與 palfix 建置 |

已知待辦:rclone 內建 Google client_id 預計於 2026 年內退役,屆時需
[自建 client_id](https://rclone.org/drive/#making-your-own-client-id)。

## 授權與致謝

本專案以 [MIT License](LICENSE) 發佈。

站在巨人肩膀上:

- [palworld-save-tools](https://github.com/cheahjs/palworld-save-tools)(MIT)— GVAS 存檔解析
- [palworld-hostfix-toolkit](https://github.com/quadrantbs/palworld-hostfix-toolkit)(MIT)— PlM 格式支援與搬遷層修補
- [palworld-host-save-fix](https://github.com/xNul/palworld-host-save-fix)(MIT)— 經典主機角色搬遷思路
- [ooz](https://github.com/zao/ooz) — 開源 Oodle 解壓實作(使用時下載,不隨包散佈)
- [rclone](https://rclone.org/)(MIT)— 雲端同步引擎

**免責聲明**:本專案為社群工具,與 Pocketpair, Inc. 無任何關聯。
使用前請備份存檔;所有寫入操作皆自動建立備份,惟仍請自行承擔使用風險。
