<?php
/**
 * php-zig 集成测试套件 —— 功能正确性（正常路径）
 *
 * 测试体系三件套：
 *   test_all.php     本文件：功能正确性（正常路径返回值/行为断言）
 *   test_crash.php   崩溃隔离（fork）：危险边界不崩溃（SEGV/ABRT 检测）
 *   test_corpus.php  类型语料库矩阵：任意类型 × 核心 API 不崩溃
 *
 * 断言「功能正确」看本文件；「不崩溃」看另两个。类型越界类断言不可放在
 * 本文件——弱类型 PHP 的可隐式转换值（"123"→int）不报错，只有类别错误
 * （array→string）才 TypeError（见 special.md「联合类型不拦截隐式转换」）。
 *
 * 分组索引（按能力域）：
 *   §1-2    模块级函数 + 返回值类型
 *   §3       zval 类型判断/取值
 *   §4       arg_info 反射（含 comptime struct 反射）
 *   §5      异常/错误报告        §6  模块常量
 *   §7      PHP Facade 调用      §8  类注册
 *   §9-10  数组操作/遍历         §11 对象属性
 *   §12-13 生命周期/phpinfo      §15-16 Zval 运算符/边界
 *   §17-20 comptime 反射/OOP/数组高级/语义判断
 *   §21-24 默认值/可变参数/序列化/INI
 *   §25-26 arena/cleanup + Fiber
 *   §27-28 Observer（过滤/现场信息）
 *   §29    内存增长探针（泄漏防线）  §30 RequestArena 监控与限额
 */

$passed = 0;
$failed = 0;
$skipped = 0;

// 供 Observer 补强测试使用：必须是 PHP 用户函数（与扩展提供的内部函数对照），
// 且参数个数固定为 3 以便断言 num_args
function obs_user_fn($a = null, $b = null, $c = null) {
    return 1;
}

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

// 弱转换语义：3.7→3、4.2→4（PHP 截断），相加得 7。
// 旧断言 `0+0=0` 锁定的是「isLong() else 0」——string/float 一律当 0，
// 与 PHP 语义不符，已在 v0.10.1 改为官方弱转换（zval_get_long）。
test('add 带小数 → 弱转换截断 3+4=7', 7, add(3.7, 4.2));
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
// 26. v0.9.1 — Fiber（协程）能力
// ============================================================
echo "\n=== 26. v0.9.1 Fiber ===\n";

// 只读查询：isFiber / status
test('hello_fiber_is(普通对象) → false', false, hello_fiber_is(new stdClass()));
test('hello_fiber_is(非对象) → false', false, @hello_fiber_is('not-an-object'));
test('hello_fiber_status(非 fiber) → -1', -1, hello_fiber_status(new stdClass()));

// 构造：Zig 用 callable 创建 Fiber 对象
$fiber = hello_fiber_create(hello_fiber_body());
test('hello_fiber_is($fiber) → true', true, hello_fiber_is($fiber));
test('$fiber instanceof Fiber', true, $fiber instanceof Fiber);
test('新 fiber 状态为 INIT(0)', 0, hello_fiber_status($fiber));

// 启动 fiber：fiber 内部 suspend 自己，start() 返回 suspend 交出的值
$startRet = $fiber->start();
test('start() 返回 fiber suspend 交出的值', 'from-fiber', $startRet);
test('suspend 后状态为 SUSPENDED(2)', 2, hello_fiber_status($fiber));

// resume：PHP 侧唤起 fiber，fiber 继续执行，收到 resume 传入的 'from-php'，
// 将其作为最终结果存入 fiber->result；fiber 直接完成时 resume() 返回 null
$resumeRet = $fiber->resume('from-php');
test('resume() 后 fiber 完成返回 null', null, $resumeRet);
test('执行完毕后状态为 DEAD(3)', 3, hello_fiber_status($fiber));

// getReturn：fiber 最终结果 = resume 传入的值（验证 suspend/resume 值传递链路）
test('get_return 读到 fiber 返回值（= resume 传入值）', 'from-php', hello_fiber_get_return($fiber));

// 第二个 fiber：验证独立状态
$fiber2 = hello_fiber_create(hello_fiber_body());
test('fiber2 初始状态独立 INIT(0)', 0, hello_fiber_status($fiber2));
$fiber2->start();
test('fiber2 suspend 后 SUSPENDED(2)', 2, hello_fiber_status($fiber2));

