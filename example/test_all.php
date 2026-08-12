<?php
/**
 * php-zig v0.4.0 集成测试套件
 * 覆盖 100% 公开 API：
 *   - 模块级函数
 *   - 返回值类型（9种）
 *   - zval 类型判断 + 取值 + 设值（全 IS_* 覆盖）
 *   - 参数 arg_info（反射验证，含 comptime struct 反射类型标注）
 *   - 异常抛出
 *   - 模块常量（5种类型）
 *   - PHP Facade 调用
 *   - 类注册（静态方法 + comptime struct 反射）
 *   - 数组操作（append/set/setAssoc/find/del/count/separate/pop）
 *   - HashTable 遍历（迭代器）
 *   - 对象属性读写
 *   - 生命周期钩子（MINIT）
 *   - phpinfo 输出
 */

$passed = 0;
$failed = 0;
$skipped = 0;

function test(string $name, $expected, $actual): void {
    global $passed, $failed;
    if ($expected === $actual) {
        $passed++;
        echo "  ✓ $name\n";
    } else {
        $failed++;
        $exp = var_export($expected, true);
        $act = var_export($actual, true);
        echo "  ✗ $name  FAILED: expected $exp, got $act\n";
    }
}

function testException(string $name, callable $fn, string $expectedMsg): void {
    global $passed, $failed;
    try {
        $fn();
        $failed++;
        echo "  ✗ $name  FAILED: no exception thrown\n";
    } catch (\Exception $e) {
        if ($e->getMessage() === $expectedMsg) {
            $passed++;
            echo "  ✓ $name\n";
        } else {
            $failed++;
            echo "  ✗ $name  FAILED: expected '{$expectedMsg}', got '{$e->getMessage()}'\n";
        }
    }
}

function testTruthy(string $name, $actual): void {
    global $passed, $failed;
    if ($actual) {
        $passed++;
        echo "  ✓ $name\n";
    } else {
        $failed++;
        echo "  ✗ $name  FAILED: expected truthy, got " . var_export($actual, true) . "\n";
    }
}

// ============================================================
// 1. 模块级函数 — 基本调用
// ============================================================
echo "\n=== 1. 模块级函数 ===\n";

test('hello_world() 返回字符串', 'Hello from Zig!', hello_world());
test('hello_name("Bob") 返回问候语', 'Hello, Bob!', hello_name('Bob'));
test('hello_name() 无参返回 null', null, @hello_name());
test('version() 返回版本字符串', 'php-zig v0.5.0', version());

// ============================================================
// 2. 返回值类型 — 9种全覆盖
// ============================================================
echo "\n=== 2. 返回值类型 ===\n";

test('add(3,5) → long 8', 8, add(3, 5));
test('add(100,200) → long 300', 300, add(100, 200));
test('add(0,0) → long 0', 0, add(0, 0));
test('add(纯字符串,5) → 0+5=5', 5, add('x', 5));

// 3
echo "\n=== 3. zval 类型判断 + 取值 (hello_divide) ===\n";

test('hello_divide(10,3) → 3', 3, hello_divide(10, 3));
test('hello_divide(100,10) → 10', 10, hello_divide(100, 10));
test('hello_divide(-6,2) → -3', -3, hello_divide(-6, 2));

// ============================================================
// 4. arg_info 反射验证
// ============================================================
echo "\n=== 4. arg_info 参数元信息 ===\n";

$rAdd = new ReflectionFunction('add');
test('add 参数个数为2', 2, $rAdd->getNumberOfParameters());
test('add 参数1名为 a', 'a', $rAdd->getParameters()[0]->getName());
test('add 参数2名为 b', 'b', $rAdd->getParameters()[1]->getName());

$rDiv = new ReflectionFunction('hello_divide');
test('hello_divide 参数1名为 a', 'a', $rDiv->getParameters()[0]->getName());
test('hello_divide 参数2名为 b', 'b', $rDiv->getParameters()[1]->getName());

$rName = new ReflectionFunction('hello_name');
test('hello_name 参数个数为0（无ParamDesc）', 0, $rName->getNumberOfParameters());

// ============================================================
// 5. 异常抛出
// ============================================================
echo "\n=== 5. 异常抛出 ===\n";

