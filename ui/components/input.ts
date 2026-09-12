/* lui 组件库：ui-input（单行输入，双向绑定协议）
   父级：<ui-input x-model="state.name" placeholder="请输入"/> —— 引擎自动接 props.modelValue / onModelValue；
   组件内：input 的 text 来自 props.modelValue，输入事件回写 props.onModelValue（引擎按事件载荷取值） */

component("ui-input", {
  props: {
    modelValue: { type: "string", default: "" },
    placeholder: { type: "string", default: "" },
    password: { type: "boolean", default: false },
    disabled: { type: "boolean", default: false },
    onModelValue: { type: "function" }
  },
  templateFile: "../templates/input.xml"
});
