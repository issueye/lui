/* lui 组件库：M8-3 反馈与浮层
   - 内联：ui-alert / ui-loading
   - 声明式浮层：ui-dialog / ui-drawer（x-if 控制显示，x-popup 挂到文档根并定位）
   - 命令式：uiMessage / uiNotification / uiMessageBox（库函数创建节点，document.add 时就地登记） */

const UiToastSeq = { n: 0, slots: 0 };
const UiMsgBoxWaiters = {};

/* XML 文本转义（命令式组件把用户文本拼进 XML） */
function UiEsc(s: string): string {
  let out = "" + s;
  out = out.replace("&", "&amp;");
  out = out.replace("<", "&lt;");
  out = out.replace(">", "&gt;");
  out = out.replace("\"", "&quot;");
  return out;
}

function UiAlertClass(kind: string): string {
  if (kind === "success") {
    return "ui-alert--success";
  }
  if (kind === "warning") {
    return "ui-alert--warning";
  }
  if (kind === "danger") {
    return "ui-alert--danger";
  }
  return "ui-alert--info";
}

/* ---- 对话框 / 抽屉：关闭与确认都走回调 props ---- */

function UiDialogClose(props): void {
  props.onClose();
}

function UiDialogOk(props): void {
  props.onOk();
}

component("ui-alert", {
  props: {
    type: { type: "string", default: "info" },
    title: { type: "string", default: "" },
    text: { type: "string", default: "" }
  },
  templateFile: "../templates/alert.xml"
});

component("ui-loading", {
  props: { text: { type: "string", default: "加载中…" } },
  templateFile: "../templates/loading.xml"
});

component("ui-dialog", {
  props: {
    visible: { type: "boolean", default: false },
    title: { type: "string", default: "提示" },
    width: { type: "number", default: 320 },
    onClose: { type: "function" },
    onOk: { type: "function" }
  },
  templateFile: "../templates/dialog.xml"
});

component("ui-drawer", {
  props: {
    visible: { type: "boolean", default: false },
    title: { type: "string", default: "面板" },
    width: { type: "number", default: 240 },
    onClose: { type: "function" }
  },
  templateFile: "../templates/drawer.xml"
});

/* ---- 命令式浮层：顶部居中的轻提示（message / notification 共用） ---- */

function UiToastPlace(node, slot): void {
  const root = document.body;
  if (root === null || root === undefined) {
    return;
  }
  const area = root.rect;
  const box = node.rect;
  const left = (area.width - box.width) / 2;
  const top = 12 + slot * (box.height + 8);
  node.style = "position:absolute; left:" + left + "px; top:" + top + "px";
}

function UiToastShow(html, ms): void {
  const slot = UiToastSeq.slots;
  UiToastSeq.slots = UiToastSeq.slots + 1;
  const node = document.add(html);
  UiToastPlace(node, slot);
  ui.setTimeout(function () { UiToastPlace(node, slot); }, 40);   // 布局后校正宽度
  ui.setTimeout(function () {
    node.remove();
    UiToastSeq.slots = UiToastSeq.slots - 1;
  }, ms);
}

function UiMessage(kind, text): void {
  const cls = UiAlertClass(kind);
  UiToastShow("<panel class=\"ui-message " + cls + "\"><label class=\"ui-message__text\" text=\"" +
    UiEsc(text) + "\"/></panel>", 2400);
}

function UNotification(kind, title, text): void {
  const cls = UiAlertClass(kind);
  UiToastShow("<panel class=\"ui-notification " + cls + "\">" +
    "<label class=\"ui-notification__title\" text=\"" + UiEsc(title) + "\"/>" +
    "<label class=\"ui-notification__text\" text=\"" + UiEsc(text) + "\"/></panel>", 3600);
}

const uiMessage = {
  info: function (text) { UiMessage("info", text); },
  success: function (text) { UiMessage("success", text); },
  warning: function (text) { UiMessage("warning", text); },
  error: function (text) { UiMessage("danger", text); }
};

const uiNotification = {
  info: function (title, text) { UNotification("info", title, text); },
  success: function (title, text) { UNotification("success", title, text); },
  warning: function (title, text) { UNotification("warning", title, text); },
  error: function (title, text) { UNotification("danger", title, text); }
};

/* ---- 消息框：confirm/alert 返回 Promise（按钮点击时结算） ---- */

function UiBoxAncestor(node) {
  let cur = node;
  while (cur !== null && cur !== undefined) {
    if (cur.hasClass("ui-message-box")) {
      return cur;
    }
    cur = cur.parent;
  }
  return null;
}

function UiBoxSettle(event, result): void {
  const box = UiBoxAncestor(event.node);
  if (box === null) {
    return;
  }
  const waiter = UiMsgBoxWaiters[box.id];
  UiMsgBoxWaiters[box.id] = undefined;
  box.remove();
  if (waiter !== undefined && waiter !== null) {
    waiter(result);
  }
}

function UiBoxOk(event): void {
  UiBoxSettle(event, true);
}

function UiBoxCancel(event): void {
  UiBoxSettle(event, false);
}

function UiBox(title, text, withCancel) {
  const id = "uibox" + UiToastSeq.n;
  UiToastSeq.n = UiToastSeq.n + 1;
  let buttons = "<ui-button text=\"确定\" type=\"primary\" x-onclick=\"UiBoxOk\"/>";
  if (withCancel) {
    buttons = "<ui-button text=\"取消\" x-onclick=\"UiBoxCancel\"/>" + buttons;
  }
  const node = document.add("<panel id=\"" + id + "\" class=\"ui-message-box\">" +
    "<panel class=\"ui-message-box__mask\"/>" +
    "<panel class=\"ui-message-box__panel\">" +
    "<label class=\"ui-message-box__title\" text=\"" + UiEsc(title) + "\"/>" +
    "<label class=\"ui-message-box__text\" text=\"" + UiEsc(text) + "\"/>" +
    "<ui-space size=\"8\">" + buttons + "</ui-space>" +
    "</panel></panel>");
  UiBoxPlace(node);
  ui.setTimeout(function () { UiBoxPlace(node); }, 40);
  return new Promise(function (resolve) {
    UiMsgBoxWaiters[id] = resolve;
  });
}

function UiBoxPlace(node): void {
  const root = document.body;
  if (root === null || root === undefined) {
    return;
  }
  const area = root.rect;
  node.style = "position:absolute; left:0; top:0; width:" + area.width +
    "px; height:" + area.height + "px";
}

const uiMessageBox = {
  confirm: function (title, text) { return UiBox(title, text, true); },
  alert: function (title, text) { return UiBox(title, text, false); }
};
