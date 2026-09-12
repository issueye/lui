/* lui M8-5 导航增强类组件逻辑（Tabs / Menu / Breadcrumb / Dropdown / Steps / Backtop） */

function UiTabsClass(kind): string {
  let c = "ui-tabs";
  if (kind === "card") {
    c = c + " ui-tabs--card";
  }
  return c;
}

function UiTabItemClass(itemKey, activeKey): string {
  let c = "ui-tabs__item";
  if (String(itemKey) === String(activeKey)) {
    c = c + " is-active";
  }
  return c;
}

function UiTabClick(props, item): void {
  if (props.onChange) {
    props.onChange(item.name || item.key || item);
  }
}

function UiMenuClass(mode): string {
  let c = "ui-menu";
  if (mode === "vertical") {
    c = c + " ui-menu--vertical";
  } else {
    c = c + " ui-menu--horizontal";
  }
  return c;
}

function UiMenuItemClass(active, disabled): string {
  let c = "ui-menu-item";
  if (active) {
    c = c + " is-active";
  }
  if (disabled) {
    c = c + " is-disabled";
  }
  return c;
}

function UiStepStatusClass(status): string {
  let c = "ui-step";
  if (status === "finish") {
    c = c + " is-finish";
  } else if (status === "process") {
    c = c + " is-process";
  } else if (status === "error") {
    c = c + " is-error";
  } else {
    c = c + " is-wait";
  }
  return c;
}

function UiStepNumberText(step, status): string {
  if (status === "finish") {
    return "✓";
  }
  return String(step || 1);
}

function UiDropdownCommand(props, item): void {
  if (props.onCommand) {
    props.onCommand(item);
  }
}

/* 组件注册 */

component("ui-tabs", {
  props: {
    items: { type: "array", default: function () { return []; } },
    active: { type: "any", default: "" },
    type: { type: "string", default: "line" },
    onChange: { type: "function" }
  },
  templateFile: "../templates/tabs.xml"
});

component("ui-tab-pane", {
  props: {
    name: { type: "string", default: "" },
    label: { type: "string", default: "" },
    active: { type: "boolean", default: false }
  },
  templateFile: "../templates/tab-pane.xml"
});

component("ui-menu", {
  props: {
    mode: { type: "string", default: "horizontal" },
    active: { type: "string", default: "" }
  },
  templateFile: "../templates/menu.xml"
});

component("ui-menu-item", {
  props: {
    name: { type: "string", default: "" },
    title: { type: "string", default: "" },
    active: { type: "boolean", default: false },
    disabled: { type: "boolean", default: false },
    onClick: { type: "function" }
  },
  templateFile: "../templates/menu-item.xml"
});

component("ui-breadcrumb", {
  props: {
    separator: { type: "string", default: "/" }
  },
  templateFile: "../templates/breadcrumb.xml"
});

component("ui-breadcrumb-item", {
  props: {
    text: { type: "string", default: "" },
    to: { type: "string", default: "" },
    separator: { type: "string", default: "/" },
    last: { type: "boolean", default: false },
    onClick: { type: "function" }
  },
  templateFile: "../templates/breadcrumb-item.xml"
});

component("ui-dropdown", {
  props: {
    items: { type: "array", default: function () { return []; } },
    placement: { type: "string", default: "bottom-start" },
    visible: { type: "boolean", default: false },
    onCommand: { type: "function" },
    onToggle: { type: "function" }
  },
  templateFile: "../templates/dropdown.xml"
});

component("ui-steps", {
  props: {
    current: { type: "number", default: 1 },
    direction: { type: "string", default: "horizontal" }
  },
  templateFile: "../templates/steps.xml"
});

component("ui-step", {
  props: {
    step: { type: "number", default: 1 },
    title: { type: "string", default: "" },
    desc: { type: "string", default: "" },
    status: { type: "string", default: "wait" }
  },
  templateFile: "../templates/step.xml"
});

component("ui-backtop", {
  props: {
    target: { type: "string", default: "" },
    right: { type: "number", default: 30 },
    bottom: { type: "number", default: 30 },
    onClick: { type: "function" }
  },
  templateFile: "../templates/backtop.xml"
});
