# xts-vm-preflight

xTS Insight 部署到內網 VM 前的環境檢查。唯讀：不安裝、不改設定、不需 sudo。

```bash
git clone https://github.com/seen0722/xts-vm-preflight.git
cd xts-vm-preflight
bash xts-vm-preflight.sh
# 選填：REDMINE_URL=https://... GITILES_URL=https://... bash xts-vm-preflight.sh
```

結果同時寫到 `./xts-preflight-<hostname>-<時間>.txt`（proxy 帳密已遮罩）。
