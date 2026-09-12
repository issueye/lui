/* lui M8-5 导航增强类组件演示页逻辑（Tabs / Menu / Breadcrumb / Dropdown / Steps / Backtop） */

const state = reactive({
  activeTab: "tab1",
  menuKey: "m-dash",
  currentStep: 2,
  statusMsg: "就绪",
  tabItems: [
    { name: "tab1", label: "核心特性" },
    { name: "tab2", label: "架构设计" },
    { name: "tab3", label: "更新日志" }
  ],
  dropdownItems: [
    { key: "view", label: "查看详情" },
    { key: "export", label: "导出数据" },
    { key: "delete", label: "危险删除", danger: true }
  ]
});

function OnTabChange(key: string): void {
  state.activeTab = key;
  state.statusMsg = "切换选项卡至：" + key;
}

function OnMenuSelect(key: string): void {
  state.menuKey = key;
  state.statusMsg = "选择菜单项：" + key;
}

function OnCrumbClick(title: string): void {
  state.statusMsg = "点击面包屑：" + title;
  uiMessage.info("导航至：" + title);
}

function NextStep(): void {
  if (state.currentStep >= 3) {
    state.currentStep = 1;
  } else {
    state.currentStep = state.currentStep + 1;
  }
  state.statusMsg = "推进流程至第 " + state.currentStep + " 步";
}

function OnBacktopClick(): void {
  state.statusMsg = "已平滑滚动返回顶部";
  uiMessage.success("已回到顶部");
}

function GetStep1Status(curr: number): string {
  if (curr > 1) { return "finish"; }
  if (curr === 1) { return "process"; }
  return "wait";
}

function GetStep2Status(curr: number): string {
  if (curr > 2) { return "finish"; }
  if (curr === 2) { return "process"; }
  return "wait";
}

function GetStep3Status(curr: number): string {
  if (curr === 3) { return "process"; }
  return "wait";
}

onMount(function () {
  console.log("导航增强组件演示页加载就绪");
});
