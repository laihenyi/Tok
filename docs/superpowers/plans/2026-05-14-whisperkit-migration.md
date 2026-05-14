# WhisperKit 遷移至 argmax-oss-swift 實施計劃

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 將 WhisperKit 依賴從已棄用的 `argmaxinc/WhisperKit` 遷移至統一 SDK `argmaxinc/argmax-oss-swift`

**Architecture:** 替換 SPM package reference（URL + version requirement），product name 保持 `WhisperKit` 不變。`argmax-oss-swift` 將 `swift-transformers` 的 tokenizer 邏輯內建到 `ArgmaxCore`，因此不再需要該 transitive dependency。所有 `import WhisperKit` 語句保持不變。

**Tech Stack:** Xcode SPM, Swift 6, project.pbxproj 編輯

**風險重點:** `AudioStreamTranscriber` 初始化需要的內部組件（audioEncoder, featureExtractor, segmentSeeker, textDecoder, audioProcessor）可能在新建構中有 API 變更。

---

## 前置準備

### Task 0: 建立遷移 Branch 與備份

**Files:**
- Create: `docs/superpowers/plans/2026-05-14-whisperkit-migration.md` (本文件)

- [ ] **Step 1: 建立 branch**

```bash
cd /Users/laihenyi/Documents/GitHub/Tok
git checkout -b migration/whisperkit-argmax-oss
```

預期: `Switched to a new branch 'migration/whisperkit-argmax-oss'`

- [ ] **Step 2: 備份當前 Package.resolved**

```bash
cp Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved.bak
```

- [ ] **Step 3: 提交備份**

```bash
git add Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved.bak
git commit -m "chore: backup Package.resolved before migration"
```

---

## 核心遷移

### Task 1: 修改 SPM Package Reference

**Files:**
- Modify: `Hex.xcodeproj/project.pbxproj:566-573`

- [ ] **Step 1: 更新 repositoryURL 和 requirement**

在 `project.pbxproj` 中，找到 `XCRemoteSwiftPackageReference "WhisperKit"` 區塊（約 line 566-573），將：

```
47E05E252D44555500D26DA6 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://github.com/argmaxinc/WhisperKit";
    requirement = {
        branch = main;
        kind = branch;
    };
};
```

改為：

```
47E05E252D44555500D26DA6 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://github.com/argmaxinc/argmax-oss-swift";
    requirement = {
        kind = upToNextMajorVersion;
        minimumVersion = 0.9.0;
    };
};
```

使用 Edit 工具精確替換 `project.pbxproj:566-573`。

- [ ] **Step 2: 刪除 Package.resolved 以強制重新解析**

```bash
rm Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

- [ ] **Step 3: 嘗試解析 package**

```bash
xcodebuild -project Hex.xcodeproj -scheme Tok -configuration Debug -resolvePackageDependencies 2>&1 | tail -30
```

預期: package 解析成功，無錯誤。若失敗，比對錯誤訊息判斷是否需要調整 version 或 product name。

- [ ] **Step 4: 提交 SPM 設定變更**

```bash
git add Hex.xcodeproj/project.pbxproj Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "chore: switch WhisperKit to argmax-oss-swift 0.9.0+"
```

---

## 編譯與修復

### Task 2: 嘗試建置並收集編譯錯誤

**Files:**
- Check: 所有 `import WhisperKit` 的檔案（10 個 .swift 檔案）

- [ ] **Step 1: 執行完整建置**

```bash
xcodebuild -project Hex.xcodeproj -scheme Tok -configuration Debug build 2>&1 | tee /tmp/tok-build.log
```

預期: 建置可能失敗，需要收集所有錯誤。

- [ ] **Step 2: 檢查建置結果**

```bash
grep -E "error:|warning:" /tmp/tok-build.log | head -50
```

- [ ] **Step 3: 分類錯誤**

手動檢視錯誤列表，分類為：
- A) `WhisperKit` 模組找不到 → package 解析問題
- B) API 不存在（如 `AudioStreamTranscriber` init 參數不同）
- C) 類型名稱變更（如 `WhisperTokenizer` → 不同名稱）
- D) Swift 6 StrictConcurrency 問題
- E) 其他

根據錯誤類別，參考下方 Task 3/4/5 的修復策略。

- [ ] **Step 4: 若建置成功（無錯誤），跳到 Task 6**

若 xcodebuild 返回 0 且無 error，直接跳到 Task 6 進行測試。

---

### Task 3: 修復 API 不相容問題

**Files:**
- 主要: `Hex/Clients/TranscriptionClient.swift`
- 可能: 其他 import WhisperKit 的檔案

**注意:** 此 Task 的具體修復內容取決於 Task 2 的錯誤輸出。以下是預期的潛在問題與修復方向。

- [ ] **Step 1: 檢查 `AudioStreamTranscriber` init 簽名**

若 `AudioStreamTranscriber` 的 init 參數有變更，對照新 package 的 API 文件調整。

`TranscriptionClient.swift:964-1021` 目前的 init：

```swift
AudioStreamTranscriber(
  audioEncoder: whisperKit.audioEncoder,
  featureExtractor: whisperKit.featureExtractor,
  segmentSeeker: whisperKit.segmentSeeker,
  textDecoder: whisperKit.textDecoder,
  tokenizer: tokenizer,
  audioProcessor: whisperKit.audioProcessor,
  decodingOptions: options
)
```

若 `WhisperKit` 不再直接暴露這些內部組件，需要改用新的 streaming API 方式。

- [ ] **Step 2: 檢查 `WhisperKitConfig` 參數**

`TranscriptionClient.swift:855-863`：

```swift
let config = WhisperKitConfig(
  model: modelName,
  modelFolder: modelFolder.path,
  tokenizerFolder: tokenizerFolder,
  prewarm: true,
  load: true
)
```

比對新建構的 `WhisperKitConfig` 是否接受相同參數。

- [ ] **Step 3: 檢查 `WhisperKit` 靜態方法**

`TranscriptionClient.swift:253` - `WhisperKit.recommendedRemoteModels()`
`TranscriptionClient.swift:260` - `WhisperKit.fetchAvailableModels()`
`TranscriptionClient.swift:812-821` - `WhisperKit.download(variant:...)`

確認這些方法在新建構中是否存在且簽名相同。

- [ ] **Step 4: 檢查 `DecodingOptions` 和 `TranscriptionResult`**

若這些類型命名空間有變，更新 import 或類型參照。

- [ ] **Step 5: 再次建置**

```bash
xcodebuild -project Hex.xcodeproj -scheme Tok -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20
```

- [ ] **Step 6: 提交修復**

```bash
git add -A
git commit -m "fix: update API calls for argmax-oss-swift compatibility"
```

---

### Task 4: 修復 Swift 6 StrictConcurrency 問題（若有）

- [ ] **Step 1: 檢查 StrictConcurrency 相關錯誤**

```bash
grep -i "concurrency\|sendable\|actor\|isolated" /tmp/tok-build.log
```

- [ ] **Step 2: 逐項修復**

由於 `argmax-oss-swift` 啟用了 `StrictConcurrency` experimental feature，其公開 API 可能要求更多 `@Sendable` 標註。可能需要：
- 將 callback closure 加上 `@Sendable`
- 將 struct 加上 `Sendable` conformance
- 調整 actor isolation

- [ ] **Step 3: 建置驗證**

```bash
xcodebuild -project Hex.xcodeproj -scheme Tok -configuration Debug build 2>&1 | grep -E "error:" | head -10
```

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "fix: resolve Swift 6 StrictConcurrency issues"
```

