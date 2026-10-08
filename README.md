# Zephyr RTOS One-Click Setup for Windows

此專案提供 Windows 上的一鍵線上安裝、既有環境離線打包、離線安裝與確認後卸載。預設板卡為 `it51xxx_evb`，失敗時嘗試 `it51xxx_evb/it51526aw`，工具鏈為 `riscv64-zephyr-elf`。

所有 `.bat` 入口共用 `scripts/zephyr-manager.ps1`，必要步驟失敗時回傳 exit code 1；只有安裝及 Blinky 編譯都成功，才會顯示安裝完成。

## 系統需求

- Windows 10 / 11 **x64**，64 位元 Windows PowerShell 5.1。
- 專案、來源工作區與解壓縮路徑不含空白，例如 `D:\zephyr-easy-setup`。
- 使用 **Python 3.12 x64**；離線 wheels 固定給相同 Python 次版本與平台使用。
- 線上安裝與首次補齊離線安裝檔需要網路及支援 `winget download` 的 WinGet。
- 需有容納來源、wheels、SDK、暫存副本及 ZIP 的磁碟空間，通常為數 GB 以上。
- CMake、Git、7-Zip 安裝可能需要系統管理員權限；在乾淨目標電腦上可從系統管理員命令提示字元執行安裝。移除使用者環境設定時，請使用原安裝者的帳號。

## 一鍵線上安裝

```cmd
git clone https://github.com/ITE-Richard/zephyr-easy-setup.git
cd zephyr-easy-setup
zephyr-easy-setup.bat
```

安裝流程：安裝並檢查 Python、Git、CMake、7-Zip、Ninja、dtc、gperf；整理主機工具 PATH；啟用 Git 長路徑；建立 `zephyrproject\.venv`；安裝 west；執行 `west init`、`west update`；安裝 Zephyr 與模組 Python 依賴；下載指定 SDK 工具鏈；註冊 CMake；建立並編譯 `app\blinky`。

SDK 使用 `west sdk install -b <workspace> -t <toolchain>`，安裝到 `zephyr-sdk-<version>` 子目錄。若 west 重用其他位置的既有 SDK，腳本會尋找並記錄該 SDK；卸載時只清理本專案內的 SDK。

主機工具目錄會補入使用者 PATH。SDK 與 `.venv` 由開發終端機載入，避免新終端機誤用另一個工作區的工具鏈。

### 自訂板卡、工具鏈與版本

```cmd
zephyr-easy-setup.bat [BOARD] [BOARD_QUALIFIER] [SDK_TOOLCHAIN] [ZEPHYR_REVISION]

zephyr-easy-setup.bat stm32f4_disco "" arm-zephyr-eabi
zephyr-easy-setup.bat it51xxx_evb it51xxx_evb/it51526aw riscv64-zephyr-elf v4.1.0
```

自訂 BOARD 而未提供 QUALIFIER 時，不會套用 ITE 的 qualifier。板卡、qualifier 與工具鏈保存在 `.zephyr-setup.json`，供後續離線打包及安裝使用。REVISION 只用於建立新工作區；既有工作區不會自動切換版本。

