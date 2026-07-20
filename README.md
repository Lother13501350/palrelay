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

1. 在自己的 [Google Drive](https://drive.google.com) 建一個資料夾(名字隨意)→
   右鍵「共用」→ 加入所有成員(權限選**編輯者**)→ 把資料夾連結傳到群組
2. 自己也跑一次 `setup.cmd`——第一個完成設定的人自動成為群主,
   精靈會幫群組產生伺服器管理密碼(存在共用資料夾的 `group.json`,成員自動沿用)
3. 開玩!GUI 按「+ 新世界」可以開任意多個世界,同一個資料夾全部搞定

### 搬移現有的 co-op 世界

co-op 存檔的主機角色卡在特殊槽位,需要一次性轉換:用
[PalworldSaveTools](https://github.com/deafdudecomputers/PalworldSaveTools) 或
[Physgun 網頁轉換器](https://physgun.com/tools/palworld-save-converter/)
轉成 dedicated server 存檔,放進
`PalServer\Pal\Saved\SaveGames\0\<世界資料夾>`,然後
`.\palrelay.ps1 upload <世界名>` 播種。之後就不用再碰了。

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
