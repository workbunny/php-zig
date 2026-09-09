//! PHP 配置推导
//!
//! 运行时从 C 胶水层获取 PHP API 版本号、build_id 与线程模型，自动适配编译时 PHP 头文件。

const c = @import("php_c.zig");

pub fn zendModuleApiNo() c_uint {
    return c.phpglue_module_api_no();
}

pub fn zendModuleBuildIdPtr() [*c]const u8 {
    return c.phpglue_module_build_id();
}

/// 线程模型：1 = ZTS，0 = NTS。
///
/// 骨架的请求级状态（Cleanup 注册表、arena 派生额度）已按线程隔离，
/// 两种模型下行为一致；此值供下游决定能否自开线程——自开线程拿不到请求
/// 上下文，需要的数据必须显式传入或走 IPC。
pub fn ztsMode() u8 {
    return c.phpglue_zts_mode();
}
