/* lui 组件库：L1 表单（checkbox / switch / radio-group / slider / input-number / form / form-item）
   约定：受控组件 = props.modelValue + 回调 props.onModelValue（配 x-model 使用时由引擎自动接上）。
   校验：库内注册表（非响应）+ 错误消息响应式对象；form-item 的模板每次刷新调用 UiFieldError，
   值变化时才写响应式对象（避免"写响应式 → 再刷新"的循环）。 */

const UiRegistry = {};      // 字段注册表：'form.prop' → {form, prop, model, rules}
const UiErrors = reactive({});   // 错误消息：form → prop → message（响应式，供模板显示）

function UiFieldKey(form: string, prop: string): string {
  return form + "." + prop;
}

function UiToggle(props): void {
  props.onModelValue(!props.modelValue);
}

function UiKnobStyle(on): string {
  if (on) {
    return "position:absolute; left:16px; top:2px";
  }
  return "position:absolute; left:2px; top:2px";
}

function UiRadioPick(props, value): void {
  props.onModelValue(value);
}

function UiPercentStyle(props): string {
  let ratio = (props.modelValue - props.min) / (props.max - props.min);
  if (ratio < 0) {
    ratio = 0;
  }
  if (ratio > 1) {
    ratio = 1;
  }
  return "width:" + (ratio * 100) + "%";
}

/* 滑块根节点定位：从事件节点向上找到 class 含 ui-slider 的祖先，按点击 x 比例换算取值 */
function UiSliderAncestor(node) {
  let cur = node;
  while (cur !== null && cur !== undefined) {
    if (cur.hasClass("ui-slider")) {
      return cur;
    }
    cur = cur.parent;
  }
  return null;
}

function UiSliderSet(props, event): void {
  const root = UiSliderAncestor(event.node);
  if (root === null) {
    return;
  }
  const box = root.rect;
  if (box.width <= 0) {
    return;
  }
  let ratio = (event.x - box.left - 8) / (box.width - 16);   // 扣掉左右内边距
  if (ratio < 0) {
    ratio = 0;
  }
  if (ratio > 1) {
    ratio = 1;
  }
  let value = props.min + ratio * (props.max - props.min);
  const step = props.step;
  value = Math.round(value / step) * step;
  props.onModelValue(value);
}

function UiClamp(props, value): number {
  let v = value;
  if (v < props.min) {
    v = props.min;
  }
  if (v > props.max) {
    v = props.max;
  }
  return v;
}

function UiStep(props, delta): void {
  props.onModelValue(UiClamp(props, props.modelValue + delta * props.step));
}

function UiNumberInput(props, event): void {
  const v = parseFloat(event.text);
  if (isNaN(v)) {
    return;
  }
  props.onModelValue(UiClamp(props, v));
}

/* ---- 校验 ---- */

const UiRules = {
  required: function (msg) { return { kind: "required", message: msg }; },
  min: function (n, msg) { return { kind: "min", value: n, message: msg }; },
  max: function (n, msg) { return { kind: "max", value: n, message: msg }; },
  minLength: function (n, msg) { return { kind: "minLength", value: n, message: msg }; },
  email: function (msg) { return { kind: "email", message: msg }; }
};

/* 单值校验：返回第一条不满足的提示（'' = 通过）。数组元素可为规则对象或函数（返回 false 视为不通过） */
function UiCheckRules(value, rules): string {
  if (rules === undefined || rules === null) {
    return "";
  }
  let i = 0;
  while (i < rules.length) {
    const rule = rules[i];
    i = i + 1;
    if (typeof rule === "function") {
      const ok = rule(value);
      if (ok === false) {
        return "校验未通过";
      }
      continue;
    }
    const kind = rule.kind;
    if (kind === "required") {
      if (value === "" || value === undefined || value === null || value === false) {
        return rule.message;
      }
    } else if (kind === "min") {
      if (value < rule.value) {
        return rule.message;
      }
    } else if (kind === "max") {
      if (value > rule.value) {
        return rule.message;
      }
    } else if (kind === "minLength") {
      if (value.length < rule.value) {
        return rule.message;
      }
    } else if (kind === "email") {
      const s = "" + value;
      if (s.indexOf("@") <= 0 || s.indexOf(".") < 0) {
        return rule.message;
      }
    }
  }
  return "";
}

/* form-item 模板调用：注册字段 + 求值错误消息（仅变化时写响应式对象） */
function UiFieldError(form: string, prop: string, model, rules): string {
  const key = UiFieldKey(form, prop);
  UiRegistry[key] = { form: form, prop: prop, model: model, rules: rules };
  let value = "";
  if (model !== undefined && model !== null) {
    value = model[prop];
  }
  const msg = UiCheckRules(value, rules);
  let bucket = UiErrors[form];
  if (bucket === undefined) {
    UiErrors[form] = {};
    bucket = UiErrors[form];
  }
  if (bucket[prop] !== msg) {
    bucket[prop] = msg;
  }
  return msg;
}

/* 提交校验：返回是否全部通过（并把错误写进 UiErrors 供界面显示） */
function uiFormValidate(form: string): boolean {
  let ok = true;
  const names = Object.keys(UiRegistry);
  let i = 0;
  while (i < names.length) {
    const field = UiRegistry[names[i]];
    i = i + 1;
    if (field.form !== form) {
      continue;
    }
    let value = "";
    if (field.model !== undefined && field.model !== null) {
      value = field.model[field.prop];
    }
    const msg = UiCheckRules(value, field.rules);
    let bucket = UiErrors[form];
    if (bucket === undefined) {
      UiErrors[form] = {};
      bucket = UiErrors[form];
    }
    bucket[field.prop] = msg;
    if (msg !== "") {
      ok = false;
    }
  }
  return ok;
}

/* ---- 组件注册 ---- */

component("ui-checkbox", {
  props: {
    modelValue: { type: "boolean", default: false },
    text: { type: "string", default: "" },
    disabled: { type: "boolean", default: false },
    onModelValue: { type: "function" }
  },
  templateFile: "../templates/checkbox.xml"
});

component("ui-switch", {
  props: {
    modelValue: { type: "boolean", default: false },
    disabled: { type: "boolean", default: false },
    onModelValue: { type: "function" }
  },
  templateFile: "../templates/switch.xml"
});

component("ui-radio-group", {
  props: {
    modelValue: { type: "string", default: "" },
    options: { type: "array", default: [] },
    disabled: { type: "boolean", default: false },
    onModelValue: { type: "function" }
  },
  templateFile: "../templates/radio-group.xml"
});

component("ui-slider", {
  props: {
    modelValue: { type: "number", default: 0 },
    min: { type: "number", default: 0 },
    max: { type: "number", default: 100 },
    step: { type: "number", default: 1 },
    disabled: { type: "boolean", default: false },
    onModelValue: { type: "function" }
  },
  templateFile: "../templates/slider.xml"
});

component("ui-input-number", {
  props: {
    modelValue: { type: "number", default: 0 },
    min: { type: "number", default: 0 },
    max: { type: "number", default: 9999 },
    step: { type: "number", default: 1 },
    disabled: { type: "boolean", default: false },
    onModelValue: { type: "function" }
  },
  templateFile: "../templates/input-number.xml"
});

component("ui-form", {
  props: {},
  templateFile: "../templates/form.xml"
});

component("ui-form-item", {
  props: {
    form: { type: "string", default: "" },
    prop: { type: "string", default: "" },
    label: { type: "string", default: "" },
    model: { type: "object", required: true },
    rules: { type: "array" }
  },
  templateFile: "../templates/form-item.xml"
});
