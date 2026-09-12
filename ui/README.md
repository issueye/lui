# lui 组件库（ui/）

零构建组件库：组件是 **XML 模板（templates/*.xml）+ CSS 主题（theme/*.css）+ TS 注册（components/*.ts）**，
跑在 lui 引擎的组件系统之上（`component()` / props / 具名 slot / `x-model` / `x-onclick`）。

## 用法（3 步）

```xml
<!-- 1) 页面里引入组件库（相对页面 XML 的相对路径） -->
<script src="../ui/index.ts"/>

<!-- 2) 用组件（标签名 ui- 前缀；props 同名 camelCase，事件用 x-onclick 或 :on-xxx 传函数 prop） -->
<ui-card title="示例">
  <ui-button text="保存" type="primary" x-onclick="OnSave"/>
  <ui-input x-model="state.name" placeholder="请输入用户名"/>
</ui-card>
```

```pascal
// 3) 宿主加载主题（浅色表是基座；深色主题再叠 lui-dark.css，只覆盖 token）
FHost.Engine.LoadStyleSheetFromFile('ui/theme/lui-light.css');
```

## 目录

```
ui/
  index.ts              # 入口：ui.include 逐个引入 components/*（同一文件只执行一次）
  theme/lui-light.css   # 设计 token（CSS 变量）+ 全部组件样式
  theme/lui-dark.css    # 深色主题：只覆盖 token
  components/*.ts       # 每组件一个文件：辅助函数（Ui* 前缀）+ component() 注册
  templates/*.xml       # 每组件一个模板（templateFile 引用；路径相对 components/*.ts）
```

## 命名约定

- 标签：`ui-<name>`；类名：`ui-<comp>`、修饰 `ui-<comp>--<variant>`、状态 `is-*`
- 组件内部辅助函数统一 `Ui*` 前缀（TS 子集没有模块系统，全部落在全局命名空间）
- 主题 token：`--ui-color-*`、`--ui-height-*`、`--ui-font-size-*`、`--ui-gap`、`--ui-radius*`、`--ui-transition`

## 组件清单（M8-1 已交付）

| 组件 | props | 说明 |
| --- | --- | --- |
| `ui-button` | text / type(default·primary·success·warning·danger·info) / size(default·small·large) / disabled / onClick | 原生 button 行为 + 修饰类 |
| `ui-input` | modelValue / placeholder / password / disabled / onModelValue | 配 `x-model` 双向绑定（`x-model="state.x"`） |
| `ui-card` | title | 标题为空时不渲染标题行；默认 slot 作内容 |
| `ui-row` / `ui-col` | gutter / span(1..24) | flex 栅格（span 作 flex-grow 权重） |
| `ui-space` | size / direction(horizontal·vertical) | 间距容器（gap） |
| `ui-divider` | direction | 分割线 |
| `ui-text` | text / type / size | 文本（颜色/字号） |
| `ui-icon` | name(字形表) / glyph | 字形图标（Unicode；无 image 渲染） |
| `ui-link` | text / disabled / onClick | 链接 |

## 与 Element Plus 的差异（重要）

- **事件**：父级用 `x-onclick="Fn"` 或 `:on-click="Fn"`（函数 prop），组件内部用 `x-onclick="props.onClick"`；
  没有 `@click`（XML 属性名不允许以 `@` 开头）
- **双向绑定**：`x-model="state.x"`（引擎协议：`props.modelValue` ↔ `props.onModelValue`），不是 `v-model`
- **插槽**：子节点加 `slot="name"` 对应 `<slot name="name"/>`，没有 `v-slot` 简写
- **图标**：字形（✓ ★ ▾ 等），引擎暂不支持 image 渲染/矢量图标
- **无 CSS 变量以外的 token 机制**：主题=覆盖 token；尺寸阶梯用 `--ui-height-*` 等 token
- **暂缺**：受控组件的键盘可达性（方向键/Esc 需引擎补键盘事件）、`ui-input` 的 clearable/前后缀插槽

## 已知问题

- `ui-button` 的 `size="small"`（26px 高）文本会被上裁约 6px（引擎文本垂直居中在矮盒内的排版细节，
  与容器无关；默认/大号正常）。修复前建议按钮最小高度 ≥ 28px。