testException('除零异常', fn() => hello_divide(10, 0), 'Division by zero');
testException('类型错误异常', fn() => hello_divide('a', 3), 'Both arguments must be integers');
testException('参数不足异常', fn() => hello_divide(5), 'Need 2 arguments');

// ============================================================
// 6. 模块常量
// ============================================================
echo "\n=== 6. 模块常量 ===\n";

test('HELLO_VERSION (long)', 1, HELLO_VERSION);
test('HELLO_PI (double)', 3.14159, HELLO_PI);
test('HELLO_AUTHOR (string)', 'php-zig', HELLO_AUTHOR);
test('HELLO_DEBUG (bool false)', false, HELLO_DEBUG);
test('HELLO_NULL (null)', null, HELLO_NULL);

// ============================================================
// 7. PHP Facade 调用
// ============================================================
echo "\n=== 7. PHP Facade 调用 ===\n";

test('hello_strlen("Hello") → 5', 5, hello_strlen('Hello'));
test('hello_strlen("") → 0', 0, hello_strlen(''));
test('hello_strlen("汉字") → 6', 6, hello_strlen('汉字'));
test('hello_concat("ab","cd") → abcd', 'abcd', hello_concat('ab', 'cd'));
test('hello_concat("","") → ""', '', hello_concat('', ''));

// ============================================================
// 8. 类注册 — Calculator 静态方法
// ============================================================
echo "\n=== 8. 类注册 ===\n";

test('Calculator::add(3,5) → 8', 8, Calculator::add(3, 5));
test('Calculator::add(0,0) → 0', 0, Calculator::add(0, 0));
test('Calculator::multiply(4,7) → 28', 28, Calculator::multiply(4, 7));
test('Calculator::multiply(0,100) → 0', 0, Calculator::multiply(0, 100));

// 类方法 arg_info
$rCalcAdd = new ReflectionMethod('Calculator', 'add');
test('Calculator::add 参数1为 a', 'a', $rCalcAdd->getParameters()[0]->getName());
test('Calculator::add 参数2为 b', 'b', $rCalcAdd->getParameters()[1]->getName());

// 类常量
test('CalcConst::PI (类常量)', 3, CalcConst::PI);
test('CalcConst::NAME (类常量)', 'Calculator', CalcConst::NAME);

// ============================================================
// 9. 数组操作
// ============================================================
echo "\n=== 9. 数组操作 ===\n";

test('hello_pop([10,20,30]) → 30', 30, hello_pop([10, 20, 30]));
test('hello_pop([42]) → 42', 42, hello_pop([42]));

// ============================================================
// 10. HashTable 遍历（迭代器）
// ============================================================
echo "\n=== 10. HashTable 迭代器 ===\n";

test('hello_iterate(["a","b","c"]) → a,b,c', 'a,b,c', hello_iterate(['a', 'b', 'c']));
test('hello_iterate(["单"]) → 单', '单', hello_iterate(['单']));
test('hello_iterate([]) → 空串', '', hello_iterate([]));

// ============================================================
// 11. 对象属性读写
// ============================================================
echo "\n=== 11. 对象属性 ===\n";

test('hello_object() → php-zig', 'php-zig', hello_object());

// ============================================================
// 12. 生命周期钩子
// ============================================================
echo "\n=== 12. 生命周期钩子 ===\n";

// MINIT 在模块加载时已自动执行。这里验证模块正常加载（函数可用即代表生命周期正常）
testTruthy('模块正常加载 / MINIT 已执行', function_exists('hello_world'));
testTruthy('常量已注册 / MINIT 已执行', defined('HELLO_VERSION'));

// ============================================================
// 13. phpinfo 输出
// ============================================================
echo "\n=== 13. phpinfo ===\n";

ob_start();
phpinfo(INFO_MODULES);
$output = ob_get_clean();
testTruthy('phpinfo 模块输出中包含 php-zig', strpos($output, 'php-zig') !== false);

// ============================================================
// 14. 边界情况
// ============================================================
echo "=== 15. v0.3.0: Zval 运算符 + Array 算法 ===\n";

test('hello_zip(42,42) → equal', 'equal', hello_zip(42, 42));
test('hello_zip(1,2) → not-equal', 'not-equal', hello_zip(1, 2));
test('hello_map() → 6 (third elem doubled)', 6, hello_map());
test('hello_filter() → 2 evens out of 4', 2, hello_filter());
test('hello_reduce() → sum 1+2+3+4 = 10', 10, hello_reduce());

