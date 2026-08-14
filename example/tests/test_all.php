<?php
/**
 * php-zig 集成测试套件
 * 覆盖全部公开 API：
 *   - 模块级函数
 *   - 返回值类型（9种）
 *   - zval 类型判断 + 取值 + 设值 + 语义判断
 *   - 参数 arg_info（反射验证，含 comptime struct 反射类型标注）
 *   - 异常抛出、错误报告
 *   - 模块常量（5种类型）
 *   - PHP Facade 调用、闭包
 *   - 类注册（静态方法 + comptime struct 反射）、接口、继承
 *   - 数组操作（增删查 + 高级操作）
 *   - HashTable 遍历（迭代器）
 *   - 对象属性读写、instanceof
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

// 通用：捕获 \Throwable（覆盖 Error 家族 + 自定义异常/错误类）
function testThrowable(string $name, callable $fn, string $expectedClass, string $expectedMsg): void {
    global $passed, $failed;
    try {
        $fn();
        $failed++;
        echo "  ✗ $name  FAILED: no throwable thrown\n";
    } catch (\Throwable $e) {
        if (get_class($e) === $expectedClass && $e->getMessage() === $expectedMsg) {
            $passed++;
            echo "  ✓ $name\n";
        } else {
            $failed++;
            echo "  ✗ $name  FAILED: expected {$expectedClass}('{$expectedMsg}'), got " . get_class($e) . "('{$e->getMessage()}')\n";
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
test('version() 返回版本字符串', 'php-zig v0.9.0', version());

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

// v0.8：自定义异常类 + Error 家族
echo "\n=== 5b. 异常抛出扩展（自定义异常 + Error 家族） ===\n";

testThrowable('抛自定义异常 MyAppException', fn() => hello_throw_custom('boom'), 'MyAppException', 'boom');

// 抛出的对象是 Exception 实例（运行时 instanceof 验证）
$myEx = null;
try { hello_throw_custom('boom'); } catch (\Throwable $e) { $myEx = $e; }
test('MyAppException instanceof Exception', true, $myEx instanceof \Exception);

// 自定义 Error（继承 Error）
$myErr = null;
try { hello_throw_custom_code(42); } catch (\Throwable $e) { $myErr = $e; }
test('自定义错误 MyAppError 类名', 'MyAppError', $myErr ? get_class($myErr) : null);
test('自定义错误 code = 42', 42, $myErr ? $myErr->getCode() : -1);
test('自定义错误 instanceof Error', true, $myErr instanceof \Error);

// 内置 Error 家族
testThrowable('TypeError', fn() => hello_throw_type_error('bad type'), 'TypeError', 'bad type');
testThrowable('ValueError', fn() => hello_throw_value_error(), 'ValueError', 'invalid value');
testThrowable('DivisionByZeroError', fn() => hello_throw_div_zero(), 'DivisionByZeroError', 'division by zero');

// 自定义异常继承关系验证
test('MyAppException 继承 Exception', true, is_subclass_of('MyAppException', 'Exception'));
test('MyAppError 继承 Error', true, is_subclass_of('MyAppError', 'Error'));

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
echo "=== 15. Zval 运算符 + Array 算法 ===\n";

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
// 17. comptime struct 反射 arg_info
// ============================================================
echo "\n=== 17. comptime struct 反射 arg_info ===\n";

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
// 18. OOP — 类属性 + 构造器 + 继承 + 访问修饰符
// ============================================================
echo "\n=== 18. OOP ===\n";

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
// 19. 数组高级操作 + Zval 运算符
// ============================================================
echo "\n=== 19. 数组高级操作 + Zval 运算符 ===\n";

// shift — 移除并返回第一个元素
test('hello_array_shift([1,2,3]) → 1', 1, hello_array_shift([1, 2, 3]));
test('hello_array_shift([]) → null', null, hello_array_shift([]));

// unshift — 头部插入
test('hello_array_unshift([2,3], 1) → [1,2,3]', [1, 2, 3], hello_array_unshift([2, 3], 1));

// merge — 合并两个数组
test('hello_array_merge([1,2],[3,4]) → [1,2,3,4]', [1, 2, 3, 4], hello_array_merge([1, 2], [3, 4]));
test('hello_array_merge 关联键覆盖', ['a' => 1, 'b' => 2], hello_array_merge(['a' => 1], ['b' => 2]));

// keys
test('hello_array_keys 数字键', [0, 1, 2], hello_array_keys([10, 20, 30]));
test('hello_array_keys 关联键', ['x', 'y'], hello_array_keys(['x' => 1, 'y' => 2]));

// values
test('hello_array_values 关联数组 → 值列表', [1, 2, 3], hello_array_values(['a' => 1, 'b' => 2, 'c' => 3]));

// slice
test('hello_array_slice([1,2,3,4],1,2) → [2,3]', [2, 3], hello_array_slice([1, 2, 3, 4], 1, 2));
test('hello_array_slice([1,2,3,4],2,-1) → [3,4]', [3, 4], hello_array_slice([1, 2, 3, 4], 2, -1));

// sort
test('hello_array_sort([3,1,2]) → [1,2,3]', [1, 2, 3], hello_array_sort([3, 1, 2]));

// each — foreach 语法糖（求和）
test('hello_array_each([1,2,3,4]) → 10', 10, hello_array_each([1, 2, 3, 4]));

// Zval 算术运算符
test('hello_zval_add(1,2) → 3', 3, hello_zval_add(1, 2));
test('hello_zval_add(1.5, 2) → 3.5', 3.5, hello_zval_add(1.5, 2));
test('hello_zval_add(5,7) → 12', 12, hello_zval_add(5, 7));

// Zval 比较运算符
test('hello_zval_cmp(1,2) → -1', -1, hello_zval_cmp(1, 2));
test('hello_zval_cmp(2,1) → 1', 1, hello_zval_cmp(2, 1));
test('hello_zval_cmp(1,1) → 0', 0, hello_zval_cmp(1, 1));
test('hello_zval_cmp("a","b") → -1', -1, hello_zval_cmp('a', 'b'));

// ============================================================
// 20. 语义类型判断 + instanceof + 闭包 + 接口
// ============================================================
echo "\n=== 20. 语义类型判断 + instanceof + 闭包 + 接口 ===\n";

// 类型补全（位掩码：bit0=callable bit1=iterable bit2=scalar bit3=empty bit4=numeric）
test('hello_type_checks(42) → 标量+数值=20', 20, hello_type_checks(42));
test('hello_type_checks([1,2,3]) → 可迭代=2', 2, hello_type_checks([1, 2, 3]));
test('hello_type_checks(null) → 空=8', 8, hello_type_checks(null));
test('hello_type_checks("") → 空+标量=12', 12, hello_type_checks(''));
test('hello_type_checks("123") → 标量+数值=20', 20, hello_type_checks('123'));
test('hello_type_checks(闭包) → 可调用=1', 1, hello_type_checks(hello_make_closure()));

// instanceof
$p = new Person();
test('$p instanceof Person', true, $p instanceof Person);
test('$p instanceof Greetable', true, $p instanceof Greetable);
test('hello_instanceof($p, "Person")', true, hello_instanceof($p, 'Person'));
test('hello_instanceof($p, "Greetable")', true, hello_instanceof($p, 'Greetable'));
test('hello_instanceof($p, "NotExist")', false, hello_instanceof($p, 'NotExist'));

// 接口方法
test('$p->greet() → "hello"', 'hello', $p->greet());

// 闭包
$c = hello_make_closure();
test('$c instanceof Closure', true, $c instanceof Closure);
test('$c() → "closure result"', 'closure result', $c());
test('hello_call_closure($c) → "closure result"', 'closure result', hello_call_closure($c));

// ============================================================
// 21. v0.8 — 参数默认值 + 可变参数
// ============================================================
echo "\n=== 21. v0.8 参数默认值 + 可变参数 ===\n";

test('hello_greet("Bob") 使用默认 greeting', 'Hello, Bob!', hello_greet('Bob'));
test('hello_greet("Bob","Hi") 自定义 greeting', 'Hi, Bob!', hello_greet('Bob', 'Hi'));

$rGreet = new ReflectionFunction('hello_greet');
test('hello_greet 参数2有默认值', true, $rGreet->getParameters()[1]->isDefaultValueAvailable());
test('hello_greet 参数2默认值为 Hello', 'Hello', $rGreet->getParameters()[1]->getDefaultValue());

test('hello_sum_all(1,2,3) → 6', 6, hello_sum_all(1, 2, 3));
test('hello_sum_all(10) → 10', 10, hello_sum_all(10));
test('hello_sum_all() → 0', 0, hello_sum_all());

$rSumAll = new ReflectionFunction('hello_sum_all');
test('hello_sum_all 参数2为可变参数', true, $rSumAll->getParameters()[1]->isVariadic());
test('hello_sum_all 必填参数数为1', 1, $rSumAll->getNumberOfRequiredParameters());

// ============================================================
// 22. v0.8 — 序列化
// ============================================================
echo "\n=== 22. v0.8 序列化 ===\n";

test('hello_serialize([1,2,3])', 'a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}', hello_serialize([1, 2, 3]));
test('hello_serialize("hello")', 's:5:"hello";', hello_serialize('hello'));
test('hello_serialize(42)', 'i:42;', hello_serialize(42));
test('hello_unserialize → 还原数组', [1, 2, 3], hello_unserialize('a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}'));
test('hello_unserialize → 还原字符串', 'hello', hello_unserialize('s:5:"hello";'));
test('hello_unserialize 非法输入 → null', null, @hello_unserialize('not-valid'));

// toObject 对象包装
$obj = new stdClass();
$obj->name = 'zig';
test('hello_to_object($obj) 读取 name 属性', 'zig', hello_to_object($obj));
test('hello_to_object(非对象) → null', null, @hello_to_object('not-an-object'));

// ============================================================
// 23. v0.8 — INI 配置 + 变更通知
// ============================================================
echo "\n=== 23. v0.8 INI 配置 ===\n";

test('hello_get_ini_max 默认 100', 100, hello_get_ini_max());
test('hello_get_ini_greeting 默认 Hi', 'Hi', hello_get_ini_greeting());
test('hello_get_ini_enabled 默认 true', true, hello_get_ini_enabled());

// ini_set 修改后读取 + 变更通知计数
$before = hello_ini_change_count();
ini_set('hello.max_items', '200');
test('ini_set 后 hello_get_ini_max → 200', 200, hello_get_ini_max());
test('INI 变更通知已触发', true, hello_ini_change_count() > $before);

// ============================================================
// 24. v0.8 — extern struct 对象绑定
// ============================================================
echo "\n=== 24. v0.8 extern struct 对象绑定 ===\n";

$ctr = new Counter();
test('Counter->get() 初始 0', 0, $ctr->get());
test('Counter->increment() → 1', 1, $ctr->increment());
test('Counter->increment() → 2', 2, $ctr->increment());
$ctr->set(10);
test('Counter->set(10) 后 get() → 10', 10, $ctr->get());
test('Counter->increment() → 11', 11, $ctr->increment());

$ctr2 = new Counter();
test('新 Counter 独立状态 get() → 0', 0, $ctr2->get());
test('新 Counter 不受旧实例影响', 0, $ctr2->get());

// ============================================================
// 25. v0.9 — 请求级 arena（内存池）+ cleanup 注册
// ============================================================
echo "\n=== 25. v0.9 arena + cleanup ===\n";

test('hello_arena_sum() 用 arena 分配求和 → 60', 60, hello_arena_sum());
test('hello_cleanup_register() 注册清理回调', true, hello_cleanup_register());

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
