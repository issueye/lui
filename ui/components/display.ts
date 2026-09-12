/* lui M8-4 数据展示类组件逻辑（Tag / Badge / Progress / Avatar / Collapse / Pagination / Table / Tooltip / Popover） */

function UiTagClass(kind, size): string {
  let c = "ui-tag--" + (kind || "default");
  if (size === "small") {
    c = c + " ui-tag--sm";
  } else if (size === "large") {
    c = c + " ui-tag--lg";
  }
  return c;
}

function UiBadgeClass(kind, dot): string {
  let c = "ui-badge__sup--" + (kind || "danger");
  if (dot) {
    c = c + " is-dot";
  }
  return c;
}

function UiBadgeText(val, max): string {
  const m = max || 99;
  if (typeof val === "number" && val > m) {
    return m + "+";
  }
  return String(val);
}

function UiProgressClass(status): string {
  if (status === "success") {
    return "is-success";
  }
  if (status === "exception" || status === "danger") {
    return "is-exception";
  }
  if (status === "warning") {
    return "is-warning";
  }
  return "";
}

function UiPageCount(total, pageSize): number {
  const size = pageSize || 10;
  const tot = total || 0;
  if (tot <= 0) {
    return 1;
  }
  let cnt = Math.floor(tot / size);
  if (tot % size > 0) {
    cnt = cnt + 1;
  }
  return cnt;
}

function UiCanPrev(current): boolean {
  return (current || 1) > 1;
}

function UiCanNext(current, total, pageSize): boolean {
  return (current || 1) < UiPageCount(total, pageSize);
}

component("ui-tag", {
  props: {
    type: { type: "string", default: "default" },
    size: { type: "string", default: "default" },
    closable: { type: "boolean", default: false },
    text: { type: "string", default: "" },
    onClose: { type: "function" }
  },
  templateFile: "../templates/tag.xml"
});

component("ui-badge", {
  props: {
    value: { type: "any", default: "" },
    max: { type: "number", default: 99 },
    dot: { type: "boolean", default: false },
    hidden: { type: "boolean", default: false },
    type: { type: "string", default: "danger" }
  },
  templateFile: "../templates/badge.xml"
});

component("ui-progress", {
  props: {
    percentage: { type: "number", default: 0 },
    status: { type: "string", default: "" },
    strokeWidth: { type: "number", default: 8 },
    showText: { type: "boolean", default: true }
  },
  templateFile: "../templates/progress.xml"
});

component("ui-avatar", {
  props: {
    src: { type: "string", default: "" },
    text: { type: "string", default: "" },
    size: { type: "number", default: 36 },
    shape: { type: "string", default: "circle" }
  },
  templateFile: "../templates/avatar.xml"
});

component("ui-collapse", {
  props: {
    modelValue: { type: "any", default: "" }
  },
  templateFile: "../templates/collapse.xml"
});

component("ui-collapse-item", {
  props: {
    title: { type: "string", default: "" },
    name: { type: "string", default: "" },
    active: { type: "boolean", default: false },
    onToggle: { type: "function" }
  },
  templateFile: "../templates/collapse-item.xml"
});

component("ui-pagination", {
  props: {
    current: { type: "number", default: 1 },
    pageSize: { type: "number", default: 10 },
    total: { type: "number", default: 0 },
    onPrev: { type: "function" },
    onNext: { type: "function" },
    onChange: { type: "function" }
  },
  templateFile: "../templates/pagination.xml"
});

component("ui-table", {
  props: {
    columns: { type: "array", default: function () { return []; } },
    data: { type: "array", default: function () { return []; } }
  },
  templateFile: "../templates/table.xml"
});

component("ui-tooltip", {
  props: {
    content: { type: "string", default: "" },
    placement: { type: "string", default: "top" },
    visible: { type: "boolean", default: false }
  },
  templateFile: "../templates/tooltip.xml"
});

component("ui-popover", {
  props: {
    title: { type: "string", default: "" },
    content: { type: "string", default: "" },
    placement: { type: "string", default: "bottom" },
    visible: { type: "boolean", default: false }
  },
  templateFile: "../templates/popover.xml"
});
