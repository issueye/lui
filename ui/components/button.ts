/* lui 组件库：ui-button（对齐 Element Plus 的 el-button 语义子集）
   prop: type = default/primary/success/warning/danger/info；size = default/small/large
   点击经回调 prop 抛给父级：模板内 x-onclick="props.onClick"；父级写 x-onclick="Fn" 或 :on-click="Fn"。
   注：`type` 是 TS 子集保留字，不能作标识符（参数/变量）名，只能作属性名（props.type）。 */

function UiBtnClass(kind: string, size: string, round: boolean, plain: boolean, circle: boolean): string {
  let cls = "";
  if (kind === "primary") {
    cls = cls + " ui-btn--primary";
  } else if (kind === "success") {
    cls = cls + " ui-btn--success";
  } else if (kind === "warning") {
    cls = cls + " ui-btn--warning";
  } else if (kind === "danger") {
    cls = cls + " ui-btn--danger";
  } else if (kind === "info") {
    cls = cls + " ui-btn--info";
  }
  if (size === "small") {
    cls = cls + " ui-btn--sm";
  } else if (size === "large") {
    cls = cls + " ui-btn--lg";
  }
  if (round) {
    cls = cls + " is-round";
  }
  if (plain) {
    cls = cls + " is-plain";
  }
  if (circle) {
    cls = cls + " is-circle";
  }
  return cls;
}

component("ui-button", {
  props: {
    text: { type: "string", default: "" },
    type: { type: "string", default: "default" },
    size: { type: "string", default: "default" },
    round: { type: "boolean", default: false },
    plain: { type: "boolean", default: false },
    circle: { type: "boolean", default: false },
    disabled: { type: "boolean", default: false },
    onClick: { type: "function" }
  },
  templateFile: "../templates/button.xml"
});
