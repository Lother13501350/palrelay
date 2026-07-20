# PalRelay

讓朋友群輪流當幻獸帕魯伺服器的 host:誰有空誰開,存檔自動透過 Google Drive 同步,
不用租 24 小時的雲端主機。設計細節見 [docs/DESIGN.md](docs/DESIGN.md)。

```
.\palrelay.ps1 start     # 取鎖 → 下載最新存檔 → 開伺服器 → 按 Q 關服 → 上傳 → 釋放鎖
.\palrelay.ps1 status    # 看誰在 host、最新存檔版本
.\palrelay.ps1 upload    # 手動上傳(當機復原 / 第一次播種存檔)
.\palrelay.ps1 takeover  # 清掉當機者留下的過期鎖
```

## 安裝(每位成員都要做一次)

### 0. 需求

- Windows 10/11(內建 PowerShell 5.1 即可)
- [rclone](https://rclone.org/downloads/)(單一 exe,放進 PATH 或記下路徑)
- Palworld Dedicated Server(Steam 工具區搜「Palworld Dedicated Server」安裝,
  或用 SteamCMD:`app_update 2394010`)
- (強烈建議)[Tailscale](https://tailscale.com/):全員裝好互加,連線就不用碰路由器設定

### 1. Google Drive 共用資料夾

**由一個人做**:在自己的雲端硬碟建立資料夾(例如 `PalRelay`),
右鍵分享給所有成員,權限選**編輯者**。

**每個人做**:打開資料夾,從網址列複製資料夾 ID
(`https://drive.google.com/drive/folders/`**`這一串就是ID`**),然後執行 `rclone config`:

```
n            # 新增 remote
name> gdrive
Storage> drive
client_id / client_secret> (直接 Enter)
scope> 1     # 完整存取
root_folder_id> (貼上剛剛複製的資料夾 ID)
Edit advanced config> n
Use web browser> y   # 瀏覽器登入自己的 Google 帳號授權
```

完成後驗證:`rclone lsd gdrive:` 不報錯即可。
因為 root_folder_id 直接指向共用資料夾,設定檔裡的 remote 填 `gdrive:` 就好。

### 2. 伺服器設定(REST API)

**不用手動改 ini**:`start` 時 PalRelay 會自動從 `DefaultPalWorldSettings.ini`
生成/修補 `PalWorldSettings.ini`,套用 config.json 裡的 `adminPassword` 與 REST 設定。
唯一要注意的是**全員的 config.json 要用同一組 adminPassword**。

> 防火牆只需對外開 UDP 8211(用 Tailscale 的話連這個都不用)。

### 3. PalRelay 設定

```powershell
.\palrelay.ps1 init      # 產生 config.json
notepad config.json      # 編輯
```

至少要改這三項:

```json
{
  "playerName": "lother",
  "remote": "gdrive:",
  "serverDir": "C:\\PalServer",
  "adminPassword": "跟 ini 裡一樣"
}
```

## 第一次啟用世界

- **全新世界**:隨便一人 `start`,伺服器會自動建立新世界,關服(按 Q)時自動上傳為 v1。
- **搬移既有 co-op 世界**:需要先做一次 host 角色修復與格式轉換
  (co-op 存檔的 host 角色卡在特殊槽位),用
  [PalworldSaveTools](https://github.com/deafdudecomputers/PalworldSaveTools) 或
  [Physgun 網頁轉換器](https://physgun.com/tools/palworld-save-converter/) 轉成
  dedicated server 存檔、放進 `PalServer\Pal\Saved\SaveGames\0\<世界資料夾>`,
  然後 `.\palrelay.ps1 upload` 播種。這是一次性的,之後不用再碰。

## 日常使用

1. 想玩的人在群組喊一聲,執行 `.\palrelay.ps1 start`
2. 其他人連 host 的 IP(Tailscale IP)+ 埠 8211
3. 收工時 host 在 PalRelay 視窗按 **Q**:自動存檔、關服、上傳、釋放鎖
4. 任何人隨時可用 `status` 看世界狀態

### 出事了怎麼辦

| 狀況 | 處理 |
|---|---|
| host 電腦當機 | 當機者之後執行 `start` 會提示先上傳本機存檔;等不及的人可在 20 分鐘後 `takeover`(會犧牲那場沒上傳的進度) |
| 關服後上傳失敗(網路問題) | 網路恢復後 `.\palrelay.ps1 upload` 重試;在此之前鎖會故意保留,別人開不了是正常保護 |
| `status` 顯示 STALE 鎖 | `.\palrelay.ps1 takeover` 清掉 |
| 存檔壞掉想回滾 | Drive 的 `saves/` 留有最近 10 版,把 `latest.json` 改指向舊 zip 即可(欄位照抄該 zip 的版本號與 sha256——sha256 可用 `Get-FileHash` 算) |

### 鐵則

- **永遠透過 PalRelay 開服**,不要自己雙擊 PalServer.exe(進度不會被版本管理)
- 同一時間只能一人 host——工具會用鎖擋,但開服前群組喊一聲是好習慣

## 開發

```powershell
.\test\run-tests.ps1     # 離線自動化測試(以 fake rclone 模擬 Drive)
```