// ============================================================
// 27. v0.9.1 — Observer 集中式观察代理
// ============================================================
echo "\n=== 27. v0.9.1 Observer ===\n";

// 重置后，观察一次函数调用：begin/end 计数应增长，且能读到函数名
hello_obs_reset();
$beginBefore = hello_obs_begin_count();
$endBefore = hello_obs_end_count();
hello_world();
$beginAfter = hello_obs_begin_count();
$endAfter = hello_obs_end_count();
test('fcall begin 观察已触发（计数增长）', true, $beginAfter > $beginBefore);
test('fcall end 观察已触发（计数增长）', true, $endAfter > $endBefore);
test('能提取被观察函数名（last_func 非空）', true, strlen(hello_obs_last_func()) > 0);

// error 观察：触发一个 warning（E_WARNING = 2）
hello_obs_reset();
$errBefore = hello_obs_error_count();
@hello_error_docref();
$errAfter = hello_obs_error_count();
test('error 观察已触发（计数增长）', true, $errAfter > $errBefore);
test('error type 为 E_WARNING(2)', 2, hello_obs_error_type());

// function_declared / class_linked 观察：声明一个新函数和一个类
hello_obs_reset();
$funcBefore = hello_obs_func_declared();
$clsBefore = hello_obs_class_linked();
eval('function obs_declared_fn() {} class ObsDeclaredClass {}');
$funcAfter = hello_obs_func_declared();
$clsAfter = hello_obs_class_linked();
test('function_declared 观察已触发', true, $funcAfter > $funcBefore);
test('class_linked 观察已触发', true, $clsAfter > $clsBefore);

// fiber 观察：创建 + start + suspend 应触发 fiber_init / fiber_switch
hello_obs_reset();
$fiberInitBefore = hello_obs_fiber_init();
$fiberSwitchBefore = hello_obs_fiber_switch();
$obsFiber = hello_fiber_create(hello_fiber_body());
$obsFiber->start();
$fiberInitAfter = hello_obs_fiber_init();
$fiberSwitchAfter = hello_obs_fiber_switch();
test('fiber_init 观察已触发（创建+启动）', true, $fiberInitAfter > $fiberInitBefore);
test('fiber_switch 观察已触发（start 挂起切换）', true, $fiberSwitchAfter > $fiberSwitchBefore);
$obsFiber->resume('done');
test('fiber 观察回调不影响 fiber 正常执行', 'done', hello_fiber_get_return($obsFiber));

// ============================================================
// 28. v0.9.4 — Observer 补强：现场信息 + 过滤下推
// ============================================================
echo "\n=== 28. v0.9.4 Observer 补强 ===\n";

// P0：declared / class_linked 拿回 op_array / ce 句柄（此前被主动丢弃）
hello_obs_reset();
eval('function obs_handle_fn() {} class ObsHandleClass {}');
test('function_declared 拿到 op_array 句柄', true, hello_obs_declared_handle() >= 1);
test('class_linked 拿到 ce 句柄', true, hello_obs_linked_handle() >= 1);

// P1：过滤下推——只观察 hello_world，其它函数不得进入 begin 回调。
// 这里用「非目标函数被观察到的次数必须为 0」的结构断言，而非弱断言。
hello_obs_reset();
hello_world();                 // 目标函数，应被观察
strlen('abc');                 // 非目标内部函数，应被拦截
hello_obs_seen_target();       // 非目标用户函数，应被拦截
test('过滤：目标函数 hello_world 被观察', 1, hello_obs_seen_target());
test('过滤：非目标函数从未进入回调（结构断言）', 0, hello_obs_seen_other());

// P0：现场信息——内部函数分支（hello_world 由扩展提供，属内部函数）
hello_obs_reset();
hello_world();
test('funcInfo 识别内部函数（internal=true）', true, hello_obs_info_internal());
test('funcInfo 内部函数无定义行号（lineno=0）', 0, hello_obs_info_lineno());
test('funcInfo 参数个数为 0（hello_world 无参）', 0, hello_obs_info_num_args());

