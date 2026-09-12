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

## 组件清单

**M8-1（基础）**

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

**M8-2（表单）**

| 组件 | props | 说明 |
| --- | --- | --- |
| `ui-checkbox` | modelValue(bool) / text / disabled / onModelValue | 点击整行切换；勾号用字形 |
| `ui-switch` | modelValue(bool) / disabled / onModelValue | 旋钮用绝对定位（无 transform） |
| `ui-radio-group` | modelValue(string) / options[{value,text}] / disabled / onModelValue | **数据驱动**：组内选项由 options 渲染（组件间无 provide/inject，不做子组件收集） |
| `ui-slider` | modelValue(number) / min / max / step / disabled | **点击定位取值**（不做拖动：引擎未给非 input 节点指针捕获） |
| `ui-input-number` | modelValue / min / max / step / disabled | − / + 步进 + 输入解析并夹取 |
| `ui-form` | —（默认 slot） | 表单容器 |
| `ui-form-item` | form / prop / label / **model** / rules | 标签 + 控件 + 校验提示 |

### 表单校验协议（无 provide/inject，用显式约定）

```xml
<ui-form id="reg">
  <ui-form-item form="reg" prop="mail" label="邮箱" :model="form"
    :rules="[UiRules.required('请输入邮箱'), UiRules.email('邮箱格式不正确')]">
    <ui-input x-model="form.mail"/>
  </ui-form-item>
</ui-form>
<ui-button text="提交" type="primary" x-onclick="OnSubmit"/>
```

- 规则用库导出的 **`UiRules`**（`required` / `min` / `max` / `minLength` / `email`），
  也接受自定义函数规则（返回 `false` 视为不通过）
- `ui-form-item` 每次刷新求值一次错误消息并显示（值变化才写内部响应式表，不会自激刷新）
- 提交时调 **`uiFormValidate('reg')`** → 返回是否全部通过，并刷新错误显示
- 校验时机：**随刷新实时校验**（引擎无 blur/change 驱动的校验钩子），`UiErrors` 也可供自定义展示

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
