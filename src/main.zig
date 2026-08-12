//! php-zig — Zig 编写的 PHP 扩展开发框架
//!
//! 框架入口模块，`pub const` 重新导出所有子模块的公开接口。
//! 下游使用 `const phpzig = @import("phpzig")` 即可访问全部能力。
//!
//! 模块清单：
//! - php_c        C 胶水函数声明（extern fn，一一对应 glue/php_glue.c）
//! - php_types    Zend 类型定义（opaque / extern struct）、IS_* 常量、函数签名
//! - php_config   运行时 PHP API 版本推导，避免硬编码
//! - Zval         类型安全的 zval 包装（类型判断、取值/设值、引用计数）
//! - Array        PHP 数组操作（追加/索引设值/关联设值/查找/删除/计数）
//! - Return       返回值工具 + 调用参数获取
//! - PhpFunc      PHP 函数调用 Facade（从 Zig 调用 PHP 内置/用户函数）
//! - Throw        PHP 异常抛出
//! - Iterator     数组/哈希表迭代器
//! - Object       PHP 对象属性读写
//! - Resource     PHP 资源类型封装
//! - mod          模块注册核心（comptime Module 泛型、生命周期钩子、类注册、arg_info、常量、phpinfo）

pub const php_c      = @import("php_c.zig");
pub const php_types  = @import("php_types.zig");
pub const php_config = @import("php_config.zig");
pub const Zval       = @import("zval.zig").Zval;
pub const Array      = @import("array.zig").Array;
pub const Return     = @import("return.zig");
pub const mod        = @import("module.zig");
pub const PhpFunc    = @import("php_func.zig");
pub const Throw      = @import("throw.zig");
pub const Iterator   = @import("iterator.zig").Iterator;
pub const Object     = @import("object.zig");
pub const Resource   = @import("resource.zig").Resource;

// 常用类型别名 — 避免下游写完整路径
pub const FunctionDesc       = mod.FunctionDesc;
pub const ClassDesc          = mod.ClassDesc;
pub const ParamDesc          = mod.ParamDesc;
pub const ConstantDesc       = mod.ConstantDesc;
pub const ClassConstantDesc  = mod.ClassConstantDesc;
pub const Module             = mod.Module;
pub const FunctionHandler    = php_types.FunctionHandler;
pub const ModuleLifecycleFn  = php_types.ModuleLifecycleFn;
