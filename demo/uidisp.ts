/* lui M8-4 数据展示类组件演示页逻辑（Tag / Badge / Progress / Avatar / Collapse / Pagination / Table） */

const state = reactive({
  tagCount: 3,
  tagMsg: "就绪",
  badgeNum: 8,
  progress: 68,
  collapseOpen: true,
  page: 1,
  pageSize: 5,
  total: 25,
  tableCols: [
    { prop: "id", label: "序号", width: 50 },
    { prop: "name", label: "组件名称", width: 110 },
    { prop: "category", label: "分类", width: 90 },
    { prop: "status", label: "状态" }
  ],
  tableData: [
    { id: "1", name: "ui-tag", category: "数据展示", status: "已就绪" },
    { id: "2", name: "ui-badge", category: "数据展示", status: "已就绪" },
    { id: "3", name: "ui-progress", category: "数据展示", status: "已就绪" },
    { id: "4", name: "ui-collapse", category: "数据展示", status: "已就绪" },
    { id: "5", name: "ui-table", category: "数据展示", status: "已就绪" }
  ]
});

function OnTagClose1(): void {
  state.tagMsg = "移除了标签：Vue";
  uiMessage.info("标签已关闭");
}

function OnTagClose2(): void {
  state.tagMsg = "移除了标签：React";
  uiMessage.info("标签已关闭");
}

function AddBadge(): void {
  state.badgeNum = state.badgeNum + 10;
  if (state.badgeNum > 120) {
    state.badgeNum = 0;
  }
}

function IncProgress(): void {
  state.progress = state.progress + 15;
  if (state.progress > 100) {
    state.progress = 10;
  }
}

function ToggleCollapse(): void {
  state.collapseOpen = !state.collapseOpen;
}

function OnPrevPage(): void {
  if (state.page > 1) {
    state.page = state.page - 1;
    RefreshTablePage();
  }
}

function OnNextPage(): void {
  const maxP = Math.floor(state.total / state.pageSize);
  if (state.page < maxP) {
    state.page = state.page + 1;
    RefreshTablePage();
  }
}

function RefreshTablePage(): void {
  if (state.page === 1) {
    state.tableData = [
      { id: "1", name: "ui-tag", category: "数据展示", status: "已就绪" },
      { id: "2", name: "ui-badge", category: "数据展示", status: "已就绪" },
      { id: "3", name: "ui-progress", category: "数据展示", status: "已就绪" },
      { id: "4", name: "ui-collapse", category: "数据展示", status: "已就绪" },
      { id: "5", name: "ui-table", category: "数据展示", status: "已就绪" }
    ];
  } else if (state.page === 2) {
    state.tableData = [
      { id: "6", name: "ui-pagination", category: "数据展示", status: "已就绪" },
      { id: "7", name: "ui-avatar", category: "数据展示", status: "已就绪" },
      { id: "8", name: "ui-tooltip", category: "浮层反馈", status: "已就绪" },
      { id: "9", name: "ui-popover", category: "浮层反馈", status: "已就绪" },
      { id: "10", name: "ui-dialog", category: "反馈浮层", status: "已就绪" }
    ];
  } else {
    state.tableData = [
      { id: "11", name: "ui-tabs", category: "导航增强", status: "开发中" },
      { id: "12", name: "ui-menu", category: "导航增强", status: "开发中" },
      { id: "13", name: "ui-breadcrumb", category: "导航增强", status: "开发中" },
      { id: "14", name: "ui-dropdown", category: "导航增强", status: "开发中" },
      { id: "15", name: "ui-steps", category: "导航增强", status: "开发中" }
    ];
  }
}

onMount(function () {
  console.log("数据展示组件演示页加载完成");
});