---

### Task 5: 處理 `swift-transformers` 遺留問題

- [ ] **Step 1: 確認不再需要 swift-transformers**

若 Tok 程式碼中有直接 `import SwiftTransformers`（檢查）：

```bash
grep -rn "SwiftTransformers\|import.*Transformers" Hex/
```

- [ ] **Step 2: 若無直接引用，不需動作**

`swift-transformers` 是舊 WhisperKit 的 transitive dependency，換到新 package 後會自動從 Package.resolved 消失。

- [ ] **Step 3: 若有直接引用，需重構**

將直接使用 `SwiftTransformers` 的程式碼改為使用新 `WhisperKit` 提供的等價 API（如 `WhisperTokenizer`）。

---

## 測試

### Task 6: 功能測試

- [ ] **Step 1: 啟動 App 並確認基本功能**

```bash
open Hex.xcodeproj
```

在 Xcode 中 Run (Cmd+R)，確認：
- App 啟動無 crash
- Menu bar 圖示顯示正常
- 設定視窗可開啟
- Model 列表可載入（從 HuggingFace 取得可用模型列表）

- [ ] **Step 2: 測試 Model 下載**

在 Settings 中：
- 切換到一個已安裝的 model，確認可正常載入
- 若需要測試下載，選一個未下載的小 model（如 `tiny`）
- 確認下載進度正常顯示

- [ ] **Step 3: 測試離線轉錄**

- 用 hotkey 觸發錄音
- 說話後放開
- 確認轉錄結果正確顯示
- 檢查繁體中文轉換是否正常
- 確認標點符號系統正常運作

- [ ] **Step 4: 測試串流转錄（Streaming）**

- 按壓 hotkey 開始錄音
- 觀察即時文字顯示（若有啟用隱藏串流文字）
- 放開 hotkey 後確認最終結果
- 比對串流文字與離線轉錄結果的一致性

- [ ] **Step 5: 測試 AI Enhancement（若有啟用）**

- 完成轉錄後，若 AI Enhancement 開啟
- 確認增強後的文字正確替換

---

### Task 7: Regression 測試

- [ ] **Step 1: 執行現有 Test Suite**

```bash
xcodebuild test -project Hex.xcodeproj -scheme Tok -destination 'platform=macOS' 2>&1 | tail -30
```

確認所有測試通過。

- [ ] **Step 2: 若測試失敗，修復**

根據失敗的測試訊息修正程式碼或測試。

- [ ] **Step 3: 提交測試修復**

```bash
git add -A
git commit -m "test: fix tests after WhisperKit migration"
```

---

## 收尾

### Task 8: 清理與文檔

- [ ] **Step 1: 移除備份文件**

```bash
rm Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved.bak
```

- [ ] **Step 2: 更新 CLAUDE.md（若需要）**

若有任何開發流程變更（如 model 名稱格式不同、新的設定項），更新 CLAUDE.md。

- [ ] **Step 3: 最終建置驗證**

```bash
xcodebuild -project Hex.xcodeproj -scheme Tok -configuration Debug build 2>&1 | tail -5
```

預期: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 最終提交**

```bash
git add -A
git commit -m "chore: cleanup after WhisperKit migration

- Removed backup files
- Updated documentation

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 5: 合併回 main**

```bash
git checkout main
git merge migration/whisperkit-argmax-oss
```

---

## 還原計劃

若遷移遇到無法解決的 API 不相容問題：

```bash
# 回到 main branch
git checkout main
git branch -D migration/whisperkit-argmax-oss

# 或從備份還原 Package.resolved
cp Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved.bak \
   Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```
