# 自行建置 fika-spt-server-docker Image（SPT 4.1.1 / Fika 2.4.0）

## 背景

官方 Release 目前停留在 [4.0.13](https://github.com/zhliau/fika-spt-server-docker/releases/tag/4.0.13)，
升級到 SPT 4.1.1 / Fika 2.4.0 的 [PR #89](https://github.com/zhliau/fika-spt-server-docker/pull/89) 已經開好，
但**只改了版本號**（`Dockerfile`、`Dockerfile.multiarch`、`entrypoint.sh` 各自的 `SPT_VERSION`/`FIKA_VERSION`
預設值），實際建置測試後發現光改版本號是不夠的 —— SPT 4.1 系列在封裝格式上有幾個破壞性改動，PR #89
目前完全沒有處理，直接用會建置成功但**容器開機必掛**。以下記錄了診斷出的全部問題與修法。

## 發現的問題（PR #89 未涵蓋的部分）

### 1. SPT 4.1 release 壓縮檔內部目錄改名：`SPT` → `SPT_Runtime`

舊版（4.0.13）壓縮檔解開後，內容直接在頂層 `SPT/` 目錄下（`SPT/SPT_Data/...`、`SPT/SPT.Server.Linux`）。
4.1.1 的壓縮檔解開後變成頂層 `SPT_Runtime/` 目錄，且同層還多了 `BepInEx/`、`winhttp.dll`、
`doorstop_config.ini` 等一堆 Windows 用戶端 / BepInEx 檔案（這些是 client-side 檔案，Linux 專用 dedicated
server 完全用不到）。

Fika 2.4.0（`Fika-Server-CSharp`）的釋出 zip 內部路徑也同步改成 `SPT_Runtime/user/mods/fika-server/...`
（舊版是 `SPT/user/mods/fika-server/...`）。

`entrypoint.sh` 原本假設頂層目錄是 `SPT`，直接 `cp -r $build_dir/* $mounted_dir`，結果實際上把
`SPT_Runtime`、`BepInEx` 等全部原封不動複製到 `/opt/server/` 下，而不是預期的 `/opt/server/SPT/`，
導致 `/opt/server/SPT/SPT_Data/configs/http.json` 找不到而報錯，Fika 安裝時 `mv` 也找不到來源路徑。

**修法**：`entrypoint.sh` 的 `install_spt()`（含 `FORCE_SPT_VERSION` 分支）與 `install_fika_mod()`，
改成只抓 `SPT_Runtime/` 內容搬進 `$spt_dir`（即 `/opt/server/SPT/`），忽略其餘 client 端檔案。

### 2. SPT 4.1.1 binary 需要 .NET 10 runtime，但 Dockerfile 還是 .NET 9 base image

`SPT.Server.Linux` 這個 build 需要 `Microsoft.NETCore.App` 10.0.0，但 `Dockerfile` 仍是
`mcr.microsoft.com/dotnet/aspnet:9.0-bookworm-slim`，執行時直接報
`You must install or update .NET to run this application.`。

而且 .NET 10 的官方 runtime image 已經**不再提供 Debian（bookworm）變體**，改以 Ubuntu
(`noble`) 為主，也**不再有 `-slim` tag**（改成無套件管理器的 `-chiseled`，裝不了 `apt install` 的東西）。

**修法**：`Dockerfile` base image 改成 `mcr.microsoft.com/dotnet/aspnet:10.0-noble`（一般版，仍有 apt，
非 chiseled）。

### 3. Ubuntu 的 `7zip` 套件裝的執行檔叫 `7z`，不是 `7zz`

`Dockerfile`／`entrypoint.sh`／`scripts/download_unzip_install_mods.sh` 都寫死呼叫 `7zz`，這是 Debian
bookworm 上 `7zip` 套件（新版 7-Zip for Linux）的執行檔名稱。換到 Ubuntu noble 後，`7zip` 套件裝出來的執行檔
是 `7z`（以及 `7za`、`7zr`、`p7zip`），沒有 `7zz`，導致 `7zz x spt.7z` 直接 `command not found`。

**修法**：三處 `7zz` 全部改成 `7z`（命令列語法相容，`x`/`-o` 等參數行為一致）。

### 4. Fika 2.4.0 的版本比對機制整個失效（最隱蔽的一個）

`entrypoint.sh` 原本用一個很聰明的技巧檢查 Fika 是否需要更新：讀取已安裝的 `FikaServer.dll` 的
`ProductVersion`（格式假設是 `2.3.2+abcdef1`），用正規表示式 `[0-9.]+\+\K.*` 取出 `+` 後面的 git SHA，
拿去跟 GitHub API 查到的最新 release tag 的 commit SHA 比對。

但新版（C# 重寫版）`FikaServer.dll` 的 `ProductVersion` 已經**不再包含 SHA**，直接就是純版號字串
`2.4.0`。正規表示式抓不到 `+` 之後的內容，`grep -oP` 在「沒有匹配」時的結束碼是 `1`；因為這行是寫在
`fika_local_SHA=$(exiftool ... | grep -oP ...)` 這種指令替換賦值裡，配上 `entrypoint.sh` 開頭的
`#!/bin/bash -e`，只要這個賦值式子的結束碼非 0，整個 script 就會**靜默中止**，不會印出任何錯誤訊息 ——
容器 log 只會停在 `Validating SPT version` 這一行，然後就以結束碼 1 退出，非常難排查。

（這也是為什麼一開始用 `docker run --entrypoint bash ... -c "bash -x /usr/bin/entrypoint"` 手動測試會「成功」
—— 因為那種呼叫方式在某些情況下 mount 檢查/路徑判斷不同，直到後來用完全對應 `docker compose` 實際設定的
`docker compose run -e SHELLOPTS=xtrace fika-server` 才重現並定位到這個問題。）

**修法**：既然 `FikaServer.dll` 的 `ProductVersion` 現在就是乾淨的版號，直接跟 `$fika_version`
（例如 `2.4.0`）做字串比對即可，不再需要正則抓 SHA，也不需要另外呼叫 GitHub API 查 tag SHA
（移除了 `fika_remote_SHA=$(curl ... api.github.com ...)` 這行）。比對邏輯改成跟 SPT
版本比對（`existing_spt_version != "$spt_version"`）同樣的模式，較穩健也較好懂。

## 已驗證：實際跑起來了

用修好的 image 跑 `docker compose up -d`，容器持續運作（非 crash-loop），log 最終印出：

```
Server has started, happy playing
```

且 `https://localhost:6969/` 回應 `HTTP 200`。

## 前置需求

- Git
- Docker（Docker Desktop 或 Docker Engine，需要能跑 `docker build`）
- [GitHub CLI (`gh`)](https://cli.github.com/)（可選，方便直接 checkout PR，沒有的話用純 git 也行）

## 從零開始的完整步驟

這些修正已經 commit 並推到我自己的 fork：https://github.com/nekogravitycat/fika-spt-server-docker
（分支 `update-spt-4.1.1`），不動原作者 `zhliau/fika-spt-server-docker` 的 repo。

### 1. Clone 這個 fork 的分支

```bash
git clone -b update-spt-4.1.1 https://github.com/nekogravitycat/fika-spt-server-docker.git
cd fika-spt-server-docker
```

這個分支已經包含 PR #89 的版本號更新，加上下面列出的 4 項修正，不需要再手動套用。

### 2. 建置 Docker Image

```bash
VERSION=4.1.1 SPT_VERSION=4.1.1-40743-e18bd1e FIKA_VERSION=2.4.0 ./build
```

會建出本地 image `fika-spt-server-docker:4.1.1`（單一 amd64 架構，適合一般 x86/amd64 主機）。

> 如果需要 ARM64（樹莓派、Apple Silicon），要改用 `Dockerfile.multiarch`，該檔案同樣有上述 4 項問題
> （目前尚未同步修正，需要另外處理），並搭配 `docker buildx build --platform linux/amd64,linux/arm64
> -f Dockerfile.multiarch ...`。

### 3. 確認建置成功

```bash
docker images fika-spt-server-docker
```

### 4. 啟動伺服器

`docker-compose.yml` 已經指向本地建置的 image，不需要再手動改。

```bash
docker compose up -d
docker compose logs -f
```

看到 `Server has started, happy playing` 就代表成功了。

## 已完成的變更（目前狀態）

- 本地已建置並驗證可用的 image：`fika-spt-server-docker:4.1.1`
- `docker-compose.yml` 的 `image` 欄位已從 `ghcr.io/zhliau/fika-spt-server-docker:latest` 改成
  `fika-spt-server-docker:4.1.1`
- `Dockerfile`、`entrypoint.sh`、`scripts/download_unzip_install_mods.sh` 已套用上述 4 項修正
- 這些修改已 commit 並推到我自己的 fork（`nekogravitycat/fika-spt-server-docker` 的 `update-spt-4.1.1`
  分支），沒有動原作者 `zhliau/fika-spt-server-docker` 的 repo

## 之後官方 Release 出來後怎麼辦？

這次發現的 4 個問題都是上游 SPT/Fika 封裝格式改動造成的，**PR #89 本身即使被 merge 也還是壞的**，
但目前先不主動回報給 `zhliau/fika-spt-server-docker`，只在自己的 fork 上記錄修法備用。

等官方正式修好並發布 `4.1.1` release 後：

1. `git checkout master && git pull`（換回官方 repo/官方分支）
2. 把 `docker-compose.yml` 的 `image` 改回 `ghcr.io/zhliau/fika-spt-server-docker:4.1.1`（或 `latest`）
3. `docker compose pull && docker compose up -d`

也可以繼續沿用自建的 image，只要 SPT/Fika 版本沒有再變動，功能上是一致的。
