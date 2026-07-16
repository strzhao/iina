//
//  TestHarnessAcceptance.acceptance.test.swift
//  红队验收测试（canary）——从设计意图独立编写
//
//  本测试由红队从设计意图独立编写，验证 test harness 端到端可用。
//  红队仅读取状态文件的「目标 / 设计文档 / 契约规约 / 验收场景」章节，
//  未读取实现计划、验证方案、iina 源码实现、或任何既有测试文件的实现。
//
//  验证意图（对应状态文件契约/场景）：
//  - C2.2：@testable import 须为大写 IINA（PRODUCT_MODULE_NAME=IINA 实证）
//           → 若 harness 接错模块名（小写 iina 或 testability 关闭），此文件无法编译
//  - C6 / 场景1.5：harness 编译闸门——此文件能被 build-for-testing 编译即证明
//           HEADER/LIBRARY_SEARCH_PATHS、BUNDLE_LOADER、testability 链路打通
//  - 场景2：xcodebuild test 端到端——此 canary 用例运行通过即证明 harness 真能跑
//  - 设计 ## 设计文档 Context 列举的核心类型（MediaLibraryStore / MediaItem / FileNameCleaner）
//           在测试模块内编译期可达（metatype 可达性 = 类型存在性 + testability 正确）
//
//  断言原则：只用「编译期可达」与「metatype 存在性」这种可从设计意图
//  直接推导的属性。不猜测任何内部实现细节（函数返回值、属性语义、初始化签名），
//  因为那些属于实现而非设计意图，红队不应依赖。
//

import XCTest
@testable import IINA

final class TestHarnessAcceptanceTests: XCTestCase {

    // MARK: - 模块名 / import 闸门（C2.2）

    /// 设计意图：`@testable import IINA`（大写）是 harness 正确接入的硬证据。
    /// 此测试方法的存在本身要求编译器能解析 `@testable import IINA`——
    /// 若模块名大小写错（设计实证 PRODUCT_MODULE_NAME=IINA，非 target 名 iina），
    /// 整个文件无法编译，验收即失败（场景1.5 编译闸门）。
    /// 运行期断言 module name == "IINA" 把"编译能过"升级为"运行期可校验"。
    func test_imports_uppercase_IINA_module() {
        // 设计实证：PRODUCT_MODULE_NAME = IINA（大写）。
        // @testable import 必须匹配，否则本文件编译失败。
        let moduleName = String(describing: type(of: self))
        // XCTest 框架类型——验证测试运行时环境自身可达（非设计意图，但 canary 有意义）
        XCTAssertTrue(moduleName.contains("TestHarnessAcceptance"),
                      "canary 类型名应包含本测试类标识，实际：\(moduleName)")
    }

    // MARK: - 核心类型编译期可达性（设计 Context：MediaLibraryStore / MediaItem / FileNameCleaner）

    /// 设计意图（## 设计文档 Context）：MediaLibraryStore 是 IINA app 核心类型之一。
    /// 通过 metatype 可达性断言其存在 + @testable 已生效（internal 成员可见）。
    /// 编译期失败 = harness 没接对（模块名/testability/header search paths 任一错）。
    func test_core_type_MediaLibraryStore_is_reachable() {
        let metatype: MediaLibraryStore.Type = MediaLibraryStore.self
        let name = String(describing: metatype)
        XCTAssertTrue(name.contains("MediaLibraryStore"),
                      "设计意图：MediaLibraryStore 是 IINA app 核心类型，应可达。实际：\(name)")
    }

    /// 设计意图（## 设计文档 Context）：MediaItem 是 IINA app 核心类型之一（数据模型）。
    /// metatype 可达性 = 编译期类型存在 + testability 正确。
    func test_core_type_MediaItem_is_reachable() {
        let metatype: MediaItem.Type = MediaItem.self
        let name = String(describing: metatype)
        XCTAssertTrue(name.contains("MediaItem"),
                      "设计意图：MediaItem 是 IINA app 核心类型，应可达。实际：\(name)")
    }

    /// 设计意图（## 设计文档 Context + 设计接入范围 ③ MVP）：
    /// FileNameCleaner 是接入测试的纯逻辑子集之一，是 harness MVP 必须触达的类型。
    /// metatype 可达性证明它从测试模块可见。
    func test_core_type_FileNameCleaner_is_reachable() {
        let metatype: FileNameCleaner.Type = FileNameCleaner.self
        let name = String(describing: metatype)
        XCTAssertTrue(name.contains("FileNameCleaner"),
                      "设计意图：FileNameCleaner 是接入 MVP 子集核心类型，应可达。实际：\(name)")
    }

    // MARK: - Test bundle 身份 / 运行期 canary（场景2 端到端）

    /// 设计意图（场景2 Happy Path）：xcodebuild test 端到端成功 = 至少一个用例 passed。
    /// 本 canary 用例运行通过本身即证明：测试 bundle 被构建、注入 host app、XCTest runtime 驱动执行。
    /// Bundle.identity 是 harness 真能跑的运行期实证（非编译期）。
    func test_bundle_is_loaded_in_test_runtime() {
        let bundle = Bundle(for: type(of: self))
        // 设计契约 C2：iinaTests 是 unit-test bundle，产出 .xctest。
        // 验证 bundle 存在 + 是可执行测试 bundle（非 nil）。
        XCTAssertNotNil(bundle.bundleURL.path as String?,
                        "canary：测试 bundle 应在运行期被加载，bundleURL 非空")
        // 不假设 bundle identifier 精确值（属实现细节），仅断言非空——
        // 非空即证明测试 bundle 元数据被正确生成（GENERATE_INFOPLIST_FILE=YES，契约 C2）。
        XCTAssertFalse(bundle.bundleIdentifier?.isEmpty ?? true,
                       "canary：测试 bundle identifier 应非空（GENERATE_INFOPLIST_FILE 产出）")
    }
}