// P0：现场信息——用户函数分支（obs_user_fn 由 PHP 定义）
hello_obs_reset();
obs_user_fn(1, 2, 3);
test('funcInfo 识别用户函数（internal=false）', false, hello_obs_info_internal());
test('funcInfo 取到用户函数定义行号', true, hello_obs_info_lineno() > 0);
test('funcInfo 参数个数为 3', 3, hello_obs_info_num_args());

// P0：调用点——callSite 应定位到 PHP 源码里的调用行
hello_obs_reset();
hello_world();                 // ← 这一行就是调用点
$expectedLine = __LINE__ - 1;  // 上一行即调用发生处
test('callSite 定位到 PHP 调用点行号', $expectedLine, hello_obs_call_lineno());

// ============================================================
// 29. 内存增长探针 —— 通用泄漏防线
// ============================================================
echo "\n=== 29. 内存增长（泄漏防线） ===\n";
//
// 背景：PhpFunc.call1Str 曾泄漏——构造的临时字符串 zval 从不释放。
// 190 项功能测试全绿却没发现，因为每个用例只调一两次，泄漏几十字节
// 淹没在请求池里；直到 benchmark 循环 30 万次才 OOM。
//
// 故此处用「循环 N 次后的内存增量」做断言——这是能覆盖**所有**泄漏点的
// 公共防线。若某条 php-zig 路径漏了释放，循环会把它线性放大到可观测。
//
// 阈值取 64KB：覆盖临时变量的正常抖动，但远小于「每次泄漏一个字符串」
// 应有的量级（5 万次 × 至少 32 字节 ≈ 1.6MB）。

$N = 50000;
$LEAK_BUDGET = 65536;    // 64 KB

/**
 * 测一个探针函数的内存增长。
 * 先跑一轮预热（触发请求池首次分配、函数解析等一次性开销），
 * 再取基线测量，避免把一次性开销误判为泄漏。
 */
function memProbe(string $fn, int $n, int $budget): void {
    $fn(1);                                  // 预热
    $before = memory_get_usage();
    $fn($n);
    $after = memory_get_usage();
    $delta = $after - $before;

    // 断言：增长必须低于预算。同时报告实际值以便定位。
    $ok = $delta < $budget;
    test("泄漏探针 {$fn}（{$n} 次）增长 " . number_format($delta) . "B < {$budget}B",
         true, $ok);
}

memProbe('hello_mem_build_string', $N, $LEAK_BUDGET);
memProbe('hello_mem_call_php_func', $N, $LEAK_BUDGET);
memProbe('hello_mem_array_pop', $N, $LEAK_BUDGET);
memProbe('hello_mem_assoc', $N, $LEAK_BUDGET);

// 反向验证：确认这套探针**确实能**测出泄漏——否则它只是个永远为真的空断言。
// 用 PHP 侧主动泄漏一个等量内存，断言增量超过预算，证明阈值设在有效区间。
function leakControl(int $n): void {
    static $sink = [];
    for ($i = 0; $i < $n; $i++) {
        $sink[] = str_repeat('x', 32);       // 主动持有，制造真实泄漏
    }
}
$sinkBefore = memory_get_usage();
leakControl($N);
$sinkDelta = memory_get_usage() - $sinkBefore;
test("反向验证：探针能测出真实泄漏（控制组增长 " . number_format($sinkDelta) . "B ≥ 预算）",
     true, $sinkDelta >= $LEAK_BUDGET);

// ============================================================
// 30. Zig 侧内存（RequestArena）监控与限额
// ============================================================
echo "\n=== 30. Zig 侧内存监控与限额 ===\n";
//
// RequestArena 的 backing 是 c_allocator，不进 PHP 内存池、不受 memory_limit
// 约束。若无监控，进程可在 PHP 侧毫无感知的情况下逼近容器上限被 OOM 杀死。

// 可观测：全局计数应反映真实占用（跨实例累加）
$arenaBefore = hello_arena_usage();
hello_arena_fill(1000);          // 1000 × 64 字节 = 64KB，由 RSHUTDOWN 回收
$arenaDuring = hello_arena_usage();
test('arena usage 反映分配量', true, $arenaDuring - $arenaBefore >= 64000);
test('arena peak 已记录', true, hello_arena_peak() >= $arenaDuring);