自動 SDK 安裝需要所選 Zephyr 提供 `west sdk`。對於沒有該指令的舊版本，先準備相容的 SDK，再使用共用 PowerShell 入口指定它：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\zephyr-manager.ps1 -Mode Online -Revision v3.7.0 -SdkPath D:\sdk\zephyr-sdk-0.16.8
```

Blinky 需要板卡支援其 GPIO / LED 配置；不支援的板卡會回報驗證失敗。

## 日常開發

雙擊 `zephyr-env.cmd`，它會讀取本工作區設定、載入 `.venv` 和 SDK，並開啟 cmd 終端機。常用指令：

```cmd
cd app\blinky
west build -p always -b it51xxx_evb/it51526aw
west build -t clean
```

## 打包目前已下載的環境

安裝完成後執行：

```cmd
zephyr-pack-offline.bat
```

也可以直接從其他既有工作區打包，不必重新下載 Zephyr 程式碼或 SDK：

```cmd
zephyr-pack-offline.bat -SourceWorkspace D:\existing\zephyrproject -SdkPath D:\sdk\zephyr-sdk-0.17.0
```

來源必須包含完整 west 工作區（`.west`、Zephyr 與啟用的模組 Git 倉庫）、Python 3.12 x64 的 `.venv`，以及已解壓縮且包含目標 GCC 的 SDK。SDK 不在工作區內或有多個候選版本時，可用 `-SdkPath` 明確指定。來源沒有設定檔時使用 ITE 預設值；其他板卡請加上 `-Board`、`-Qualifier`、`-Toolchain`。

打包會：

1. 讀取來源 `.venv` 的 `pip freeze --all`，固定目前實際套件版本，下載可直接安裝的 wheels。
2. 重用 `installers\tools\<package-id>` 中的安裝檔；缺少時透過 WinGet 下載 x64 EXE、MSI 或 ZIP。
3. 在乾淨的暫存 `.venv` 使用 `--no-index` 安裝全部固定版本、執行 `pip check`，並驗證 Zephyr / 模組 requirements。
4. 複製程式碼、`.west`、`.git`、SDK、安裝檔及安裝／卸載腳本到暫存目錄。只在副本排除來源 `.venv` 與 `app\blinky\build`，保留其他檔案與來源編譯結果。
5. 建立逐檔 SHA-256 的 `bundle-manifest.json`，使用 7-Zip 壓縮並測試 ZIP。成功後才替換 `zephyr-offline-bundle.zip`。

**已安裝的工具不等於仍保留安裝檔。** 若原電腦沒有 Python、Git 等離線安裝程式或缺少 wheels，首次打包需連網補齊。已有完整快取時可以強制只使用本地內容：

```cmd
zephyr-pack-offline.bat -CacheOnly
```

快取的目錄格式如下，每個工具目錄應只有一個符合副檔名的安裝檔（WinGet 產生的 YAML 可以保留）：

```text
installers/
  requirements-frozen.txt
  wheels/*.whl
  tools/Python.Python.3.12/*.exe
  tools/Git.Git/*.exe
  tools/Kitware.CMake/*.msi
  tools/7zip.7zip/*.exe
  tools/Ninja-build.Ninja/*.zip
  tools/oss-winget.gperf/*.zip
  tools/oss-winget.dtc/*.zip
```

wheel 不可取得、SDK / 模組不完整、local / editable Python dependency、外部 Git objects、Git worktree 或 junction / symlink 都會中止打包，避免產生無法搬移的套件。來源內含使用者 app 與 Git 歷史，請依實際需求分享 ZIP。

## 完全離線安裝

將 `zephyr-offline-bundle.zip` 完整解壓縮到目標電腦，例如 `D:\zephyr`，執行：

```cmd
zephyr-offline-install.bat
```

安裝前會檢查 manifest、SHA-256 與必要檔案，接著安裝或辨識主機工具、解壓縮 portable tools、建立新的 `.venv`、從固定版本 wheels 安裝 Python 套件、註冊 Zephyr / SDK 並編譯 Blinky。此流程不執行 `winget install`、`west update` 或 `west sdk install`，pip 使用 `--isolated --no-index`。

可先只檢查離線包：

```cmd
zephyr-offline-install.bat -CheckOnly
```

可用 `-Board`、`-Qualifier`、`-Toolchain` 覆寫目標；SDK 必須已包含對應工具鏈。安裝程式若要求重新啟動，腳本會停止，重啟後再執行。卸載後要重新離線安裝時，請重新解壓縮完整 ZIP。

## 確認後卸載

```cmd
zephyr-uninstall.bat
```

開始移除前會詢問：

```text
Remove this Zephyr installation? (y/N):
Also uninstall shared Python, Git, CMake, Ninja, dtc, gperf and 7-Zip? (y/N):
```

第一題只有 `y`（不分大小寫）會繼續；直接 Enter、N 或其他輸入都取消且不變更檔案。第二題預設保留共用工具；選 y 時使用 WinGet 移除列出的工具，可能影響其他開發專案，且需要目標電腦有可用的 WinGet。

卸載會保留 `zephyrproject\app` 原位，移除本專案 `zephyrproject` 下的其餘內容及本地 portable tools，只清理指向本工作區的使用者環境設定與 CMake 登錄。遇到 junction / symlink 會在刪除前停止。`installers`、離線 ZIP、其他位置的工作區與 SDK 都保留。卸載失敗會回傳 exit code 1，不會顯示完整成功。

## 專案結構

```text
zephyr-easy-setup/
  zephyr-easy-setup.bat       線上安裝
  zephyr-pack-offline.bat     打包來源工作區
  zephyr-offline-install.bat  離線安裝
  zephyr-uninstall.bat        確認後卸載
  zephyr-env.cmd              開發終端機
  scripts/zephyr-manager.ps1  共用流程與錯誤檢查
  tests/verify-workflows.ps1  隔離驗證
  installers/                離線安裝快取（Git 忽略）
  offline_bundle/            打包暫存（Git 忽略）
  tools/                     portable tools（Git 忽略）
  zephyrproject/             工作區（Git 忽略）
```

## 驗證

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-workflows.ps1
```

測試使用專案內的暫存資料，涵蓋取消卸載、保留 app、限制刪除範圍、拒絕 junction、保留隱藏 metadata、SHA-256 / 安裝檔檢查及批次檔錯誤碼。測試不安裝／移除系統工具，也不寫入使用者登錄。

完整驗收還需要：在線上機器完成安裝及編譯、產生 ZIP，再於沒有相關工具且斷網的 Windows x64 機器解壓縮安裝與編譯。隔離測試通過不代表上述完整驗收已完成。

自動化執行時，可設定 `ZEPHYR_NO_PAUSE=1` 省略批次檔最後的 pause；卸載的 y/N 確認仍會保留。

參考：[Zephyr Getting Started](https://docs.zephyrproject.org/latest/develop/getting_started/)、[WinGet download](https://learn.microsoft.com/windows/package-manager/winget/download)、[SDK 安裝參數定義](https://github.com/zephyrproject-rtos/zephyr/blob/main/scripts/west_commands/sdk.py)。
