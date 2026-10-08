# Zephyr RTOS One-Click Setup for Windows

此專案提供 Windows 上的一鍵線上安裝、既有環境離線打包、離線安裝與確認後卸載。預設板卡為 `it51xxx_evb`，失敗時嘗試 `it51xxx_evb/it51526aw`，工具鏈為 `riscv64-zephyr-elf`。

所有 `.bat` 入口共用 `scripts/zephyr-manager.ps1`，必要步驟失敗時回傳 exit code 1；只有安裝及 Blinky 編譯都成功，才會顯示安裝完成。

## 系統需求

- Windows 10 / 11 **x64**，64 位元 Windows PowerShell 5.1。
- 專案、來源工作區與解壓縮路徑不含空白，例如 `D:\zephyr-easy-setup`。
- 使用 **Python 3.12 x64**；離線 wheels 固定給相同 Python 次版本與平台使用。
- 線上安裝與首次補齊離線安裝檔需要網路及支援 `winget download` 的 WinGet。
- 打包端需有可執行的 `7z.exe`；安裝檔、來源虛擬環境與 SDK 也會在打包前檢查。
- 需有容納來源、wheels、SDK、暫存副本及 ZIP 的磁碟空間，通常為數 GB 以上。
- CMake、Git、7-Zip 安裝可能需要系統管理員權限；在乾淨目標電腦上可從系統管理員命令提示字元執行安裝。移除使用者環境設定時，請使用原安裝者的帳號。

## 一鍵線上安裝

```cmd
git clone https://github.com/ITE-Richard/zephyr-easy-setup.git
cd zephyr-easy-setup
zephyr-easy-setup.bat
```

請保留完整專案資料夾，入口需要同一資料夾下的 `scripts\zephyr-manager.ps1`。使用 Release ZIP 時，先完整解壓縮再執行；缺少共用腳本時會顯示路徑與錯誤，不會自動下載補齊。

啟動後會先詢問安裝根目錄，按 Enter 使用安裝腳本所在的專案資料夾。例如輸入 `D:\zephyr`，Zephyr 工作區會建立在 `D:\zephyr\zephyrproject`。也可以直接指定目錄，略過這個詢問：

```cmd
zephyr-easy-setup.bat -InstallDir D:\zephyr
zephyr-easy-setup.bat -InstallDir D:\
```

在目前 checkout 的 PowerShell 中執行：

```powershell
Set-Location D:\github\zephyr-easy-setup
.\zephyr-easy-setup.bat -InstallDir D:\zephyr
.\zephyr-easy-setup.bat -InstallDir D:\
```

選擇其他安裝根目錄時，腳本會將安裝、打包、卸載、開發終端機入口、共用腳本、README 與測試複製到該目錄，供之後使用。請從選定目錄執行 `zephyr-env.cmd`、`zephyr-pack-offline.bat` 或 `zephyr-uninstall.bat`，才能操作該安裝。現有 `zephyrproject\app` 會保留。

安裝根目錄可以是 `D:\zephyr` 等資料夾，也可以直接是磁碟根目錄 `D:\`。例如 `-InstallDir D:\` 的工作區就是 `D:\zephyrproject`；`-InstallDir D:\zephyr` 的工作區則是 `D:\zephyr\zephyrproject`。路徑不能包含空白或 junction / symlink。

安裝流程：安裝並檢查 Python、Git、CMake、7-Zip、Ninja、dtc、gperf；整理主機工具 PATH；啟用 Git 長路徑；建立 `zephyrproject\.venv`；安裝 west；執行 `west init`、`west update`；安裝 Zephyr 與模組 Python 依賴；下載指定 SDK 工具鏈；註冊 CMake；建立並編譯 `app\blinky`。

執行期間會將終端機與外部程式管線設為 UTF-8，處理 WinGet 中文輸出的亂碼；結束時恢復原本的終端機編碼。

SDK 使用 `west sdk install -b <workspace> -t <toolchain>`，安裝到 `zephyr-sdk-<version>` 子目錄。若 west 重用其他位置的既有 SDK，腳本會尋找並記錄該 SDK；卸載時只清理本專案內的 SDK。

主機工具目錄會補入使用者 PATH。SDK 與 `.venv` 由開發終端機載入，避免新終端機誤用另一個工作區的工具鏈。

### 安裝位置

工作區固定在所選安裝根目錄的 `zephyrproject` 子目錄。未指定 `-InstallDir` 時先顯示目錄詢問；按 Enter 的預設值為安裝腳本所在的專案目錄，不隨啟動命令時的工作目錄改變。目前 checkout 的預設工作區是 `D:\github\zephyr-easy-setup\zephyrproject`；若選擇 `D:\zephyr`，配置如下：

```text
D:\zephyr\zephyrproject\
  zephyr\                    Zephyr 原始碼
  modules\                   west manifest 指定的相依模組
  .west\                     west 工作區設定
  .venv\                     Python 套件與 west
  zephyr-sdk-<version>\       新下載的 SDK 與目標工具鏈
  .zephyr-setup.json          板卡、qualifier、工具鏈與 SDK 位置
  app\blinky\                範例程式
  app\blinky\build\zephyr\   範例編譯輸出
