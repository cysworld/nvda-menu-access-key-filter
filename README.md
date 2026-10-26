# Menu Access Key Filter（菜单访问键过滤器）

[nvaccess/nvda#20912](https://github.com/nvaccess/nvda/issues/20912) 的原型插件：
中日韩菜单把标签里的汉字当作访问键暴露出来，NVDA 便把它再读一遍，例如 `打开... Ctrl+O 打`、`任务 子菜单 Alt+任`。
插件去掉这类无法键入的访问键，其余快捷键原样保留。

按 issue 里 NV Access 的要求，这是一个用来验证方案可行、并供各语言社区测试的 POC，不是最终的核心修复。

## 下载

- GitHub：<https://github.com/cysworld/nvda-menu-access-key-filter/releases/latest>
- GitCode（国内下载）：<https://gitcode.com/cysworld/nvda-menu-access-key-filter/releases>

下载 `.nvda-addon` 文件，双击安装，重启 NVDA。需要 NVDA 2026.1 或更高版本。

## 规则

只移除**由单个“只能靠输入法输入的字符”构成**的快捷键片段，前面可以带修饰键：

| 快捷键字符串 | 结果 |
| --- | --- |
| `打`（MSAA 弹出菜单项，`Ctrl+O` 在名称里） | （空） |
| `Ctrl+O  打`（UIA 把加速键和访问键拼在一起） | `Ctrl+O` |
| `Alt+任`（MSAA 菜单栏） | （空） |
| `Alt+f`（`文件(&F)`） | 不变 |
| `O`（英文菜单 `&Open`） | 不变 |
| `Ctrl+Shift+F10`、`Alt, F, L` | 不变 |
| `Alt+Ф`（俄语）、希腊、阿拉伯、希伯来、泰、天城文等 | 不变 |

“只能靠输入法输入”指汉字（含扩展区和兼容区）、平假名、片假名、谚文、注音符号，范围见 `shortcutFilter.py`。
这些字符在菜单激活时无法键入，所以作为访问键没有可操作性。

没有采用“字符在标签里出现就去掉”的规则，因为那会误伤英文菜单：`Open` 的访问键 `O` 在标签里，却是有用的。
判据是字符所属的文字系统，而不是“是否与标签重复”，也不依赖界面语言或已安装的键盘布局。

## 实现

- `chooseNVDAObjectOverlayClasses` 给 `MENU`、`POPUPMENU`、`MENUITEM`、`CHECKMENUITEM`、`RADIOMENUITEM` 加一个叠加类，
  重写 `_get_keyboardShortcut`，对基类（MSAA 或 UIA 实现）返回的字符串做过滤。
- 语音、盲文和“报告快捷键”命令都读这个属性，所以一处修改全部生效。
- UIA 用两个空格连接访问键和加速键，MSAA 则原样返回，过滤时把任意空白当作分隔，并保留未被移除的片段之间原有的分隔符。
- 命令“切换是否移除无法键入的菜单访问键”（默认无手势）用于对比前后效果。
- 每次移除在调试级别日志中记录，方便收集各语言的测试数据。

## 已验证与未验证

已验证：

- 25 个单元测试通过，覆盖 issue 中的两个例子、18 类可键入的文字、10 类仅限输入法的文字和各种分隔符。
- 用真实的 Win32 菜单（PowerShell + `oleacc`）确认了 MSAA 实际返回的数据，issue 的现象在原生菜单上可以复现：

  | 菜单 | 名称 | `accKeyboardShortcut` |
  | --- | --- | --- |
  | 菜单栏 `&任务` | `任务` | `Alt+任` |
  | 菜单栏 `文件(&F)` | `文件(F)` | `Alt+f` |
  | 菜单栏 `无助记符`（没写 `&`） | `无助记符` | `Alt+无` |
  | 菜单栏 `Plain`（没写 `&`） | `Plain` | `Alt+p` |
  | 弹出菜单 `&打开...` + Ctrl+O | `打开...` + Tab + `Ctrl+O` | `打` |
  | 弹出菜单 `保存` + Ctrl+S | `保存` + Tab + `Ctrl+S` | `保` |
  | 弹出菜单 `导出(&E)` + Ctrl+E | `导出(E)` + Tab + `Ctrl+E` | `e` |

  两点结论：没写 `&` 时，MSAA 会自己拿标签的第一个字符当访问键，这就是“没人指定也会读出汉字”的来源；
  弹出菜单项的加速键在**名称**里，不在快捷键属性里。所以 Bookworm 的 `打开... Ctrl+O 打` 是名称加快捷键拼出来的，
  过滤掉快捷键 `打` 后读作 `打开... Ctrl+O`，加速键不会受影响。
- 在 Internet Download Manager 和 Bookworm（简体中文界面）里安装插件实测，朗读符合预期：
  `任务 子菜单 Alt+任` 读作 `任务 子菜单`，`打开... Ctrl+O 打` 读作 `打开... Ctrl+O`。
- 通过阅读 NVDA 源码确认 `keyboardShortcut` 的生成（`NVDAObjects/UIA`、`NVDAObjects/IAccessible`）和消费
  （`speech/shortcutKeys.py`、`speech/speech.py`）位置。

未验证：

- 目前只有简体中文界面的 Internet Download Manager 和 Bookworm 做过真机测试，其他语言和应用还没有。
- 单元测试里的接线测试用的是 NVDA 模块的替身，只能防止插件自身逻辑回归。
- 没有运行 Bookworm 和 IDM 本身。上面用原生菜单复现了同样的数据，但真实应用的实现可能有差异。
- 只测了 .NET 旧版 `MainMenu` / `ContextMenu` 创建的原生菜单，MFC、wx 等框架没有逐个测。
- 只覆盖菜单相关角色。按钮、标签页等控件上的同类访问键不处理。

## 构建、安装、测试

```
python build.py                                   # 生成 dist\menuAccessKeyFilter-0.1.0.nvda-addon
python -I -m unittest discover -s tests -v        # 运行测试
```

## 给各语言社区的测试清单

对每个应用和语言，对比开关插件前后的朗读（用“切换”命令），并把日志级别设为调试：

1. 带汉字、假名、谚文访问键的菜单项：访问键不应再被读出，加速键应保留。
2. 带拉丁字母访问键的菜单项（含括号写法 `文件(&F)`）：必须仍然读出。
3. 西里尔、希腊、阿拉伯、希伯来、泰文等界面里能用键盘直接键入的访问键：必须仍然读出。
4. `Shift+小键盘2`（笔记本为 `NVDA+Ctrl+Shift+.`）：结果应与自动朗读一致。

反馈时请附上应用名、界面语言和日志中的 `Removed unusable access key(s) ...` 行。
