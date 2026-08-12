//! 字符串操作说明
//!
//! 本文件无需提供独立实现。PHP 扩展开发中的字符串操作已覆盖：
//!
//! 1. zval 字符串取值    →  zval.zig  toStringVal() 返回 []const u8
//! 2. zval 字符串设值    →  zval.zig  setString()
//! 3. 返回值字符串       →  return.zig  returnString()
//! 4. 字符串拼接/格式化   →  Zig 标准库  std.mem / std.fmt