```

相依倉庫的實際子目錄由所選 Zephyr 的 west manifest 決定。搬移完整安裝資料夾後，從其中的入口執行時，工作區會跟隨該資料夾位置。重用的外部 SDK 保留在原位置；設定檔的 `SdkDirectory` 對本工作區 SDK 使用相對路徑，對外部 SDK 使用絕對路徑。

Python、Git、CMake、7-Zip 等主機工具由 WinGet 安裝到各自的 Windows 安裝目錄，實際位置依套件與安裝範圍而定。離線安裝時，Ninja、dtc、gperf 則解壓縮到本專案的 `tools\<工具名稱>`，其可執行檔目錄會加入 PATH。

選擇磁碟根目錄時，例如 `-InstallDir D:\`，入口與共用腳本會複製到 `D:\`，工作區位於 `D:\zephyrproject`，安裝快取位於 `D:\installers`。此配置的離線 portable tools 放在 `D:\zephyrproject\.host-tools`，卸載只清理該工作區，不移除其他用途的 `D:\tools`。

### 自訂板卡、工具鏈與版本

```cmd
zephyr-easy-setup.bat [BOARD] [BOARD_QUALIFIER] [SDK_TOOLCHAIN] [ZEPHYR_REVISION]
zephyr-easy-setup.bat -InstallDir <DIRECTORY> [-Board <BOARD>] [-Qualifier <QUALIFIER>] [-Toolchain <TOOLCHAIN>] [-Revision <REVISION>]