// 可约束：限额开启后，超限分配应被拒绝（reject → 分配失败，不崩溃）
// 注意：这里不设 PHP 侧额度核算（第二参 false），只测显式上限
hello_arena_set_limit(65536, false);
$got = hello_arena_fill(100000);   // 远超限额，应在中途停止
test('限额生效：超限后分配被拒绝（未崩溃）', true, $got < 100000 * 64);
test('限额生效：实际分配未超额度上限', true, $got <= 65536 + 65536);

// 显式 configure 后，RINIT 的 INI 载入不得覆盖它。
// INI 项未注册 → configureFromIni 算出 limit=0；若允许覆盖，下游在 MINIT
// 设的限额会在首个请求到来时静默失效——这类失效在功能测试里看不到。
hello_arena_set_limit(32768, false);
hello_arena_ini_reload();
test('显式 configure 不被 INI 载入覆盖', 32768, hello_arena_effective_limit());

// 关闭限额后应恢复自由分配
hello_arena_set_limit(0, false);
$got2 = hello_arena_fill(2000);
test('关闭限额后恢复分配', 128000, $got2);

// ============================================================
// 31. 统一观测出口 + 常驻级（ResidentArena）+ 非托管入口（unsafe）
// ============================================================
echo "\n=== 31. 常驻级 Arena 与统一观测 ===\n";
//
// 三条性质只有 PHP 侧能验证：
//   a. request / resident 是两套物理隔离的账本（互不挤占）
//   b. resident 不随请求结束回收（MSHUTDOWN 时仍 > 0，见 myMshutdown 的 marker）
//   c. unsafeAllocator 不记账、不受额度约束
//
// 注意口径：request 账本含框架自身开销（Cleanup 注册表、Arena 实例与节点），
// 故断言一律用「增量」而非绝对值。

$report0 = hello_arena_report();
test('观测出口返回三档', true,
     isset($report0['total'], $report0['request'], $report0['resident']));
test('观测口径自洽：total = request + resident', true,
     $report0['total'] === $report0['request'] + $report0['resident']);

// 常驻额度由 MINIT 从 phpzig.resident_limit 载入（测试 INI 设为 1M）
test('resident_limit 从 INI 载入', 1048576, hello_resident_limit());

// ——— 常驻写入：只动 resident 账本 ———
$reqBefore = $report0['request'];
$resBefore = $report0['resident'];
hello_resident_put(0, 'persisted-across-requests');
hello_resident_put(1, str_repeat('y', 4096));
$report1 = hello_arena_report();
test('常驻写入后 resident 账本上涨', true, $report1['resident'] > $resBefore);
test('常驻写入不触碰 request 账本', $reqBefore, $report1['request']);
test('常驻数据可读回', 'persisted-across-requests', hello_resident_get(0));
test('常驻数据可读回（4KB）', 4096, strlen(hello_resident_get(1)));
test('未写入的槽位返回 null', null, hello_resident_get(7));

// ——— 红线：常驻占用不得挤占请求级额度 ———
// 把请求级额度设为「当前请求级占用 + 32KB」，再申请 16KB。
// 若两个账本被混用，常驻占用的几十 KB 会直接撑爆额度，这 16KB 必然被拒。
$cur = hello_arena_report();
hello_arena_set_limit($cur['request'] + 32768, false);
$got = hello_arena_fill(250);   // 250 × 64 = 16000 字节
test('常驻占用不挤占请求级额度（红线）', 16000, $got);
hello_arena_set_limit(0, false);

// ——— 非托管入口：既不记账，也不受额度约束 ———
// 请求级额度压到 1 字节 → 受管路径必然失败，unsafe 必须成功。
// 断言用「增量远小于申请量」而非绝对相等：init() 自身的框架开销会进账。
hello_arena_set_limit(1, false);
$before = hello_arena_report();
test('unsafe 分配成功（远超请求级额度）', true, hello_unsafe_alloc(1048576));
$after = hello_arena_report();
test('unsafe 分配不进账本（1MB 申请 / 账本增量 < 4KB）', true,
     ($after['total'] - $before['total']) < 4096);
hello_arena_set_limit(0, false);

// ——— 手动回收：显式释放常驻单例后账目归零 ———
hello_resident_release();
test('显式回收后常驻账目归零', 0, hello_arena_report()['resident']);

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
