# PalRelay

![tests](https://github.com/Lother13501350/palrelay/actions/workflows/test.yml/badge.svg)

**帕魯輪流開服工具**:讓朋友群共玩同一個幻獸帕魯世界——誰有空誰當主機,存檔自動透過
Google Drive 同步,不用租 24 小時的雲端伺服器,支援多個世界。

```
你開服 → 玩 → 收工上傳 ☁️ → 朋友接手開服 → 玩 → 收工上傳 ☁️ → ...
```

---

## 👥 給朋友:三步驟加入

> 你需要:Windows 10/11、Steam(擁有幻獸帕魯)、一個 Google 帳號,
> 以及群主傳給你的**共用資料夾連結**。

1. **下載**:到 [Releases](https://github.com/Lother13501350/palrelay/releases)
   下載最新的 zip,解壓縮到任何地方(例如桌面)
2. **設定**:雙擊 **`setup.cmd`**,跟著精靈走(約 3 分鐘,會自動裝好所有需要的東西)
3. **玩**:雙擊 **`palrelay-gui.cmd`** → 選世界 → 按「**開始當主機**」;
   收工時按「**收工上傳**」就好

**怎麼連朋友開的服?** 開啟幻獸帕魯 → 開始遊戲 → 加入多人遊戲 →
最下面的 IP 欄位貼上主機貼在群組的連線位址(GUI 會顯示,一鍵複製)。

**建議全員安裝 [Tailscale](https://tailscale.com/download)** 並互加好友:
裝了之後連線位址固定、不用動路由器設定;沒裝的話 host 需要自己處理
連接埠轉發(UDP 8211)。

---

## 👑 給群主:建立群組

跟朋友一樣的三步驟,只差一個選項:

1. 下載 Release zip、解壓、雙擊 `setup.cmd`
2. 精靈問「加入朋友的群組還是建立全新群組?」時選 **2(建立全新群組)**——
   雲端資料夾會**自動建立**,精靈接著開啟瀏覽器,你只要按「共用」把朋友的
   Google 帳號加為**編輯者**,再把精靈給你的連結傳到群組(也存在 `share-link.txt`)
3. 開玩!GUI 按「+ 新世界」可以開任意多個世界,同一個資料夾全部搞定;
   伺服器管理密碼由精靈自動產生並存在雲端,成員完全不用碰

### 搬移現有的 co-op 世界(內建匯入!)

想把你們**原本在遊戲裡玩的世界**搬進來?一條指令 + 一次登入:

```powershell
.\palrelay.ps1 import      # 列出你電腦裡所有 co-op 世界(含世界名),選一個 → 自動搬進伺服器並上傳雲端
```

之後做一次性的主機角色搬遷(co-op 的主機角色卡在特殊槽位):

1. 開服一次(GUI 或 `start`)
2. **原本當主機的人**連進伺服器,建立一個新角色,然後下線
3. 收工(Q)後執行 `.\palrelay.ps1 fixhost <世界名>` —— 舊角色的一切
   (等級、背包、帕魯、公會)會自動搬到新角色上並上傳

當初的訪客玩家不用做任何事,角色自動延續。原本的 co-op 存檔完全不會被動到。
匯入需要 `tools\palfix.exe`(Release zip 已附)與 libooz.dll
(首次使用時會徵求同意後從 [zao/ooz](https://github.com/zao/ooz) 官方 release 下載,
新版 PlM 存檔格式的開源解壓器)。

---

## ⌨️ CLI(進階使用者)

```
.\palrelay.ps1 <command> [world] [-Force]
```

| 指令 | 功能 |
|---|---|
| `start [world]` | 完整流程:取鎖 → 同步 → 開服 →(按 Q)關服 → 上傳 → 釋放鎖。用新名字即建立新世界 |
| `worlds` | 列出所有世界與狀態(誰在開、最新版本) |
| `status [world]` | 單一世界的詳細狀態 |
| `upload [world]` | 手動上傳(當機復原 / 首次播種) |
| `takeover [world]` | 清除當機者留下的過期鎖 |
| `init` | 從範本建立 config.json |

省略 `[world]` 時使用上次玩的世界。Exit codes:`0` 成功 / `2` 鎖被持有 /
`3` 設定錯誤 / `5` 伺服器異常且未上傳。

### 出事了怎麼辦

| 狀況 | 處理 |
|---|---|
| host 電腦當機 | 當機者重開 GUI 會提示補上傳;等不及的人 20 分鐘後可在 GUI 接管(該場未上傳進度會遺失) |
| 上傳失敗(網路問題) | 鎖會刻意保留(別人開不了是保護);修好後再按一次「收工上傳」或 CLI `upload` |
| 存檔壞掉想回滾 | 雲端 `worlds/<世界>/saves/` 留有最近 10 版,把 `latest.json` 改指向舊 zip 即可 |

### 鐵則

- **永遠透過 PalRelay 開服**,不要自己雙擊 PalServer.exe
- 同一個世界同一時間只能一人 host(工具會擋,但開服前群組喊一聲是好習慣)

---

## 🛠 開發者

```powershell
.\test\run-tests.ps1     # 離線測試套件(fake-rclone 模擬雲端),41 項檢查
```

- 設計文件與協議規格:[docs/DESIGN.md](docs/DESIGN.md)
- 純 PowerShell 5.1(Windows 內建),唯一外部相依是 [rclone](https://rclone.org/)
- GUI 是 WPF,dot-source 重用核心邏輯;`PALRELAY_GUI_TEST=1` 可無頭測試
- 已知待辦:rclone 內建 Google client_id 將於 2026 退役,屆時需
  [自建 client_id](https://rclone.org/drive/#making-your-own-client-id)