zephyr-easy-setup.bat stm32f4_disco "" arm-zephyr-eabi
zephyr-easy-setup.bat it51xxx_evb it51xxx_evb/it51526aw riscv64-zephyr-elf v4.1.0
zephyr-easy-setup.bat -InstallDir D:\zephyr-arm -Board stm32f4_disco -Toolchain arm-zephyr-eabi
```

使用具名參數時，`-InstallDir` 放在批次檔參數的第一個位置。舊的板卡位置參數仍可使用，執行時會詢問安裝根目錄。若只要檢查所選安裝路徑，可以執行 `zephyr-easy-setup.bat -InstallDir D:\zephyr -CheckOnly`；它不複製檔案或安裝工具。

明確提供 BOARD 時，會先清除既有 qualifier；只有同時提供 QUALIFIER 才重新設定。未提供的板卡與工具鏈參數會沿用 `zephyrproject\.zephyr-setup.json`；沒有設定檔時才使用 ITE 預設值。該設定檔供後續離線打包及安裝使用。REVISION 只用於建立新工作區；若既有 `.west` 工作區仍傳入 REVISION，腳本會回報錯誤，不會切換版本。

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
2. 重用 `installers\tools\<package-id>` 中的安裝檔；缺少時透過 WinGet 下載 x64 EXE、MSI 或 ZIP。這些主機工具下載沒有指定 `--version`，不保證與來源電腦已安裝的工具版本相同；Python 套件則固定來源 `.venv` 的實際版本。
3. 在乾淨的暫存 `.venv` 使用 `--no-index` 安裝全部固定版本、執行 `pip check`，並驗證 Zephyr / 模組 requirements。
4. 複製程式碼、`.west`、`.git`、SDK、安裝檔及安裝／卸載腳本到暫存目錄。只在副本排除來源 `.venv` 與 `app\blinky\build`，保留其他檔案與來源編譯結果。
5. 建立逐檔 SHA-256 的 `bundle-manifest.json`，使用 7-Zip 壓縮並測試 ZIP。成功後才替換 `zephyr-offline-bundle.zip`。

**已安裝的工具不等於仍保留安裝檔。** 若原電腦沒有 Python、Git 等離線安裝程式或缺少 wheels，首次打包需連網補齊。已有完整快取時，可讓 pip 下載使用 `--no-index`，並禁止下載缺少的主機工具安裝檔：

```cmd
zephyr-pack-offline.bat -CacheOnly
```

`-CacheOnly` 仍會驗證來源 `.venv` 與 Zephyr / 模組 requirements，並建立及測試 ZIP。快取不足時直接回報錯誤，不會自動改成連網下載。

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

安裝前會檢查 manifest、SHA-256 與必要檔案，接著安裝或辨識主機工具、解壓縮 portable tools、建立 `.venv`、從固定版本 wheels 安裝 Python 套件、註冊 Zephyr / SDK 並編譯 Blinky。若已有 Python 3.12 x64 的相容 `.venv`，會重用並安裝固定版本套件；不會自動刪除該環境。此流程不執行 `winget install`、`west update` 或 `west sdk install`，pip 使用 `--isolated --no-index`。

可先只檢查離線包：

```cmd
zephyr-offline-install.bat -CheckOnly
```

`-CheckOnly` 檢查 manifest 格式、列出的檔案雜湊、必要工作區檔案、SDK 版本檔、wheels 是否存在及主機安裝檔清單；它不執行安裝、Python 相依性驗證、SDK 編譯器或 Blinky 編譯。

可用 `-Board`、`-Qualifier`、`-Toolchain` 覆寫目標；SDK 必須已包含對應工具鏈。例如：

```cmd
zephyr-offline-install.bat -Board stm32f4_disco -Toolchain arm-zephyr-eabi
```

安裝程式若要求重新啟動，腳本會停止，重啟後再執行。覆寫目標會更新設定檔，之後若要再次通過原 manifest 的雜湊檢查，請重新解壓縮完整 ZIP；卸載後重裝也需要重新解壓縮。

### Release ZIP 與完整離線包

Release 的 `zephyr-easy-setup-v<version>.zip` 提供腳本、文件與測試。包含 Zephyr 原始碼、SDK、Python wheels 及主機工具安裝檔的 `zephyr-offline-bundle.zip`，需由 `zephyr-pack-offline.bat` 在完整來源環境中產生，輸出到打包腳本所在的專案根目錄。

完整離線包包含 `zephyr-offline-install.bat`、`zephyr-uninstall.bat`、`zephyr-env.cmd`、`scripts`、README、manifest、安裝快取與工作區；不包含線上安裝／打包入口或 `tests` 目錄。下方隔離測試指令適用於原始碼 checkout 或 Release 腳本 ZIP。

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

測試使用專案內的暫存資料，涵蓋取消卸載、保留 app、限制刪除範圍、拒絕 junction、保留隱藏 metadata、SHA-256 / 安裝檔檢查、批次檔參數與錯誤碼、磁碟根目錄選擇與入口複製、中文 UTF-8 外部程式輸出，以及編譯失敗處理。磁碟根目錄的複製測試攔截寫入操作，不在真正的磁碟根目錄建立檔案。編譯結果處理使用 native stub，未執行實際 Zephyr 編譯；測試不安裝／移除系統工具，也不寫入使用者登錄。

完整驗收還需要：在線上機器完成安裝及編譯、產生 ZIP，再於沒有相關工具且斷網的 Windows x64 機器解壓縮安裝與編譯。隔離測試通過不代表上述完整驗收已完成。

自動化執行時，可設定 `ZEPHYR_NO_PAUSE=1` 省略批次檔最後的 pause；線上安裝請同時指定 `-InstallDir` 以略過目錄詢問。卸載的 y/N 確認仍會保留。

參考：[Zephyr Getting Started](https://docs.zephyrproject.org/latest/develop/getting_started/)、[WinGet download](https://learn.microsoft.com/windows/package-manager/winget/download)、[SDK 安裝參數定義](https://github.com/zephyrproject-rtos/zephyr/blob/main/scripts/west_commands/sdk.py)。
