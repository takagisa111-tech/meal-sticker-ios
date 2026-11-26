# Meal Sticker 食贴（iOS）

拍下每一餐，做成贴纸贴进手账。用 SwiftUI 写的原生 iPhone App。

## 功能
- **贴纸手账**：拍照后自动抠出食物，做成带白边的贴纸，在当天的手账页上拖动、缩放、旋转
- **营养分析**：调用 DeepSeek 识别食物，估算热量与营养，按膳食指南分析一周饮食，推荐下一餐
- **家人与宠物**：可以分别给家里的老人、宠物记录饮食，分析各自不同
- **吃什么**：附近餐厅（Apple 地图）跳转大众点评；冰箱食材做菜；拍菜单给点餐建议
- **购物清单**：同步到 iPhone「提醒事项」，可一键加入京东 / 淘宝购物车
- **提醒与小组件**：按时吃饭提醒，桌面小组件显示今天的餐食

## 运行
1. 用 Xcode 打开 `ShiTie.xcodeproj`
2. 把 `ShiTie/Secrets.example.swift` 复制一份，改名为 `ShiTie/Secrets.swift`，填上自己的 DeepSeek API Key（也可以留空，之后在 App「我的」里填）
3. 在 Signing & Capabilities 里选自己的开发者账号（App 和小组件两个 target 都要选，App Group 也要改成自己的）
4. 连上 iPhone 运行

## 结构
| 目录 | 内容 |
| --- | --- |
| `ShiTie/` | App 主体：页面、数据存储、AI 调用、抠图贴纸 |
| `ShiTieWidget/` | 桌面小组件 |
| `Shared/` | App 和小组件共用的代码 |

另有微信小程序版本，单独维护。
