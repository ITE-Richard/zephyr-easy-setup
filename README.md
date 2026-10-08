# Zephyr RTOS One-Click Automated Setup for Windows

一個適用於 Windows 10 / 11 的 Zephyr RTOS 一鍵全自動化安裝與開發環境配置腳本。

本工具能自動透過 Windows 套件管理器（`winget`）安裝所有主機端工具依賴、建立隔離的 Python 虛擬環境、初始化 Zephyr 工作區與相依倉庫、下載對應架構的 Zephyr SDK 工具鏈，並編譯驗證範例專案。

預設針對 **ITE IT51xxx 系列（RISC-V EC，如 `it51xxx_evb` / `it51526aw`）** 提供開箱即用的完整支援，同時支援自訂目標板卡與架構。

---

## 📑 目錄

- [特色功能](#特色功能)
- [系統需求](#系統需求)
- [快速開始](#快速開始)
- [日常開發流程（推薦）](#日常開發流程推薦)
- [自訂板卡與工具鏈參數](#自訂板卡與工具鏈參數)
- [離線打包與跨電腦快速遷移（Air-gapped / Offline）](#離線打包與跨電腦快速遷移air-gapped--offline)
- [專案目錄結構](#專案目錄結構)
- [乾淨卸載](#乾淨卸載)
- [常見問題與排查（Troubleshooting）](#常見問題與排查troubleshooting)


---

## ✨ 特色功能

1. **一鍵全自動配置**：從無到有全自動完成，包含 CMake、Ninja、Git、Python 3.12、7-Zip、Devicetree Compiler (dtc)、gperf 等。
2. **無污染環境隔離**：Zephyr 與 west Python 套件皆安裝於獨立的 `.venv` 虛擬環境中，不污染全域 Python。
3. **自動註冊與持久化**：自動配置 Windows 使用者 PATH、啟用 Git Long Paths、註冊 Zephyr SDK 至 CMake 套件清單，並持久化 `ZEPHYR_SDK_INSTALL_DIR`。
4. **內建日常開發啟動器**：附帶 `zephyr-env.cmd`，雙擊即可開啟已配置好環境的開發終端機。
5. **安全與模組化**：預設編譯並驗證 Blinky 範例，確保安裝完成即可直接產生韌體映像檔（`zephyr.bin`）。

---

## 💻 系統需求

* **作業系統**：Windows 10 (1809 以上) 或 Windows 11 (64-bit)。
* **Windows 應用程式安裝程式（Winget）**：
  * Windows 11 通常已內建。
  * 若無 `winget`，請至 Microsoft Store 安裝 [應用程式安裝程式 (App Installer)](https://aka.ms/getwinget)。
* **網路連線**：安裝期間需下載約 1~2 GB 的相依工具、Git 倉庫與 SDK。

---

## 🚀 快速開始

### 1. 複製專案
```bash
git clone https://github.com/ITE-Richard/zephyr-easy-setup.git
cd zephyr-easy-setup
```

### 2. 執行一鍵安裝腳本
直接**雙擊執行** `zephyr-easy-setup.bat`，或在命令提示字元中執行：

```cmd
zephyr-easy-setup.bat
```

腳本將會自動依序執行以下 10 個步驟：
1. **[Step 1/10]** 檢測 `winget` 套件管理器。
2. **[Step 2/10]** 透過 winget 安裝 CMake, Ninja, Python 3.12, Git, 7-Zip, gperf, dtc。
3. **[Step 3/10]** 整理並持久化系統與使用者 PATH，啟用 Git 長路徑支援（`core.longpaths`）。
4. **[Step 4/10]** 檢測並綁定 Python 3.12 執行檔。
5. **[Step 5/10]** 建立 `zephyrproject\.venv` 虛擬環境並安裝 `west`。
6. **[Step 6/10]** 初始化 Zephyr 工作區並同步程式碼（`west update`）。
7. **[Step 7/10]** 安裝 Zephyr Python 依賴並執行 `west zephyr-export`。
8. **[Step 8/10]** 安裝 Zephyr SDK 工具鏈（預設 `riscv64-zephyr-elf`）並向 CMake 註冊。
9. **[Step 9/10]** 建立 `zephyrproject\app\blinky` 專案目錄。
10. **[Step 10/10]** 編譯 Blinky 韌體，成功產出 `build\zephyr\zephyr.bin`。

---

## 🛠 日常開發流程（推薦）

安裝完成後，日常進行專案開發時**不需要重新執行 setup 腳本**：

1. **直接雙擊執行 `zephyr-env.cmd`**：
   此腳本會自動為您啟動終端機、載入 Python 虛擬環境、設定 SDK 變數並切換至 `zephyrproject\`。

2. **常用編譯指令**：
   ```cmd
   :: 切換至應用程式目錄
   cd app\blinky

   :: 一般編譯
   west build -p always -b it51xxx_evb

   :: 若使用限定 Qualifier 目標
   west build -p always -b it51xxx_evb/it51526aw

   :: 清理編譯快取
   west build -t clean
   ```

---

## ⚙️ 自訂板卡與工具鏈參數

`zephyr-easy-setup.bat` 支援透過命令列傳入自訂參數：

### 參數格式
```cmd
zephyr-easy-setup.bat [BOARD] [BOARD_QUALIFIER] [SDK_TOOLCHAIN] [ZEPHYR_REVISION]
```

### 範例

* **預設行為（ITE IT51xxx 系列）**：
  ```cmd
  zephyr-easy-setup.bat it51xxx_evb it51xxx_evb/it51526aw riscv64-zephyr-elf
  ```

* **配置給 ARM 架構板卡（例如 STM32F4 Discovery）**：
  ```cmd
  zephyr-easy-setup.bat stm32f4_disco "" arm-zephyr-eabi
  ```

* **指定 Zephyr 穩定發行版本（如 v3.7.0）**：
  ```cmd
  zephyr-easy-setup.bat it51xxx_evb it51xxx_evb/it51526aw riscv64-zephyr-elf v3.7.0
  ```

---

## 📦 離線打包與跨電腦快速遷移（Air-gapped / Offline）

若需要將已安裝好的環境搬移到**無外網連線（隔離網段/無聯網機台）**或其他開發電腦，無需重新下載數 GB 的檔案，可使用專案提供的離線打包工具：

### 1. 在原電腦（電腦 A）進行打包
在已執行過 `zephyr-easy-setup.bat` 且安裝完成的電腦上，直接執行：
```cmd
zephyr-pack-offline.bat
```
腳本將會自動：
1. 緩存所有 Python 離線 Wheels 套件（`west` 與所有 Zephyr requirements）。
2. 下載所有主機工具離線安裝檔（CMake, Python 3.12, Git, 7-Zip, Ninja, dtc, gperf）。
3. 自動清理中間編譯快取（`build/`）以大幅降低壓縮檔大小。
4. 將所有內容、原始碼倉庫與已安裝的 Zephyr SDK 打包成 **`zephyr-offline-bundle.zip`**。

### 2. 複製至目標電腦（電腦 B）進行解壓縮與安裝
1. 將產生的 `zephyr-offline-bundle.zip` 複製到目標電腦。
2. 解壓縮至**不含空格**的路徑（例如 `D:\zephyr`）。
3. 進入解壓縮目錄，**雙擊執行**：
   ```cmd
   zephyr-offline-install.bat
   ```
4. 腳本將在 **100% 離線環境** 下自動：
   * 安裝或辨識本機工具（Python, Git, CMake, 7-Zip, Ninja, dtc, gperf）。
   * 配置系統與使用者環境變數。
   * 從離線 wheels 建立乾淨的 `.venv` 虛擬環境。
   * 向 CMake 註冊 Zephyr SDK。
   * 編譯 Blinky 範例進行全功能驗證！

---

## 📁 專案目錄結構

```text
zephyr-easy-setup/
├── zephyr-easy-setup.bat     # 一鍵線上全自動安裝與環境建置腳本
├── zephyr-pack-offline.bat   # 離線打包工具（打包目前已裝好之所有工具、代碼與 SDK）
├── zephyr-offline-install.bat# 離線安裝腳本（在目標電腦雙擊即可完全離線復原環境）
├── zephyr-env.cmd            # 日常開發終端機啟動器（雙擊進入開發環境）
├── zephyr-uninstall.bat      # 卸載與清理腳本（安全保留 app 目錄）
├── README.md                 # 專案說明文件
├── installers/               # [打包產出] 離線安裝檔與 Python Wheels（已被 git 忽略）
└── zephyrproject/            # 自動產生之 Zephyr 工作區（已被 .gitignore 忽略）
    ├── .venv/                # Python 虛擬環境
    ├── .west/                # West 專案配置
    ├── zephyr/               # Zephyr RTOS 核心原始碼
    ├── zephyr-sdk-<version>/ # Zephyr SDK 與編譯工具鏈
    └── app/                  # 使用者應用程式目錄（建議程式碼放置於此）
        └── blinky/           # 範例測試專案
```

---

## 🗑 乾淨卸載

若需要清理本專案或重新安裝：

* 執行 `zephyr-uninstall.bat`。
* 此腳本會將 `zephyrproject\app\` 應用程式程式碼備份保留，清理其餘 Zephyr 源碼、虛擬環境與 CMake 註冊表。

---

## ❓ 常見問題與排查（Troubleshooting）

### Q1: `winget` 提示找不到命令？
* 請確認 Windows 已啟用「應用程式安裝程式」。
* 可手動將 `%LocalAppData%\Microsoft\WindowsApps` 加入使用者環境變數 `PATH`。

### Q2: 出現路徑過長（Filename too long / Path too long）錯誤？
* 腳本已預先配置 `git config --global core.longpaths true`。
* 建議在 Windows 系統中啟用長路徑支援：
  1. 按 `Win + R` 輸入 `regedit`。
  2. 瀏覽至 `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem`。
  3. 將 `LongPathsEnabled` 設為 `1`。

### Q3: 重開終端機後 `west build` 報錯找不到工具鏈？
* 請使用專案隨附的 `zephyr-env.cmd` 啟動終端機。
* 若使用 VS Code，請確認 VS Code 的終端機已重啟，或在環境變數中確認 `ZEPHYR_SDK_INSTALL_DIR` 與 `ZEPHYR_TOOLCHAIN_VARIANT=zephyr` 已生效。

