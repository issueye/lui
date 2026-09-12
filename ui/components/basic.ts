/* lui 组件库：L0 基础（布局 / 容器 / 文本 / 图标 / 链接）
   组件内部用到的辅助函数统一 Ui* 前缀（全局命名空间约定）。
   模板经 templateFile 外置：路径相对本文件所在目录（故为 ../templates/*.xml）。 */

const UiIconGlyphs = {
  close: "✕",
  check: "✓",
  arrowDown: "▾",
  arrowUp: "▴",
  arrowLeft: "‹",
  arrowRight: "›",
  loading: "◌",
  search: "⌕",
  star: "★"
};

function UiIconGlyph(name: string): string {
  const g = UiIconGlyphs[name];
  if (g === undefined) {
    return "";
  }
  return g;
}

function UiIconText(glyph: string, name: string): string {
  if (glyph !== "") {
    return glyph;
  }
  return UiIconGlyph(name);
}

function UiCardTitleClass(): string {
  return "ui-card__title";
}

function UiSpaceStyle(size: number, direction: string): string {
  if (direction === "vertical") {
    return "flex-direction:column; row-gap:" + size + "px";
  }
  return "column-gap:" + size + "px";
}

/* ui-row：横向栅格行（gutter = 列间距） */
component("ui-row", {
  props: { gutter: { type: "number", default: 0 } },
  templateFile: "../templates/row.xml"
});

/* ui-col：栅格列（span 1..24，按 flex-grow 权重分配） */
component("ui-col", {
  props: { span: { type: "number", default: 24 } },
  templateFile: "../templates/col.xml"
});

/* ui-space：间距容器 */
component("ui-space", {
  props: {
    size: { type: "number", default: 8 },
    direction: { type: "string", default: "horizontal" }
  },
  templateFile: "../templates/space.xml"
});

/* ui-divider：分割线 */
component("ui-divider", {
  props: { direction: { type: "string", default: "horizontal" } },
  templateFile: "../templates/divider.xml"
});

/* ui-card：卡片（title 字符串 + 默认 slot 作内容） */
component("ui-card", {
  props: { title: { type: "string", default: "" } },
  templateFile: "../templates/card.xml"
});

/* ui-text：文本（type/size 控制颜色与字号） */
component("ui-text", {
  props: {
    text: { type: "string", default: "" },
    type: { type: "string", default: "default" },
    size: { type: "string", default: "default" }
  },
  templateFile: "../templates/text.xml"
});

/* ui-icon：图标（字形表 name，或用 glyph 直接给字形） */
component("ui-icon", {
  props: {
    name: { type: "string", default: "" },
    glyph: { type: "string", default: "" }
  },
  templateFile: "../templates/icon.xml"
});

/* ui-link：链接（点击回调 props.onClick） */
component("ui-link", {
  props: {
    text: { type: "string", default: "" },
    disabled: { type: "boolean", default: false },
    onClick: { type: "function" }
  },
  templateFile: "../templates/link.xml"
});