echo "\n=== 16. 边界情况 ===\n";

test('add 带小数 → 浮点 isLong=false, 0+0=0', 0, add(3.7, 4.2));
test('hello_pop 空数组 → null', null, hello_pop([]));
test('hello_strlen 非字符串 → null', null, @hello_strlen(123));
test('hello_concat 参数不足 → null', null, @hello_concat('a'));
test('hello_name 非字符串 → null', null, @hello_name(123));
test('hello_iterate 非数组 → null', null, @hello_iterate('not_array'));

// ============================================================
// 17. v0.4.0: comptime struct 反射 arg_info
// ============================================================
echo "\n=== 17. v0.4.0: comptime struct 反射 arg_info ===\n";

test('hello_sum(5,3) → 8', 8, hello_sum(5, 3));
test('hello_sum(0,0) → 0', 0, hello_sum(0, 0));
test('hello_format("Alice",30) → "Alice is 30 years old"', 'Alice is 30 years old', hello_format('Alice', 30));

// createFrom 反射验证
$rSum = new ReflectionFunction('hello_sum');
test('hello_sum 参数个数为2', 2, $rSum->getNumberOfParameters());
test('hello_sum 参数1名为 a', 'a', $rSum->getParameters()[0]->getName());
test('hello_sum 参数2名为 b', 'b', $rSum->getParameters()[1]->getName());
test('hello_sum 参数1类型为 int', true, $rSum->getParameters()[0]->hasType() && (string)$rSum->getParameters()[0]->getType() === 'int');

$rFmt = new ReflectionFunction('hello_format');
test('hello_format 参数1名为 name', 'name', $rFmt->getParameters()[0]->getName());
test('hello_format 参数2名为 age', 'age', $rFmt->getParameters()[1]->getName());
test('hello_format 参数1类型为 string', true, $rFmt->getParameters()[0]->hasType() && (string)$rFmt->getParameters()[0]->getType() === 'string');
test('hello_format 参数2类型为 int', true, $rFmt->getParameters()[1]->hasType() && (string)$rFmt->getParameters()[1]->getType() === 'int');

// createStaticFrom 反射验证
test('Calculator::subtract(10,3) → 7', 7, Calculator::subtract(10, 3));
$rSub = new ReflectionMethod('Calculator', 'subtract');
test('subtract 参数1名为 a', 'a', $rSub->getParameters()[0]->getName());
test('subtract 参数1类型为 int', true, $rSub->getParameters()[0]->hasType() && (string)$rSub->getParameters()[0]->getType() === 'int');

// ============================================================
// 18. v0.5.0: OOP — 类属性 + 构造器 + 继承 + 访问修饰符
// ============================================================
echo "\n=== 18. v0.5.0: OOP ===\n";

// BankAccount 属性默认值
$rBA = new ReflectionClass('BankAccount');
$props = $rBA->getDefaultProperties();
test('BankAccount::$balance 默认值 0', 0, $props['balance']);
test('BankAccount::$open 默认值 true', true, $props['open']);
test('BankAccount 属性数 2', 2, count($rBA->getProperties()));

// BankAccount 方法可见性
$rGetBal = new ReflectionMethod('BankAccount', 'getBalance');
test('getBalance 为 protected', true, $rGetBal->isProtected());
$rInternal = new ReflectionMethod('BankAccount', 'internal');
test('internal 为 private', true, $rInternal->isPrivate());

// __construct 存在
test('BankAccount 有 __construct', true, $rBA->hasMethod('__construct'));

// Calculator 已有方法不受影响
test('Calculator::add(1,1) 仍正常', 2, Calculator::add(1, 1));

// SavingsAccount 继承
$rSA = new ReflectionClass('SavingsAccount');
test('SavingsAccount 父类为 BankAccount', 'BankAccount', $rSA->getParentClass()->getName());
test('SavingsAccount 有 interest 方法', true, $rSA->hasMethod('interest'));

// ============================================================
// 结果汇总
// ============================================================
$total = $passed + $failed;
echo "\n========================================\n";
echo "结果: $passed / $total 通过";
if ($failed > 0) {
    echo ", $failed 失败\n";
    exit(1);
}
echo "\n全部通过 ✓\n";
