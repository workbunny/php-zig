//! PHP 配置推导
//!
//! 运行时从 C 胶水层获取 PHP API 版本号和 build_id，自动适配编译时 PHP 头文件。

const c = @import("php_c.zig");

pub fn zendModuleApiNo() c_uint {
    return c.phpglue_module_api_no();
}

pub fn zendModuleBuildIdPtr() [*c]const u8 {
    return c.phpglue_module_build_id();
}
